import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { gleam } from "../src/index.js";

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "starflame-vite-"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "gleam"), `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync("commands.jsonl", JSON.stringify(args) + "\\n");
const command = args[0] === "run" ? args[args.indexOf("--") + 1] : args[0];
if (fs.existsSync("fail-" + command)) {
  console.error("Run \\x60gleam run -m starflame_rpc_kit -- codecs\\x60.");
  process.exitCode = 1;
}
`, { mode: 0o755 });
  const path = process.env.PATH;
  process.env.PATH = `${bin}:${path}`;
  t.after(() => {
    process.env.PATH = path;
    rmSync(root, { recursive: true, force: true });
  });
  writeFileSync(join(root, "gleam.toml"), '[dev-dependencies]\nstarflame_rpc_kit = { path = "kit" }\n[starflame]\ncodecs = ["app/state:app/codecs"]\n');
  const plugin = gleam({ rpc: { api: "app/rpc", out: "app/generated" } });
  const context = { error(message) { throw new Error(message); } };
  const commands = () => readFileSync(join(root, "commands.jsonl"), "utf8")
    .trim().split("\n").map(JSON.parse);
  return { root, plugin, context, commands };
}

test("dev generates RPC, then configured codecs without RPC flags, then builds", async (t) => {
  const { root, plugin, context, commands } = fixture(t);
  plugin.configResolved({ root, command: "serve" });
  await plugin.buildStart.call(context);
  const calls = commands();
  assert.deepEqual(calls[0].slice(-5), ["generate", "--api", "app/rpc", "--out", "app/generated"]);
  assert.equal(calls[1].at(-1), "codecs");
  assert.equal(calls[1].includes("--api"), false);
  assert.deepEqual(calls[2], ["build"]);
});

test("codecs failure reports its error and stops before gleam build", async (t) => {
  const { root, plugin, context, commands } = fixture(t);
  const errors = t.mock.method(console, "error", () => {});
  writeFileSync(join(root, "fail-codecs"), "");
  plugin.configResolved({ root, command: "serve" });
  await assert.rejects(plugin.buildStart.call(context), /gleam build failed/);
  assert.equal(commands().length, 2);
  assert.match(errors.mock.calls[0].arguments[0], /codecs failed/);
});

test("production checks freshness and errors with the codecs command", async (t) => {
  const { root, plugin, context, commands } = fixture(t);
  t.mock.method(console, "error", () => {});
  writeFileSync(join(root, "fail-check"), "");
  plugin.configResolved({ root, command: "build" });
  await assert.rejects(plugin.buildStart.call(context), /gleam run -m starflame_rpc_kit -- codecs/);
  assert.equal(commands().length, 1);
  assert.equal(commands()[0].includes("check"), true);
});

test("dev watches codecs dependencies outside the API closure and gleam.toml", async (t) => {
  const { root, plugin, context, commands } = fixture(t);
  plugin.configResolved({ root, command: "serve" });
  await plugin.buildStart.call(context);
  const metadata = join(root, "build/starflame_rpc_kit");
  mkdirSync(metadata, { recursive: true });
  writeFileSync(join(metadata, "sources.json"), JSON.stringify({ sources: ["src/app/rpc.gleam"] }));
  writeFileSync(join(metadata, "codecs-sources.json"), JSON.stringify({ "app/state": ["src/app/state.gleam", "src/app/nested.gleam"] }));
  let change;
  let reloads = 0;
  const watched = [];
  plugin.configureServer({
    watcher: { add(path) { watched.push(path); }, on(_event, fn) { change = fn; } },
    environments: { client: {
      moduleGraph: { idToModuleMap: new Map() },
      hot: { send() { reloads++; } },
    } },
  });
  assert.equal(watched.includes(join(root, "gleam.toml")), true);
  await change(join(root, "src/app/nested.gleam"));
  await change(join(root, "gleam.toml"));
  assert.equal(reloads, 2);
  assert.equal(commands().length, 9);
  assert.equal(commands()[3].includes("generate"), true);
  assert.equal(commands()[4].at(-1), "codecs");
});
