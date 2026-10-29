//// Persistence for the table: one JSON row in D1, encoded with the codecs
//// generated from `blackjack/shared`. This module is importable by the API
//// because the generated code lives in `blackjack/codecs`, not in the RPC
//// output directory.

import blackjack/codecs
import blackjack/engine
import blackjack/shared as s
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import starflame/d1
import starflame/plain
import starflame/server.{type Context}

const schema =
  "CREATE TABLE IF NOT EXISTS blackjack_tables (id TEXT PRIMARY KEY, state TEXT NOT NULL)"

pub fn load(context: Context, table: String) -> Promise(s.State) {
  let db = d1.database(context, "DB")
  use setup <- promise.await(d1.setup(db, [schema]))
  case setup {
    Ok(Nil) -> Nil
    Error(error) -> panic as d1.describe(error)
  }
  use rows <-
    promise.await(d1.all(
      db,
      "SELECT state FROM blackjack_tables WHERE id = ?",
      [d1.string(table)],
      state_row_decoder(),
    ))
  case rows {
    Ok([text, ..]) -> promise.resolve(decode_state(text))
    Ok([]) -> {
      let state = engine.empty_table(table)
      use _ <- promise.await(save_with(db, table, state))
      promise.resolve(state)
    }
    Error(error) -> panic as d1.describe(error)
  }
}

pub fn save(
  context: Context,
  table: String,
  state: s.State,
) -> Promise(Nil) {
  let db = d1.database(context, "DB")
  use result <- promise.map(save_with(db, table, state))
  case result {
    Ok(_) -> Nil
    Error(error) -> panic as d1.describe(error)
  }
}

fn save_with(
  db: d1.Database,
  table: String,
  state: s.State,
) -> Promise(Result(Int, d1.Error)) {
  let json = stringify(plain.to_dynamic(codecs.state_to_plain(state)))
  d1.run(
    db,
    "INSERT INTO blackjack_tables (id, state) VALUES (?, ?)
     ON CONFLICT(id) DO UPDATE SET state = excluded.state",
    [d1.string(table), d1.string(json)],
  )
}

fn decode_state(text: String) -> s.State {
  codecs.state_from_plain(parse(text))
}

fn state_row_decoder() -> decode.Decoder(String) {
  use state <- decode.field("state", decode.string)
  decode.success(state)
}

@external(javascript, "./storage_ffi.mjs", "stringify")
fn stringify(value: Dynamic) -> String

@external(javascript, "./storage_ffi.mjs", "parse")
fn parse(text: String) -> Dynamic
