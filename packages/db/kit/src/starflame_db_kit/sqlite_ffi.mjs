import { Error, Ok, toList } from "../gleam.mjs";

let DatabaseSync;

/// An in-memory database that enforces foreign keys, as D1 always does.
export function open() {
  if (!DatabaseSync) {
    // Node 22 warns that node:sqlite is experimental; that's noise here.
    const emit = process.emitWarning;
    process.emitWarning = () => {};
    try {
      ({ DatabaseSync } = process.getBuiltinModule("node:sqlite"));
    } finally {
      process.emitWarning = emit;
    }
  }
  const database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys = ON");
  return database;
}

export function exec(database, sql) {
  try {
    database.exec(sql);
    return new Ok(undefined);
  } catch (error) {
    return new Error(error.message);
  }
}

export function query(database, sql, params) {
  return toList(database.prepare(sql).all(...params.toArray()));
}

export function close(database) {
  database.close();
}
