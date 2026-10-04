// Benchmarks each target under Miniflare's workerd. See README.md.
//
//   node run.mjs [--check] [--targets a,b] [--operations a,b]
//                [--concurrency 1,32] [--warmup 2] [--duration 5] [--threads 8]

import { fork } from "node:child_process";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { parseArgs } from "node:util";
import { isDeepStrictEqual } from "node:util";
import { transform } from "esbuild";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { apps, root, schemaStatements, targets } from "./apps.mjs";
import { client, operations, todos } from "./clients.mjs";

const { values: options } = parseArgs({
  options: {
    check: { type: "boolean", default: false },
    targets: { type: "string", default: Object.keys(targets).join(",") },
    operations: { type: "string", default: Object.keys(operations).join(",") },
    concurrency: { type: "string", default: "1,32" },
    warmup: { type: "string", default: "2" },
    duration: { type: "string", default: "5" },
    threads: { type: "string", default: "8" },
  },
});
const list = (value) => value.split(",").filter(Boolean);
const selected = list(options.targets);
const selectedOperations = list(options.operations);
const levels = list(options.concurrency).map(Number);

const built = {};
const results = [];
const sizes = {};

for (const name of selected) {
  const target = targets[name];
  if (!target) throw new Error(`Unknown target ${name}`);
  built[target.app] ??= await apps[target.app].build();
  const app = built[target.app];
  sizes[target.app] ??= await size(app.scriptPath);

  const mf = new Miniflare(
    convertV4MiniflareOptions({
      modules: true,
      scriptPath: app.scriptPath,
      compatibilityDate: "2026-09-30",
      compatibilityFlags: ["nodejs_compat"],
      d1Databases: { DB: "bench" },
      serviceBindings: app.serviceBindings,
      // Straight to the worker, skipping the entry worker Miniflare puts in
      // front of it, which production doesn't have.
      unsafeDirectSockets: [{ host: "127.0.0.1", port: 0 }],
    }),
  );
  await mf.ready;
  const base = (await mf.unsafeGetDirectURL()).origin;
  try {
    await seed(await mf.getD1Database("DB"));
    const workerd = findWorkerd();
    await verify(name, target, base, app);
    console.log(`ok ${name}: every method returns the expected result`);
    if (options.check) continue;

    for (const operation of selectedOperations) {
      for (const concurrency of levels) {
        const result = await measure(target, base, app, workerd, operation, concurrency);
        results.push({ target: name, operation, concurrency, ...result });
        console.log(line(results.at(-1)));
      }
    }
  } finally {
    await mf.dispose();
  }
}

if (!options.check) report();

// SETUP -----------------------------------------------------------------------

async function seed(db) {
  for (const statement of schemaStatements()) await db.prepare(statement).run();
  const insert = db.prepare("INSERT INTO todos (title, done) VALUES (?, ?)");
  const rows = Array.from({ length: 1000 }, (_, i) => insert.bind(`Seeded todo ${i + 1}`, i % 2));
  await db.batch(rows);
}

/// Miniflare's workerd, a child of this process.
function findWorkerd() {
  const found = readdirSync("/proc")
    .filter((entry) => /^\d+$/.test(entry))
    .filter((pid) => {
      try {
        const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
        const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
        return Number(fields[1]) === process.pid && stat.includes("(workerd)");
      } catch {
        return false;
      }
    });
  if (found.length !== 1) throw new Error(`Expected one workerd child, found ${found.length}`);
  return found[0];
}

/// CPU time of every workerd thread, in milliseconds.
function cpuMs(pid) {
  let total = 0;
  for (const task of readdirSync(`/proc/${pid}/task`)) {
    try {
      total += Number(readFileSync(`/proc/${pid}/task/${task}/schedstat`, "utf8").split(" ")[0]);
    } catch {
      // The thread exited.
    }
  }
  return total / 1e6;
}

async function size(scriptPath) {
  const source = readFileSync(scriptPath, "utf8");
  const { code } = await transform(source, { minify: true, format: "esm" });
  return { minified: code.length, gzip: gzipSync(code).length };
}

// VERIFY ----------------------------------------------------------------------

