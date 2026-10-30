//// Durable Object SQLite. Unlike D1, these calls are synchronous: the database
//// lives in the object, so a query returns a value instead of a Promise.
////
//// This module reads `execution(context)`, which is the Durable Object's state
//// when the object builds the API with `newApi(env, ctx, auth)`.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/result
import starflame/server.{type Context}

pub type Error {
  Failed(message: String)
  /// A row didn't match its decoder.
  RowDecodeFailed
}

pub fn describe(error: Error) -> String {
  case error {
    Failed(message) -> message
    RowDecodeFailed -> "A row didn't match its decoder."
  }
}

pub opaque type Database

/// The object's SQLite database. Panics outside a Durable Object.
@external(javascript, "./do_sql_ffi.mjs", "database")
pub fn database(context: Context) -> Database

/// Runs idempotent statements, such as `CREATE TABLE IF NOT EXISTS`.
pub fn setup(db: Database, statements: List(String)) -> Result(Nil, Error) {
  do_setup(db, statements)
  |> result.map_error(Failed)
}

/// Runs a statement and returns the number of rows written.
pub fn run(
  db: Database,
  sql: String,
  params: List(Value),
) -> Result(Int, Error) {
  do_run(db, sql, params)
  |> result.map_error(Failed)
}

/// Runs a query and decodes every row.
pub fn all(
  db: Database,
  sql: String,
  params: List(Value),
  decoder: Decoder(a),
) -> Result(List(a), Error) {
  use rows <- result.try(do_all(db, sql, params) |> result.map_error(Failed))
  use values <-
    result.try(list.try_map(rows, fn(row) {
      case decode.run(row, decoder) {
        Ok(value) -> Ok(value)
        Error(_) -> Error(RowDecodeFailed)
      }
    }))
  Ok(values)
}

// VALUES ----------------------------------------------------------------------

pub opaque type Value

@external(javascript, "./do_sql_ffi.mjs", "identity")
pub fn int(value: Int) -> Value

@external(javascript, "./do_sql_ffi.mjs", "identity")
pub fn float(value: Float) -> Value

@external(javascript, "./do_sql_ffi.mjs", "identity")
pub fn string(value: String) -> Value

@external(javascript, "./do_sql_ffi.mjs", "blob")
pub fn blob(value: BitArray) -> Value

@external(javascript, "./do_sql_ffi.mjs", "null_")
pub fn null() -> Value

// FFI -------------------------------------------------------------------------

@external(javascript, "./do_sql_ffi.mjs", "setup")
fn do_setup(db: Database, statements: List(String)) -> Result(Nil, String)

@external(javascript, "./do_sql_ffi.mjs", "run")
fn do_run(
  db: Database,
  sql: String,
  params: List(Value),
) -> Result(Int, String)

@external(javascript, "./do_sql_ffi.mjs", "all")
fn do_all(
  db: Database,
  sql: String,
  params: List(Value),
) -> Result(List(Dynamic), String)
