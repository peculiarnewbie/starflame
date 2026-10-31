import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { CloudflareStorage } from "@openauthjs/openauth/storage/cloudflare";
import { joinKey } from "@openauthjs/openauth/storage/storage";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { createKVStorage } from "../src/starflame_openauth_kv.mjs";

let mf;
let namespace;
before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({
    modules: true,
    script: "export default { fetch() { return new Response('ok'); } };",
    compatibilityDate: "2026-09-30",
    kvNamespaces: ["AUTH"],
  }));
  namespace = await mf.getKVNamespace("AUTH");
});
after(async () => { await mf?.dispose(); });

function clock(t) {
  let now = Date.now();
  t.mock.method(Date, "now", () => now);
  return { get now() { return now; }, advance(ms) { now += ms; } };
}

test("a one-millisecond delay does not break a 60-second authorization-code write", async (t) => {
  const time = clock(t);
  const expiry = new Date(time.now + 60_000);
  time.advance(1);
  const key = ["oauth:code", "delayed"];
  const value = { subject: "ada", pkce: { challenge: "challenge" } };
  const storage = createKVStorage(namespace);
  await storage.set(key, value, expiry);
  assert.deepEqual(await storage.get(key), value);
});

test("short-lived credentials expire at their exact deadline even while KV retains them", async (t) => {
  const time = clock(t);
  const expiry = new Date(time.now + 2_000);
  const key = ["oauth:refresh", "short-lived"];
  const value = { subject: "ada", timeUsed: time.now };
  const storage = createKVStorage(namespace);
  await storage.set(key, value, expiry);
  time.advance(1_999);
  assert.deepEqual(await storage.get(key), value);
  time.advance(1);
  assert.equal(await storage.get(key), undefined);
  // Expiration must come from the adapter, not a real-time wait or KV deletion.
  assert.deepEqual(await namespace.get(joinKey(key), "json"), value);
  assert.deepEqual(await Array.fromAsync(storage.scan(["oauth:refresh"])), []);
});

test("legacy OpenAuth values and key names remain readable and removable", async () => {
  const legacy = CloudflareStorage({ namespace });
  const key = ["oauth:refresh", "user:ada@example.com", "legacy-token"];
  const other = ["oauth:refresh", "user:ada@example.com", "other-token"];
  const value = { properties: { id: "ada" }, nextToken: "next" };
  await legacy.set(key, value, new Date(Date.now() + 120_000));
  await legacy.set(other, value);
  const storage = createKVStorage(namespace);
  assert.deepEqual(await storage.get(key), value);
  assert.deepEqual(await Array.fromAsync(storage.scan(key.slice(0, -1))), [
    [key, value], [other, value],
  ]);
  await storage.remove(key);
  assert.equal(await legacy.get(key), undefined);
  assert.deepEqual(await legacy.get(other), value);
});

test("rewriting without an expiry clears the previous deadline", async (t) => {
  const time = clock(t);
  const key = ["signing:key", "rewritten"];
  const storage = createKVStorage(namespace);
  await storage.set(key, { version: 1 }, new Date(time.now + 2_000));
  await storage.set(key, { version: 2 });
  time.advance(3_000);
  assert.deepEqual(await storage.get(key), { version: 2 });
  const page = await namespace.list({ prefix: joinKey(key) });
  assert.equal(page.keys[0].expiration, undefined);
});

test("writing an already-expired credential removes its previous value", async (t) => {
  const time = clock(t);
  const key = ["oauth:code", "expired-replacement"];
  const storage = createKVStorage(namespace);
  await storage.set(key, { subject: "ada" });
  await storage.set(key, { subject: "bob" }, new Date(time.now));
  assert.equal(await storage.get(key), undefined);
  assert.equal(await namespace.get(joinKey(key)), null);
});

test("an invalid deadline cannot accidentally turn a credential into a permanent value", async () => {
  const key = ["oauth:code", "invalid-deadline"];
  const storage = createKVStorage(namespace);
  await storage.set(key, { subject: "ada" });
  await assert.rejects(storage.set(key, { subject: "bob" }, new Date(NaN)), /Invalid.*expiry/);
  assert.deepEqual(await storage.get(key), { subject: "ada" });
});

test("scans skip expired credentials and continue through an empty filtered page", async (t) => {
  const time = clock(t);
  const paginated = {
    get: (...args) => namespace.get(...args),
    getWithMetadata: (...args) => namespace.getWithMetadata(...args),
    put: (...args) => namespace.put(...args),
    delete: (...args) => namespace.delete(...args),
    list: (options) => namespace.list({ ...options, limit: 2 }),
  };
  const storage = createKVStorage(paginated);
  const prefix = ["scan-expiry"];
  for (const name of ["a", "b"]) {
    await storage.set([...prefix, name], { name }, new Date(time.now + 2_000));
  }
  await storage.set([...prefix, "c"], { name: "c" }, new Date(time.now + 300_000));
  await storage.set([...prefix, "d"], { name: "d" });
  await storage.set(["other-prefix"], { name: "other" });
  await storage.set(["scan-expiry-other", "x"], { name: "sibling" });
  time.advance(2_000);
  assert.deepEqual(await Array.fromAsync(storage.scan(prefix)), [
    [[...prefix, "c"], { name: "c" }],
    [[...prefix, "d"], { name: "d" }],
  ]);
});
