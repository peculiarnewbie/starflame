//// A scratch SQLite database from `node:sqlite`, used to check migrations
//// before they reach D1. It enforces foreign keys, as D1 does, but has none
//// of D1's restrictions on statements.

import gleam/dynamic.{type Dynamic}

pub type Database

@external(javascript, "./sqlite_ffi.mjs", "open")
pub fn open() -> Database

@external(javascript, "./sqlite_ffi.mjs", "exec")
pub fn exec(database: Database, sql: String) -> Result(Nil, String)

/// Rows as objects keyed by column name.
@external(javascript, "./sqlite_ffi.mjs", "query")
pub fn query(
  database: Database,
  sql: String,
  params: List(String),
) -> List(Dynamic)

@external(javascript, "./sqlite_ffi.mjs", "close")
pub fn close(database: Database) -> Nil

/// Runs a migration file as one transaction, as `wrangler d1 migrations
/// apply` does. Deferred foreign key violations fail the commit.
pub fn apply(database: Database, sql: String) -> Result(Nil, String) {
  let _ = exec(database, "BEGIN")
  case exec(database, sql) {
    Ok(Nil) ->
      case exec(database, "COMMIT") {
        Ok(Nil) -> Ok(Nil)
        Error(error) -> {
          let _ = exec(database, "ROLLBACK")
          Error(error)
        }
      }
    Error(error) -> {
      let _ = exec(database, "ROLLBACK")
      Error(error)
    }
  }
}
