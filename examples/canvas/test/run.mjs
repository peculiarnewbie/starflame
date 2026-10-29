// Bundles worker.ts, runs it in Miniflare, and drives the capability tree with
// raw Cap'n Web. Usage: pnpm test.

import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { newWebSocketRpcSession } from "capnweb";

const root = resolve(fileURLToPath(import.meta.url), "../..");
const outfile = `${root}/.test/worker.mjs`;

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

const options = convertV4MiniflareOptions({
  modules: true,
  scriptPath: outfile,
  compatibilityDate: "2026-09-30",
  port: 8794,
  d1Databases: ["DB"],
  durableObjects: {
    BOARD: { className: "CanvasBoard", useSQLite: true },
  },
});
const mf = new Miniflare(options);
const base = await mf.ready;
const httpBase = `http://${base.host}`;
const wsBase = `ws://${base.host}`;

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`  ${ok ? "PASS" : "FAIL"} ${name}  ${detail}`);
  if (!ok) failures++;
};
const arr = (list) => (Array.isArray(list) ? list : list.toArray?.() ?? list);
const tick = (ms = 150) => new Promise((r) => setTimeout(r, ms));

const draft = (points = [
  { x: 0.1, y: 0.2 },
  { x: 0.3, y: 0.4 },
  { x: 0.5, y: 0.6 },
]) => ({ points, color: "#7cc4ff", width: 3 });

async function newSession() {
  const response = await fetch(`${httpBase}/session`);
  assert.equal(response.status, 200);
  return (await response.json()).session;
}

async function connect(room, token) {
  return newWebSocketRpcSession(`${wsBase}/rpc?room=${room}&session=${token}`);
}

console.log("\n# Origin and sessions");
{
  const forbidden = await fetch(`${httpBase}/rpc?room=board&session=0123456789`, {
    headers: { Origin: "https://evil.example" },
  });
  check("cross-origin RPC rejected", forbidden.status === 403, String(forbidden.status));
  const anonymous = await fetch(`${httpBase}/rpc?room=board`);
  check("RPC without a session is rejected", anonymous.status === 401, String(anonymous.status));
}

const adaToken = await newSession();
const bobToken = await newSession();
const ada = await connect("board", adaToken);
const bob = await connect("board", bobToken);

console.log("\n# Capabilities");
let adaBoard;
let bobBoard;
{
  const handles = await ada.enter(false);
  adaBoard = handles.board;
  check("enter returns a board capability", adaBoard !== undefined);

  const viewHandles = await ada.enter(true);
  const view = viewHandles.board;
  check("a read-only capability can still read", Array.isArray(arr(await view.snapshot())));
  let rejected = false;
  try {
    await view.add(draft());
  } catch {
    rejected = true;
  }
  check("a read-only capability has no add method", rejected);

  const bobHandles = await bob.enter(false);
  bobBoard = bobHandles.board;
  check("another session gets its own capability", bobBoard !== undefined && bobBoard !== adaBoard);
}

console.log("\n# Drawing");
{
  const empty = await adaBoard.add(draft([]));
  check("empty strokes are refused", empty.$ === "Error" && empty[0].$ === "EmptyStroke", JSON.stringify(empty));

  const badColor = await adaBoard.add({ ...draft(), color: "#ff00ff" });
  check("colours are validated", badColor.$ === "Error" && badColor[0].$ === "BadColor");

  const added = await adaBoard.add(draft());
  check("a stroke is accepted", added.$ === "Ok", JSON.stringify(added));
  check("the server assigns an id and author", added[0].id.length === 16 && added[0].author.length === 16);
  check("points survive the round trip", JSON.stringify(arr(added[0].points)) === JSON.stringify(draft().points));

  const snapshot = arr(await adaBoard.snapshot());
  check("the stroke is in the snapshot", snapshot.length === 1 && snapshot[0].id === added[0].id);
}

console.log("\n# Live events");
{
  const events = [];
  await bobBoard.subscribe((event) => events.push(event));
  await tick();

  check("subscribing reports presence", events.some((e) => e.$ === "Presence" && e.online === 1), JSON.stringify(events));

  await adaBoard.add(draft([{ x: 0.7, y: 0.8 }, { x: 0.9, y: 0.95 }]));
  await tick();
  const posted = events.find((e) => e.$ === "StrokeAdded");
  check("the other capability receives the stroke", posted !== undefined);

  await adaBoard.clear();
  await tick();
  check("clear broadcasts", events.some((e) => e.$ === "Cleared"));
  check("clear empties the snapshot", arr(await adaBoard.snapshot()).length === 0);
}

console.log("\n# Room isolation");
{
  const otherToken = await newSession();
  const other = await connect("other", otherToken);
  const otherBoard = (await other.enter(false)).board;
  check("another room starts empty", arr(await otherBoard.snapshot()).length === 0);
  await otherBoard.add(draft());
  check("rooms don't leak", arr(await adaBoard.snapshot()).length === 0);
}

console.log("\n# Restart");
{
  await adaBoard.add(draft());
  const before = arr(await adaBoard.snapshot()).length;

  await mf.setOptions(options);
  await tick(200);

  const token = await newSession();
  const fresh = await connect("board", token);
  const board = (await fresh.enter(false)).board;
  const after = arr(await board.snapshot()).length;
  check("strokes survive a restart", after === before, `${after}/${before}`);
  const added = await board.add(draft());
  check("a new capability can draw after the restart", added.$ === "Ok");
}

await mf.dispose();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
