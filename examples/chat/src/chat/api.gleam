//// Every public function here is an RPC method.
////
//// The caller's identity and room arrive in `auth`, bound by the Durable
//// Object, so neither is an argument. Storage is the object's own SQLite.

import chat/events
import chat/shared.{
  type ChatError, type Message, EmptyMessage, EmptyName, Message, MessagePosted,
  MessageTooLong, NameTooLong, max_body, max_name,
}
import gleam/dynamic/decode
import gleam/list
import gleam/string
import starflame/do_sql as sql
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
) -> Result(Message, ChatError) {
  let #(author, room) = identity(context)
  let name = string.trim(name)
  let body = string.trim(body)
  case validate(name, body) {
    Error(error) -> Error(error)
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
      use _ <- or_reject(
        sql.run(
          db,
          "INSERT INTO messages (id, room, author, name, body, created_at)
           VALUES (?, ?, ?, ?, ?, ?)",
          [
            sql.string(message.id),
            sql.string(message.room),
            sql.string(message.author),
            sql.string(message.name),
            sql.string(message.body),
            sql.int(message.created_at),
          ],
        ),
      )
      events.publish(context, MessagePosted(message))
      Ok(message)
    }
  }
}

pub fn history(context: server.Context) -> List(Message) {
  let #(_, room) = identity(context)
  use db <- with_db(context)
  use messages <- or_reject(sql.all(
    db,
    "SELECT id, room, author, name, body, created_at
       FROM messages WHERE room = ? ORDER BY created_at ASC LIMIT 200",
    [sql.string(room)],
    message_decoder(),
  ))
  messages
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

// STORAGE ---------------------------------------------------------------------

fn with_db(context: server.Context, next: fn(sql.Database) -> a) -> a {
  let db = sql.database(context)
  case sql.setup(db, [schema]) {
    Ok(Nil) -> next(db)
    Error(error) -> panic as sql.describe(error)
  }
}

fn or_reject(query: Result(a, sql.Error), next: fn(a) -> b) -> b {
  case query {
    Ok(value) -> next(value)
    Error(error) -> panic as sql.describe(error)
  }
}

fn message_decoder() -> decode.Decoder(Message) {
  use id <- decode.field("id", decode.string)
  use room <- decode.field("room", decode.string)
  use author <- decode.field("author", decode.string)
  use name <- decode.field("name", decode.string)
  use body <- decode.field("body", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  decode.success(Message(id:, room:, author:, name:, body:, created_at:))
}

// FFI -------------------------------------------------------------------------

@external(javascript, "./id_ffi.mjs", "random_id")
fn random_id() -> String

@external(javascript, "./id_ffi.mjs", "now_ms")
fn now_ms() -> Int
