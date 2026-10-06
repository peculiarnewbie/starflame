// Applies unapplied migrations to the dev server's local D1, recording them
// in d1_migrations as wrangler does. `cf d1 migrations apply` needs a
// database ID, which the local database doesn't have.
// Usage: pnpm migrate:local   (with `pnpm dev` running)

import { readFile, readdir } from "node:fs/promises";

const origin = process.argv[2] ?? "http://localhost:5173";
const database = "DB-starflame-notes";
const endpoint = `${origin}/cdn-cgi/local/explorer/api/d1/database/${database}/raw`;

async function query(sql) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sql }),
  }).catch(() => {
    throw new Error(`Couldn't reach ${origin}: is \`pnpm dev\` running?`);
  });
  const body = await response.json();
  if (!body.success) throw new Error(JSON.stringify(body.errors));
  return body.result;
}

await query(
  "CREATE TABLE IF NOT EXISTS d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, " +
    "name TEXT UNIQUE, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)",
);
const [applied] = await query("SELECT name FROM d1_migrations");
const done = new Set(applied.results.rows.map(([name]) => name));

const files = (await readdir(new URL("../migrations", import.meta.url))).filter((f) => f.endsWith(".sql")).sort();
for (const name of files) {
  if (done.has(name)) continue;
  const sql = await readFile(new URL(`../migrations/${name}`, import.meta.url), "utf8");
  const quoted = name.replaceAll("'", "''");
  await query(`${sql}\nINSERT INTO d1_migrations (name) VALUES ('${quoted}');`);
  console.log(`Applied ${name}`);
}
console.log(done.size === files.length ? "No migrations to apply." : "Done.");
