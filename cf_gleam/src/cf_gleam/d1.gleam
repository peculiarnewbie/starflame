//// Minimal D1 bindings.

import cf_gleam/plain.{type Plain}
import cf_gleam/server.{type Context}
import gleam/dynamic.{type Dynamic}
import gleam/javascript/promise.{type Promise}

pub type Database

/// Look up a D1 binding by its name in the Worker's env.
@external(javascript, "./d1_ffi.mjs", "database")
pub fn database(context: Context, binding: String) -> Database

/// Run statements once per isolate, before the first query that asks for it.
/// Meant for `CREATE TABLE IF NOT EXISTS` style setup.
@external(javascript, "./d1_ffi.mjs", "setup")
pub fn setup(database: Database, statements: List(String)) -> Promise(Nil)

/// Rows as plain objects; decode them with `gleam/dynamic/decode`.
@external(javascript, "./d1_ffi.mjs", "all")
pub fn all(
  database: Database,
  sql: String,
  params: List(Plain),
) -> Promise(List(Dynamic))

/// Returns the number of rows changed.
@external(javascript, "./d1_ffi.mjs", "run")
pub fn run(database: Database, sql: String, params: List(Plain)) -> Promise(Int)
