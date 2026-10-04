import { BitArray, Error, Ok, toList } from "../gleam.mjs";
import { env } from "./server.mjs";

const ready = new WeakMap();

export function database(context, binding) {
  const database = env(context)[binding];
  if (!database) throw new globalThis.Error(`No D1 binding named ${binding}`);
  return database;
}

export function setup(database, statements) {
  let pending = ready.get(database);
  if (!pending) {
    pending = attempt(() =>
      database
        .batch(statements.toArray().map((sql) => database.prepare(sql)))
        .then(() => undefined),
    );
    // Retry on the next call if setup failed.
    pending.then((result) => {
      if (!result.isOk()) ready.delete(database);
    });
    ready.set(database, pending);
  }
  return pending;
}

export function all(database, sql, bindings) {
  return attempt(async () => {
    const { results } = await prepare(database, sql, bindings).all();
    return toList(results);
  });
}

export function raw(database, sql, bindings) {
  return attempt(async () =>
    toList(await prepare(database, sql, bindings).raw()),
  );
}

export function run(database, sql, bindings) {
  return attempt(async () => {
    const { meta } = await prepare(database, sql, bindings).run();
    return meta.changes;
  });
}

export function batch(database, statements) {
  return attempt(async () => {
    const results = await database.batch(
      statements
        .toArray()
        .map(([sql, bindings]) => prepare(database, sql, bindings)),
    );
    return toList(
      results.map(({ results, meta }) => [toList(results ?? []), meta.changes]),
    );
  });
}

function prepare(database, sql, bindings) {
  return database.prepare(sql).bind(...bindings.toArray());
}

/// Resolves to Ok(value) or Error(message), where the message is D1's cause
/// without its `D1_ERROR: ` prefix.
async function attempt(run) {
  try {
    return new Ok(await run());
  } catch (error) {
    const cause = error?.cause;
    if (typeof cause === "string") return new Error(cause);
    if (cause instanceof globalThis.Error) return new Error(cause.message);
    const message = String(error?.message ?? error);
    return new Error(message.replace(/^D1_[A-Z_]+: /, ""));
  }
}

export function identity(value) {
  return value;
}

export function null_binding() {
  return null;
}

/// A fresh Uint8Array of exactly the bit array's bytes. D1 mishandles other
/// views, and a Gleam slice can share a larger buffer.
export function to_uint8array(bits) {
  const bytes = new Uint8Array(bits.byteSize);
  for (let i = 0; i < bits.byteSize; i++) bytes[i] = bits.byteAt(i);
  return bytes;
}

export function is_finite(value) {
  return Number.isFinite(value);
}

export function to_bit_array(value) {
  if (value instanceof Uint8Array) return new Ok(new BitArray(value.slice()));
  if (value instanceof ArrayBuffer)
    return new Ok(new BitArray(new Uint8Array(value.slice(0))));
  if (
    Array.isArray(value) &&
    value.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255)
  )
    return new Ok(new BitArray(Uint8Array.from(value)));
  return new Error(undefined);
}
