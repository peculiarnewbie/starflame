// Runs worker.ts in Miniflare with the migrations applied, signs two users in
// with email codes, then drives the generated Gleam client over HTTP as each
// of them.
// Usage: pnpm test   (checks generated code and runs `gleam build` first)

import { build } from "esbuild";
import { Log, LogLevel, Miniflare, convertV4MiniflareOptions } from "miniflare";
import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = resolve(fileURLToPath(import.meta.url), "../..");
const outfile = `${root}/build/test-worker.mjs`;

await build({
  entryPoints: [`${root}/worker.ts`],
  outfile,
  bundle: true,
  format: "esm",
  platform: "neutral",
  conditions: ["workerd", "worker", "import"],
  mainFields: ["module", "main"],
  external: ["cloudflare:*", "node:*"],
  logLevel: "warning",
});

// The local send_email binding logs each message, a line at a time, just
// after sending it. The code is in the subject.
const logged = [];
class EmailLog extends Log {
  logWithLevel(level, message) {
    logged.push(message);
  }
}

async function codeFor(email, since) {
  for (let tries = 0; tries < 50; tries++) {
    const text = logged.slice(since).join("\n");
    const to = text.lastIndexOf(`To: ${email}`);
    const code = to === -1 ? null : /Subject: (\d{6}) /.exec(text.slice(to))?.[1];
    if (code) return code;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`No code was emailed to ${email}`);
}

const mf = new Miniflare(
  convertV4MiniflareOptions({
    modules: true,
    scriptPath: outfile,
    compatibilityDate: "2026-09-30",
    compatibilityFlags: ["nodejs_compat"],
    kvNamespaces: ["AUTH"],
    d1Databases: ["DB"],
    bindings: { GOOGLE_CLIENT_ID: "", EMAIL_FROM: "login@notes.example" },
    email: { send_email: [{ name: "EMAIL" }] },
    log: new EmailLog(LogLevel.INFO),
  }),
);
const base = (await mf.ready).origin;

// The migrations have no semicolons inside strings, so splitting is simple.
const database = await mf.getD1Database("DB");
for (const name of (await readdir(`${root}/migrations`)).sort()) {
  const sql = (await readFile(`${root}/migrations/${name}`, "utf8")).replace(/--.*$/gm, "");
  const statements = sql.split(";").map((s) => s.trim()).filter(Boolean);
  await database.batch(statements.map((s) => database.prepare(s)));
}

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`  ${ok ? "PASS" : "FAIL"} ${name}${detail ? `  ${detail}` : ""}`);
  if (!ok) failures++;
};

// Signs in with a code the way a browser would, returning its cookies.
async function signIn(email) {
  const jar = new Map();
  const send = async (path, init = {}) => {
    const headers = new Headers(init.headers);
    headers.set("Cookie", [...jar].map(([k, v]) => `${k}=${v}`).join("; "));
    const response = await mf.dispatchFetch(new URL(path, base), { ...init, headers, redirect: "manual" });
    for (const cookie of response.headers.getSetCookie()) {
      const pair = cookie.split(";")[0];
      const index = pair.indexOf("=");
      jar.set(pair.slice(0, index), pair.slice(index + 1));
    }
    return response;
  };
  const form = (fields) =>
    send("/code/authorize", {
      method: "POST",
      body: new URLSearchParams(fields),
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  let response = await send("/auth/login?provider=code");
  while (response.status === 302) response = await send(response.headers.get("Location"));
  const since = logged.length;
  await form({ action: "request", email });
  const code = await codeFor(email.toLowerCase(), since);
  const verified = await form({ action: "verify", code });
  await send(verified.headers.get("Location"));
  return [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
}

// The browser's fetch, as the signed-in user with `cookie`.
const realFetch = globalThis.fetch;
function as(cookie) {
  globalThis.fetch = (input, init = {}) =>
    mf.dispatchFetch(new URL(input, base), {
      ...init,
      headers: { ...init.headers, Cookie: cookie, Origin: base },
    });
}

const client = await import(`${root}/build/dev/javascript/notes/notes/generated/client.mjs`);
const shared = await import(`${root}/build/dev/javascript/notes/notes/shared.mjs`);
const api = client.connect_http("/rpc");

console.log("\n# Signed out");
{
  as("");
  const reply = await client.me(api);
  check("the API is 401 when signed out", !reply.isOk() && reply[0].status === 401, reply[0]?.constructor.name);
  const crossSite = await mf.dispatchFetch(`${base}/rpc`, { method: "POST", headers: { Origin: "https://evil.example" }, body: "" });
  check("cross-site calls are refused", crossSite.status === 403);
}

console.log("\n# Notes");
const ada = await signIn("ada@example.com");
const bob = await signIn("bob@example.com");
{
  as(ada);
  const me = await client.me(api);
  check("me is the signed-in user", me.isOk() && me[0][0].email === "ada@example.com", me[0]?.[0]?.email);

  const added = await client.add_note(api, "  Buy milk  ");
  const note = added[0]?.[0];
  check("add_note trims and stores", added.isOk() && added[0].isOk() && note.body === "Buy milk", note?.body);

  const empty = await client.add_note(api, "   ");
  check("empty notes are refused", empty.isOk() && shared.NotesError$isEmptyNote(empty[0][0]));

  const listed = await client.list_notes(api);
  check("list_notes returns them", listed.isOk() && listed[0][0].toArray().length === 1);

  as(bob);
  const theirs = await client.list_notes(api);
  check("other users don't see them", theirs.isOk() && theirs[0][0].toArray().length === 0);
  const stolen = await client.delete_note(api, note.id);
  check("other users can't delete them", stolen.isOk() && shared.NotesError$isNoteNotFound(stolen[0][0]));

  as(ada);
  const deleted = await client.delete_note(api, note.id);
  check("delete_note removes it", deleted.isOk() && deleted[0].isOk());
  const after = await client.list_notes(api);
  check("and it's gone", after.isOk() && after[0][0].toArray().length === 0);

  const again = await signIn("ADA@example.com");
  as(again);
  const same = await client.me(api);
  check("the same address signs into the same account", same[0]?.[0]?.id === me[0][0].id);
}

globalThis.fetch = realFetch;
await mf.dispose();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
