// Bundles worker.ts, runs it in Miniflare, then drives it over Cap'n Web.
// Usage: pnpm exp   (runs `gleam build` first)

import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { newWebSocketRpcSession, newHttpBatchRpcSession } from "capnweb";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = resolve(fileURLToPath(import.meta.url), "../..");
const gleam = (path) => `${root}/build/dev/javascript/spike/${path}`;
const outfile = `${root}/.experiments/worker.mjs`;

await build({
  entryPoints: [`${root}/worker.ts`],
  outfile,
  bundle: true,
  format: "esm",
  platform: "neutral",
  conditions: ["workerd", "worker", "import"],
  mainFields: ["module", "main"],
  external: ["cloudflare:*"],
  logLevel: "warning",
});

// Miniflare 5 has a new options shape; the v4 shape is easier to write by hand.
const options = convertV4MiniflareOptions({
  modules: true,
  scriptPath: outfile,
  compatibilityDate: "2026-09-30",
  port: 8799, // fixed, so reconnecting after a restart hits the same URL
});
const mf = new Miniflare(options);
const base = await mf.ready;
const wsUrl = `ws://${base.host}/rpc`;
const httpUrl = `http://${base.host}/rpc`;

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`  ${ok ? "PASS" : "FAIL"} ${name}  ${detail}`);
  if (!ok) failures++;
};

console.log("\n# Gleam client stubs (WebSocket)");
const experiments = await import(gleam("spike/experiments.mjs"));
failures += await experiments.main(wsUrl);

console.log("\n# Raw Cap'n Web");
{
  using api = newWebSocketRpcSession(wsUrl);

  const wire = await api.get_user(2);
  check("wire format of Result(User, ApiError)", wire.$ === "Ok", JSON.stringify(wire));

  try {
    await api.get_user("not an int");
    check("bad argument rejected", false);
  } catch (error) {
    check("bad argument rejected", /Invalid RPC argument/.test(error.message), error.message);
  }

  try {
    await api.not_a_method();
    check("unknown method rejected", false);
  } catch (error) {
    check("unknown method rejected", true, error.message);
  }
}

{
  const response = await mf.dispatchFetch(httpUrl, {
    headers: { Upgrade: "websocket", Origin: "https://evil.example" },
  });
  check("cross-origin WebSocket refused", response.status === 403, `status ${response.status}`);
}

console.log("\n# Latency (local, so this is per-call overhead, not network)");
{
  let start = performance.now();
  const api = newWebSocketRpcSession(wsUrl);
  await api.get_user(1);
  const firstWs = performance.now() - start;

  start = performance.now();
  for (let i = 0; i < 200; i++) await api.get_user(1);
  const perWsCall = (performance.now() - start) / 200;
  api[Symbol.dispose]();

  start = performance.now();
  for (let i = 0; i < 200; i++) await newHttpBatchRpcSession(httpUrl).get_user(1);
  const perHttpCall = (performance.now() - start) / 200;

  console.log(`  ws: connect + first call ${firstWs.toFixed(1)}ms, then ${perWsCall.toFixed(2)}ms/call`);
  console.log(`  http batch: ${perHttpCall.toFixed(2)}ms/call`);
}

console.log("\n# Redeploy mid-session");
{
  const client = await import(gleam("spike/generated/client.mjs"));
  const conn = client.connect(wsUrl);
  let brokenWith = null;
  client.on_broken(conn, (message) => {
    brokenWith = message;
  });

  const login = await client.login(conn, "ada");
  const session = login[0][0];
  const before = await client.session_me(session);
  check("capability works before redeploy", before.isOk(), before[0]?.name);

  await mf.setOptions(options); // restarts workerd, like a deploy
  await new Promise((r) => setTimeout(r, 200));
  check("onRpcBroken fired", brokenWith !== null, brokenWith ?? "");

  const after = await client.session_me(session);
  check("old capability fails cleanly", !after.isOk(), after[0]?.message);

  const fresh = client.connect(wsUrl);
  const again = await client.login(fresh, "ada");
  check("reconnect + re-login works", again.isOk() && again[0].isOk());
  client.dispose(fresh);
}

await mf.dispose();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
