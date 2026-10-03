import { toList } from "../gleam.mjs";
import { env } from "./server.mjs";

const ready = new WeakMap();

export function database(context, binding) {
  const database = env(context)[binding];
  if (!database) throw new Error(`No D1 binding named ${binding}`);
  return database;
}

export function setup(database, statements) {
  let pending = ready.get(database);
  if (!pending) {
    pending = database
      .batch(statements.toArray().map((sql) => database.prepare(sql)))
      .then(() => undefined);
    // Retry on the next request if setup failed.
    pending.catch(() => ready.delete(database));
    ready.set(database, pending);
  }
  return pending;
}

export async function all(database, sql, params) {
  const { results } = await database
    .prepare(sql)
    .bind(...params.toArray())
    .all();
  return toList(results);
}

export async function run(database, sql, params) {
  const { meta } = await database
    .prepare(sql)
    .bind(...params.toArray())
    .run();
  return meta.changes;
}