async function verify(name, target, base, app) {
  const transport = client(target.transport, base, app);
  const session = transport.open();
  const isTodo = (value) =>
    Number.isInteger(value?.id) && typeof value.title === "string" && typeof value.done === "boolean";
  const checks = {
    ping: (value) => value === 2,
    echo: (value) => isDeepStrictEqual(value, todos),
    list: (value) => Array.isArray(value) && value.length === 50 && value.every(isTodo),
    get: (value) => isTodo(value),
    add: (value) => isTodo(value) && value.title === "A todo added during the benchmark",
  };
  try {
    for (const [operation, check] of Object.entries(checks)) {
      const value = await transport.call(session, ...operations[operation]());
      if (!check(value)) {
        throw new Error(`${name} ${operation} returned ${JSON.stringify(value)?.slice(0, 300)}`);
      }
    }
  } finally {
    transport.close(session);
  }
}

// MEASURE ---------------------------------------------------------------------

function measure(target, base, app, workerd, operation, concurrency) {
  const start = Date.now() + 500 + Number(options.warmup) * 1000;
  const end = start + Number(options.duration) * 1000;
  return new Promise((resolve, reject) => {
    const driver = fork(`${root}/load.mjs`);
    const sample = (at) =>
      new Promise((resolve) => setTimeout(() => resolve(cpuMs(workerd)), at - Date.now()));
    const cpu = Promise.all([sample(start), sample(end)]);
    driver.once("message", async (message) => {
      driver.kill();
      const [before, after] = await cpu;
      if (message.errors > 0) {
        return reject(new Error(`${message.errors} errors; first: ${message.firstError}`));
      }
      const latencies = Float64Array.from(message.latencies).sort();
      const count = latencies.length;
      const at = (p) => latencies[Math.min(count - 1, Math.floor(p * count))];
      resolve({
        requests: count,
        rps: count / Number(options.duration),
        p50: at(0.5),
        p99: at(0.99),
        cpuPerRequestUs: ((after - before) * 1000) / count,
        serverCpuCores: (after - before) / (end - start),
        clientCpuCores: message.clientCpuMs / (end - start + 500 + Number(options.warmup) * 1000),
      });
    });
    driver.once("error", reject);
    driver.send({
      transport: target.transport,
      base,
      details: { remote: app.remote },
      operation,
      concurrency,
      threads: Number(options.threads),
      start,
      end,
    });
  });
}

// REPORT ----------------------------------------------------------------------

function line(r) {
  return [
    r.target.padEnd(15),
    r.operation.padEnd(5),
    `c=${r.concurrency}`.padEnd(5),
    `${Math.round(r.rps)} req/s`.padStart(12),
    `p50 ${r.p50.toFixed(2)} ms`.padStart(14),
    `p99 ${r.p99.toFixed(2)} ms`.padStart(14),
    `cpu ${Math.round(r.cpuPerRequestUs)} µs/req`.padStart(17),
    `server ${r.serverCpuCores.toFixed(2)} cores`,
    `client ${r.clientCpuCores.toFixed(2)} cores`,
  ].join("  ");
}

function report() {
  const rows = [
    "| Operation | Concurrency | Target | req/s | p50 ms | p99 ms | Server CPU µs/req |",
    "| --- | ---: | --- | ---: | ---: | ---: | ---: |",
  ];
  for (const operation of selectedOperations) {
    for (const concurrency of levels) {
      for (const r of results.filter((r) => r.operation === operation && r.concurrency === concurrency)) {
        rows.push(
          `| ${operation} | ${concurrency} | ${r.target} | ${Math.round(r.rps)} | ${r.p50.toFixed(2)} | ${r.p99.toFixed(2)} | ${Math.round(r.cpuPerRequestUs)} |`,
        );
      }
    }
  }
  const bundles = [
    "| App | Worker minified | gzip |",
    "| --- | ---: | ---: |",
    ...Object.entries(sizes).map(
      ([app, s]) => `| ${app} | ${(s.minified / 1024).toFixed(1)} KiB | ${(s.gzip / 1024).toFixed(1)} KiB |`,
    ),
  ];
  const markdown = `${rows.join("\n")}\n\n${bundles.join("\n")}\n`;
  console.log(`\n${markdown}`);
  mkdirSync(`${root}/results`, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  writeFileSync(`${root}/results/${stamp}.json`, JSON.stringify({ options, sizes, results }, null, 2));
  writeFileSync(`${root}/results/${stamp}.md`, markdown);
  console.log(`Wrote results/${stamp}.{json,md}`);
}
