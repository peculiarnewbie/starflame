//// Every public function here is an RPC method.
////
//// The caller's identity and room arrive in `auth`, bound by the Durable
//// Object, so neither is an argument.

import chat/shared.{
  type ChatError, type Message, Message, EmptyMessage, EmptyName, MessageTooLong,
  NameTooLong, max_body, max_name,
}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/string
import starflame/d1
import starflame/server

const schema =
  "CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    room TEXT NOT NULL,
    author TEXT NOT NULL,
    name TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at INTEGER NOT NULL
  )"

pub fn send(
  context: server.Context,
  name name: String,
  body body: String,
) -> Promise(Result(Message, ChatError)) {
  let #(author, room) = identity(context)
  let name = string.trim(name)
  let body = string.trim(body)
  case validate(name, body) {
    Error(error) -> promise.resolve(Error(error))
    Ok(#(name, body)) -> {
      let message =
        Message(
          id: random_id(),
          room: room,
          author: author,
          name: name,
          body: body,
          created_at: now_ms(),
        )
      use db <- with_db(context)
      use _ <-
        or_reject(d1.run(
          db,
          "INSERT INTO messages (id, room, author, name, body, created_at)
           VALUES (?, ?, ?, ?, ?, ?)",
          [
            d1.string(message.id),
            d1.string(message.room),
            d1.string(message.author),
            d1.string(message.name),
            d1.string(message.body),
            d1.int(message.created_at),
          ],
        ))
      promise.resolve(Ok(message))
    }
  }
}

pub fn history(context: server.Context) -> Promise(List(Message)) {
  let #(_, room) = identity(context)
  use db <- with_db(context)
  use messages <-
    or_reject(d1.all(
      db,
      "SELECT id, room, author, name, body, created_at
       FROM messages WHERE room = ? ORDER BY created_at ASC LIMIT 200",
      [d1.string(room)],
      message_decoder(),
    ))
  promise.resolve(messages)
}

fn validate(
  name: String,
  body: String,
) -> Result(#(String, String), ChatError) {
  case string.length(name) {
    0 -> Error(EmptyName)
    length if length > max_name -> Error(NameTooLong(max_name))
    _ ->
      case string.length(body) {
        0 -> Error(EmptyMessage)
        length if length > max_body -> Error(MessageTooLong(max_body))
        _ -> Ok(#(name, body))
      }
  }
}

fn identity(context: server.Context) -> #(String, String) {
  case decode.run(server.auth(context), identity_decoder()) {
    Ok(identity) -> identity
    Error(_) -> panic as "The Worker must pass {player, room} as auth."
  }
}

fn identity_decoder() -> decode.Decoder(#(String, String)) {
  use player <- decode.field("player", decode.string)
  use room <- decode.field("room", decode.string)
  decode.success(#(player, room))
}

// DATABASE --------------------------------------------------------------------

fn with_db(
  context: server.Context,
  next: fn(d1.Database) -> Promise(a),
) -> Promise(a) {
  let db = d1.database(context, "DB")
  use setup <- promise.await(d1.setup(db, [schema]))
  case setup {
    Ok(Nil) -> next(db)
    Error(error) -> panic as d1.describe(error)
  }
}

fn or_reject(
  query: Promise(Result(a, d1.Error)),
  next: fn(a) -> Promise(b),
) -> Promise(b) {
  use result <- promise.await(query)
  case result {
    Ok(value) -> next(value)
    Error(error) -> panic as d1.describe(error)
  }
}

fn message_decoder() -> decode.Decoder(Message) {
  use id <- decode.field("id", decode.string)
  use room <- decode.field("room", decode.string)
  use author <- decode.field("author", decode.string)
  use name <- decode.field("name", decode.string)
  use body <- decode.field("body", decode.string)
  use created_at <- decode.field("created_at", d1.int_decoder())
  decode.success(Message(id:, room:, author:, name:, body:, created_at:))
}

// FFI -------------------------------------------------------------------------

@external(javascript, "./id_ffi.mjs", "random_id")
fn random_id() -> String

@external(javascript, "./id_ffi.mjs", "now_ms")
fn now_ms() -> Int
