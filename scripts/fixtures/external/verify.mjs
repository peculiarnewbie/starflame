import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import * as rpc from "./build/dev/javascript/starflame_external_check/ext/generated/client.mjs";
import { clear } from "./build/dev/javascript/starflame_external_check/ext/app.mjs";
import { Note } from "./build/dev/javascript/starflame_external_check/ext/shared.mjs";

await build({
  entryPoints: ["worker.ts"],
  outfile: "build/worker.mjs",
  bundle: true,
  format: "esm",
  platform: "neutral",
  logLevel: "warning",
});
const mf = new Miniflare(convertV4MiniflareOptions({
  modules: true,
  scriptPath: "build/worker.mjs",
  compatibilityDate: "2026-09-30",
}));
let api;
let board;
try {
  const base = await mf.ready;
  api = rpc.connect(`ws://${base.host}/rpc`);
  const entered = await rpc.enter(api);
  assert.equal(entered.isOk(), true);
  board = entered[0];
  const cleared = await clear(board);
  assert.equal(cleared.isOk(), true);
  assert.equal(cleared[0].isOk(), true);
  const events = [];
  assert.equal((await rpc.board_subscribe(board, (note) => events.push(note))).isOk(), true);
  assert.equal((await rpc.board_publish(board, new Note(1, "typed callback"))).isOk(), true);
  for (let attempt = 0; events.length === 0 && attempt < 50; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.equal(events.length, 1);
  assert.equal(events[0].id, 1);
  assert.equal(events[0].body, "typed callback");
  console.log("External generated client: typed Clear and retained callbacks passed");
} finally {
  if (board) rpc.board_dispose(board);
  if (api) rpc.dispose(api);
  await mf.dispose();
}
