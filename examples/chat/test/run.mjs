// Bundles worker.ts, runs it in Miniflare, and drives the room over HTTP RPC
// plus a raw hibernating WebSocket. Usage: pnpm test.

import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import * as client from "../build/dev/javascript/chat/chat/generated/client.mjs";
import * as codecs from "../build/dev/javascript/chat/chat/codecs.mjs";

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
  port: 8795,
  durableObjects: {
    CHAT: { className: "ChatRoom", useSQLite: true },
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
const ok = (reply) => reply.isOk() && reply[0].isOk();
const errorName = (reply) =>
  reply.isOk() && !reply[0].isOk() ? reply[0][0].constructor.name : null;
const arr = (list) => (Array.isArray(list) ? list : list.toArray());
const tick = (ms = 150) => new Promise((r) => setTimeout(r, ms));

async function newSession() {
  const response = await fetch(`${httpBase}/session`);
  assert.equal(response.status, 200);
  return (await response.json()).session;
}

async function openRpc(room, token) {
  return client.connect_http(`${httpBase}/rpc?room=${room}&session=${token}`);
}

function openSocket(room, token, name) {
  const socket = new WebSocket(
    `${wsBase}/socket?room=${room}&session=${token}&name=${encodeURIComponent(name)}`,
  );
  const events = [];
  socket.onmessage = (event) => {
    // Decode with the same generated codec the browser uses.
    events.push(codecs.room_event_from_plain(JSON.parse(event.data)));
  };
  return { socket, events };
}

const eventName = (event) => event.constructor.name;

console.log("\n# Origin and sessions");
{
  const forbidden = await fetch(`${httpBase}/rpc?room=lobby&session=0123456789`, {
    headers: { Origin: "https://evil.example" },
  });
  check("cross-origin RPC rejected", forbidden.status === 403, String(forbidden.status));
  const anonymous = await fetch(`${httpBase}/rpc?room=lobby`);
  check("RPC without a session is rejected", anonymous.status === 401, String(anonymous.status));
  const anonymousSocket = new WebSocket(`${wsBase}/socket?room=lobby`);
  const outcome = await new Promise((resolve) => {
    anonymousSocket.onerror = () => resolve("error");
    anonymousSocket.onclose = () => resolve("close");
    anonymousSocket.onopen = () => resolve("open");
    setTimeout(() => resolve("timeout"), 2000);
  });
  check("socket without a session is rejected", outcome !== "open", outcome);
}

const adaToken = await newSession();
const bobToken = await newSession();
const ada = await openRpc("lobby", adaToken);
const bob = await openRpc("lobby", bobToken);

console.log("\n# Validation");
{
  const empty = await client.send(ada, "Ada", "   ");
  check("empty messages are refused", errorName(empty) === "EmptyMessage", errorName(empty));
  const long = await client.send(ada, "Ada", "x".repeat(501));
  check("oversize messages are refused", errorName(long) === "MessageTooLong", errorName(long));
  const unnamed = await client.send(ada, "  ", "hello");
  check("blank names are refused", errorName(unnamed) === "EmptyName", errorName(unnamed));
}

console.log("\n# Sockets and presence");
const adaSocket = openSocket("lobby", adaToken, "Ada");
await tick(300);
{
  const presence = adaSocket.events.find((e) => eventName(e) === "Presence");
  check("the socket receives presence on connect", presence !== undefined);
  check("presence counts this socket", presence && presence.online === 1, String(presence?.online));

  const bobSocket = openSocket("lobby", bobToken, "Bob");
  await tick(300);
  const latest = [...adaSocket.events].reverse().find((e) => eventName(e) === "Presence");
  check("a second socket raises presence", latest && latest.online === 2, String(latest?.online));

  console.log("\n# Messages");
  const sent = await client.send(bob, "Bob", "hello from bob");
  check("send succeeds", ok(sent), JSON.stringify(sent));
  const message = sent[0][0];
  check("the reply carries the message", message.body === "hello from bob" && message.name === "Bob");

  await tick(200);
  const posted = adaSocket.events.find((e) => eventName(e) === "MessagePosted");
  check("the other socket receives the typed event", posted !== undefined && posted.message.body === "hello from bob");

  const history = await client.history(ada);
  check("history contains the message", history.isOk() && arr(history[0]).some((m) => m.id === message.id));
  check("history is ordered oldest first", history.isOk() && arr(history[0]).at(-1).id === message.id);

  bobSocket.socket.close();
  await tick(300);
  const afterClose = [...adaSocket.events].reverse().find((e) => eventName(e) === "Presence");
  check("closing a socket lowers presence", afterClose && afterClose.online === 1, String(afterClose?.online));
}

console.log("\n# Room isolation");
{
  const otherToken = await newSession();
  const other = await openRpc("other", otherToken);
  const otherHistory = await client.history(other);
  check("another room starts empty", otherHistory.isOk() && arr(otherHistory[0]).length === 0);
  const otherSend = await client.send(other, "Eve", "elsewhere");
  check("another room accepts messages", ok(otherSend));
  const lobby = await client.history(ada);
  check("rooms don't leak", lobby.isOk() && arr(lobby[0]).every((m) => m.room === "lobby"));
  client.dispose(other);
}

console.log("\n# Restart and reconnect");
{
  const before = await client.history(ada);
  const count = arr(before[0]).length;

  await mf.setOptions(options); // restarts workerd, like a deploy
  await tick(200);

  const token = await newSession();
  const fresh = await openRpc("lobby", token);
  const history = await client.history(fresh);
  check("history survives a restart", history.isOk() && arr(history[0]).length === count, String(arr(history[0])?.length));

  // No DO memory is needed to resume: a new socket just needs the room and name.
  const socket = openSocket("lobby", token, "Cara");
  await tick(300);
  check("a new socket works after a restart", socket.events.some((e) => eventName(e) === "Presence"));
  check("presence starts at one after the restart", socket.events[0]?.online === 1, String(socket.events[0]?.online));

  const sent = await client.send(fresh, "Cara", "after restart");
  check("sending still works", ok(sent));
  await tick(200);
  check("the new socket receives new messages", socket.events.some((e) => eventName(e) === "MessagePosted"));
  socket.socket.close();
  client.dispose(fresh);
}

try { client.dispose(ada); } catch {}
try { client.dispose(bob); } catch {}
adaSocket.socket.close();
await mf.dispose();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
