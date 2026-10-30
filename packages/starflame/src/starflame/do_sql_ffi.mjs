import { Error, Ok, toList } from "../gleam.mjs";
import { execution } from "./server.mjs";

export function database(context) {
  const state = execution(context);
  const sql = state?.storage?.sql;
  if (!sql) {
    throw new globalThis.Error(
      "do_sql needs a Durable Object with SQLite storage",
    );
  }
  return sql;
}

export function setup(database, statements) {
  return attempt(() => {
    for (const sql of statements.toArray()) database.exec(sql);
    return undefined;
  });
}

export function run(database, sql, params) {
  return attempt(() => database.exec(sql, ...bindings(params)).rowsWritten);
}

export function all(database, sql, params) {
  return attempt(() =>
    toList(database.exec(sql, ...bindings(params)).toArray()),
  );
}

export function identity(value) {
  return value;
}

export function blob(bits) {
  if (bits.bitOffset !== 0 || bits.bitSize % 8 !== 0) {
    throw new globalThis.Error("do_sql blobs must be byte-aligned");
  }
  const bytes = new Uint8Array(bits.byteSize);
  for (let i = 0; i < bits.byteSize; i++) bytes[i] = bits.byteAt(i);
  return bytes;
}

export function null_() {
  return null;
}

function bindings(params) {
  return params.toArray();
}

function attempt(run) {
  try {
    return new Ok(run());
  } catch (error) {
    return new Error(String(error?.message ?? error));
  }
}
