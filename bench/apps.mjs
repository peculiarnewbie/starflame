// How to build each benchmark app and run it in Miniflare.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

export const root = resolve(fileURLToPath(import.meta.url), "..");
const out = (name) => `${root}/build/${name}.mjs`;

async function bundle(name, entry) {
  await build({
    entryPoints: [entry],
    outfile: out(name),
    bundle: true,
    format: "esm",
    platform: "neutral",
    conditions: ["workerd", "worker", "import"],
    mainFields: ["module", "main"],
    external: ["cloudflare:*", "node:*"],
    logLevel: "warning",
  });
  return out(name);
}

export const apps = {
  starflame: {
    async build() {
      execFileSync("gleam", ["build"], { cwd: `${root}/starflame`, stdio: "inherit" });
      return { scriptPath: await bundle("starflame", `${root}/starflame/worker.ts`) };
    },
  },
  capnweb: {
    async build() {
      return { scriptPath: await bundle("capnweb", `${root}/capnweb/worker.ts`) };
    },
  },
  plain: {
    async build() {
      return { scriptPath: await bundle("plain", `${root}/plain/worker.ts`) };
    },
  },
  hono: {
    async build() {
      return { scriptPath: await bundle("hono", `${root}/hono/worker.ts`) };
    },
  },
  sveltekit: {
    async build() {
      const app = `${root}/sveltekit`;
      execFileSync("pnpm", ["build"], { cwd: app, stdio: ["ignore", "ignore", "inherit"] });
      // The id SvelteKit derives for todos.remote.ts, which its client
      // would put in each request's path.
      const manifest = readFileSync(`${app}/.svelte-kit/output/server/manifest.js`, "utf8");
      const remote = manifest.match(/remotes:\s*\{\s*'([^']+)'/)[1];
      return {
        // wrangler bundles this at deploy time; do the same.
        scriptPath: await bundle("sveltekit", `${app}/.svelte-kit/cloudflare/_worker.js`),
        remote,
        // Remote function calls never reach static assets.
        serviceBindings: { ASSETS: () => new Response("Not found", { status: 404 }) },
      };
    },
  },
};

/// The benchmarked targets: an app and how the client reaches it.
export const targets = {
  "starflame-ws": { app: "starflame", transport: "capnweb-ws" },
  "starflame-http": { app: "starflame", transport: "capnweb-http" },
  "capnweb-ws": { app: "capnweb", transport: "capnweb-ws" },
  "capnweb-http": { app: "capnweb", transport: "capnweb-http" },
  plain: { app: "plain", transport: "http-json" },
  hono: { app: "hono", transport: "http-json" },
  sveltekit: { app: "sveltekit", transport: "sveltekit" },
};

/// The migration the Starflame app's schema generates, applied to every app.
export function schemaStatements() {
  const sql = readFileSync(`${root}/starflame/migrations/0001_init.sql`, "utf8");
  return sql
    .split("\n")
    .filter((line) => !line.startsWith("--"))
    .join("\n")
    .split(";")
    .map((statement) => statement.trim())
    .filter(Boolean);
}
