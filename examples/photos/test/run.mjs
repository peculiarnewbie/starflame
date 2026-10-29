// Bundles worker.ts, runs it in Miniflare, then uploads through the generated
// client. Usage: pnpm test (runs `gleam build` first).

import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import * as client from "../build/dev/javascript/photos/photos/generated/client.mjs";
import { BitArray } from "../build/dev/javascript/prelude.mjs";

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
  port: 8797,
  d1Databases: ["DB"],
  r2Buckets: ["BUCKET"],
});
const mf = new Miniflare(options);
const base = await mf.ready;
const httpBase = `http://${base.host}`;

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`  ${ok ? "PASS" : "FAIL"} ${name}  ${detail}`);
  if (!ok) failures++;
};
const ok = (reply) => reply.isOk() && reply[0].isOk();
const gameError = (reply) => (reply.isOk() && !reply[0].isOk() ? reply[0][0] : null);
const errorName = (reply) => gameError(reply)?.constructor?.name ?? null;
const arr = (list) => (Array.isArray(list) ? list : list.toArray());
const bits = (bytes) => new BitArray(new Uint8Array(bytes));
const bytesOf = (value) =>
  Array.from({ length: value.byteSize }, (_, i) => value.byteAt(i));

async function newSession() {
  const response = await fetch(`${httpBase}/session`);
  assert.equal(response.status, 200);
  return (await response.json()).session;
}

async function open() {
  const token = await newSession();
  const socket = client.connect_http(`${httpBase}/rpc?session=${token}`);
  return { token, client: socket };
}

const ada = await open();
const bob = await open();

console.log("\n# Origin and routing");
{
  const forbidden = await fetch(`${httpBase}/rpc?session=0123456789`, {
    headers: { Origin: "https://evil.example" },
  });
  check("cross-origin RPC rejected", forbidden.status === 403, String(forbidden.status));
  const anonymous = await fetch(`${httpBase}/rpc`);
  check("RPC without a session is rejected", anonymous.status === 401, String(anonymous.status));
}

console.log("\n# Validation");
{
  const empty = await client.upload(ada.client, "empty.png", "image/png", bits([]));
  check("empty files are refused", errorName(empty) === "EmptyFile", errorName(empty));

  const svg = await client.upload(ada.client, "x.svg", "image/svg+xml", bits([1]));
  check("unsupported types are refused", errorName(svg) === "UnsupportedType", errorName(svg));

  const big = await client.upload(ada.client, "big.png", "image/png", bits(new Uint8Array(2_000_001)));
  check("oversize files are refused", errorName(big) === "TooLarge", errorName(big));

  const unnamed = await client.upload(ada.client, "   ", "image/png", bits([1]));
  check("blank names are refused", errorName(unnamed) === "EmptyName", errorName(unnamed));
}

// A PNG signature plus non-UTF-8 bytes, so a base64 accident would show.
const payload = [0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x80, 0x01, 0x02];
let id;
console.log("\n# Upload and round trip");
{
  const uploaded = await client.upload(ada.client, "pixel.png", "image/png", bits(payload));
  check("upload succeeds", ok(uploaded), JSON.stringify(uploaded));
  const photo = uploaded[0][0];
  id = photo.id;
  check("metadata is stored", photo.name === "pixel.png" && photo.size === payload.length);
  check("the owner is the session's player", photo.owner.length === 16);

  const list = await client.list_photos(ada.client);
  check("the list contains the photo", list.isOk() && arr(list[0]).some((p) => p.id === id));

  const round = await client.bytes(ada.client, id);
  check("bytes round-trip through RPC", ok(round) && JSON.stringify(bytesOf(round[0][0])) === JSON.stringify(payload));

  const served = await fetch(`${httpBase}/photos/${id}`);
  check("R2 serves the object", served.status === 200, String(served.status));
  check("content type is preserved", served.headers.get("content-type") === "image/png", served.headers.get("content-type") ?? "");
  const body = new Uint8Array(await served.arrayBuffer());
  check("R2 bytes match the upload", JSON.stringify(Array.from(body)) === JSON.stringify(payload));
}

console.log("\n# Ownership");
{
  const me = await client.me(bob.client);
  check("me returns the caller", me.isOk() && me[0].length === 16);

  const stolen = await client.delete$(bob.client, id);
  check("another session can't delete", errorName(stolen) === "NotYours", errorName(stolen));

  const removed = await client.delete$(ada.client, id);
  check("the owner can delete", ok(removed), JSON.stringify(removed));

  const gone = await fetch(`${httpBase}/photos/${id}`);
  check("the object is gone from R2", gone.status === 404, String(gone.status));

  const missing = await client.bytes(ada.client, id);
  check("bytes reports a missing photo", errorName(missing) === "NotFound", errorName(missing));
}

console.log("\n# Persistence");
{
  await mf.setOptions(options);
  await new Promise((r) => setTimeout(r, 100));
  const after = await open();
  const list = await client.list_photos(after.client);
  check("the list survives a restart", list.isOk(), JSON.stringify(list));
  check("the deleted photo stays deleted", list.isOk() && arr(list[0]).every((p) => p.id !== id));
}

client.dispose(ada.client);
client.dispose(bob.client);
await mf.dispose();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
