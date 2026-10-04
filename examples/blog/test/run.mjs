// Applies the committed migration history to local D1, seeds data before the
// custom backfill, then exercises generated Gleam CRUD in workerd.

import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

export function splitStatements(sql) {
  const statements = [];
  let current = "";
  let quote = null;
  let comment = false;

  for (let i = 0; i < sql.length; i++) {
    const char = sql[i];
    const next = sql[i + 1];
    if (comment) {
      if (char === "\n") {
        current += " ";
        comment = false;
      }
      continue;
    }
    if (quote !== null) {
      current += char;
      if (char === quote && next === quote) {
        current += next;
        i++;
      } else if (char === quote) {
        quote = null;
      }
      continue;
    }
    if ((char === "'" || char === '"') && quote === null) {
      quote = char;
      current += char;
    } else if (char === "-" && next === "-") {
      comment = true;
      current += " ";
      i++;
    } else if (char === ";") {
      const statement = current.trim();
      if (statement !== "") statements.push(statement);
      current = "";
    } else {
      current += char;
    }
  }

  const tail = current.trim();
  if (tail !== "") statements.push(tail);
  return statements;
}

const splitSample = `-- header comment; ignored
INSERT INTO posts (title, body) VALUES ('one; two', "column;name"); -- inline; ignored
UPDATE posts SET body = 'it''s; still text' WHERE id = 1;
SELECT "escaped "";"" quote" AS "semi;colon";` + "   \n-- trailing comment; ignored   ";
assert.deepEqual(splitStatements(splitSample), [
  `INSERT INTO posts (title, body) VALUES ('one; two', "column;name")`,
  `UPDATE posts SET body = 'it''s; still text' WHERE id = 1`,
  `SELECT "escaped "";"" quote" AS "semi;colon"`,
]);
console.log("PASS migration statement splitter: comments, quoted semicolons, escaped quotes, whitespace");

const root = resolve(fileURLToPath(import.meta.url), "../..");
const outfile = resolve(root, "build/test/blog_worker.mjs");
await build({
  entryPoints: [resolve(root, "test/worker.mjs")],
  outfile,
  bundle: true,
  format: "esm",
  platform: "neutral",
  conditions: ["workerd", "worker", "import"],
  mainFields: ["module", "main"],
  external: ["cloudflare:*"],
  logLevel: "warning",
});

const mf = new Miniflare(
  convertV4MiniflareOptions({
    rootPath: root,
    modules: true,
    scriptPath: outfile,
    compatibilityDate: "2026-09-30",
    d1Databases: ["DB"],
  }),
);

try {
  const database = await mf.getD1Database("DB");
  await database.exec(
    "CREATE TABLE IF NOT EXISTS d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
  );

  const files = (await readdir(resolve(root, "migrations")))
    .filter((name) => name.endsWith(".sql"))
    .sort();
  assert.deepEqual(files, [
    "0001_init.sql",
    "0002_add_slug.sql",
    "0003_rename.sql",
    "0004_backfill.sql",
    "0005_check.sql",
  ]);

  const apply = async (name) => {
    const sql = await readFile(resolve(root, "migrations", name), "utf8");
    const statements = splitStatements(sql);
    assert.ok(statements.length > 0, `${name} must contain SQL`);
    await database.batch([
      ...statements.map((statement) => database.prepare(statement)),
      database.prepare("INSERT INTO d1_migrations (name) VALUES (?)").bind(name),
    ]);
  };

  for (const name of files.slice(0, 3)) await apply(name);
  await database.batch([
    database.prepare(
      "INSERT INTO users (id, email, display_name, admin, created_at, bio) VALUES (?, ?, ?, ?, ?, ?)",
    ).bind(10, "ada@example.com", "Ada", 1, 1_725_000_000, "seed bio"),
    database.prepare(
      "INSERT INTO posts (id, user_id, title, slug, body, type, rating) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).bind(20, 10, "Hello World", "pending", "seed body", "article", 4.5),
    database.prepare(
      "INSERT INTO comments (id, post_id, editor_id, body) VALUES (?, ?, ?, ?)",
    ).bind(30, 20, 10, "seed comment"),
  ]);

  await apply(files[3]);
  assert.deepEqual(
    await database.prepare("SELECT slug FROM posts WHERE id = 20").first(),
    { slug: "hello-world" },
  );
  console.log("PASS custom backfill changed the seeded title into its slug");

  await apply(files[4]);
  assert.deepEqual(
    await database
      .prepare("SELECT email, display_name, admin, created_at, bio FROM users WHERE id = 10")
      .first(),
    {
      email: "ada@example.com",
      display_name: "Ada",
      admin: 1,
      created_at: 1_725_000_000,
      bio: "seed bio",
    },
  );
  assert.deepEqual(
    await database
      .prepare("SELECT user_id, title, slug, body, type, rating FROM posts WHERE id = 20")
      .first(),
    {
      user_id: 10,
      title: "Hello World",
      slug: "hello-world",
      body: "seed body",
      type: "article",
      rating: 4.5,
    },
  );
  assert.deepEqual(
    await database
      .prepare("SELECT post_id, editor_id, body FROM comments WHERE id = 30")
      .first(),
    { post_id: 20, editor_id: 10, body: "seed comment" },
  );
  assert.deepEqual(
    (await database.prepare("PRAGMA foreign_key_check").all()).results,
    [],
  );
  console.log("PASS 0005 closure rebuild preserved seeded users, posts, comments, and editor references");

  const applied = await database.prepare("SELECT name FROM d1_migrations ORDER BY id").all();
  assert.deepEqual(applied.results.map(({ name }) => name), files);

  const response = await mf.dispatchFetch("http://localhost/");
  assert.equal(response.status, 200);
  const checks = await response.json();
  for (const { name, pass, detail } of checks) {
    console.log(`${pass ? "PASS" : "FAIL"} ${name}${pass ? "" : `\n     ${detail}`}`);
  }
  const failed = checks.filter((check) => !check.pass).length;
  console.log(`\n${checks.length - failed}/${checks.length} Gleam D1 cases passed`);
  process.exitCode = failed ? 1 : 0;
} finally {
  await mf.dispose();
}
