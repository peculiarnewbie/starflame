// Runs test/d1_cases.gleam in workerd against fresh local D1 databases.
// Usage: pnpm test   (runs `gleam build` first)

import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = resolve(fileURLToPath(import.meta.url), "../..");
const outfile = `${root}/build/test/d1_worker.mjs`;

await build({
  entryPoints: [`${root}/test/d1_worker.mjs`],
  outfile,
  bundle: true,
  format: "esm",
  platform: "neutral",
  logLevel: "warning",
});

const mf = new Miniflare(
  convertV4MiniflareOptions({
    modules: true,
    scriptPath: outfile,
    compatibilityDate: "2026-09-30",
    d1Databases: ["DB", "OTHER"],
  }),
);
try {
  const response = await mf.dispatchFetch("http://localhost/");
  const checks = await response.json();
  for (const { name, pass, detail } of checks) {
    console.log(`${pass ? "PASS" : "FAIL"} ${name}${pass ? "" : `\n     ${detail}`}`);
  }
  const failed = checks.filter((check) => !check.pass).length;
  console.log(`\n${checks.length - failed}/${checks.length} passed`);
  process.exitCode = failed ? 1 : 0;
} finally {
  await mf.dispose();
}
