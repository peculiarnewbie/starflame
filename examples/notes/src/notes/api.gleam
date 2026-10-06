//// The notes API. Every public function is an RPC method; the Worker only
//// serves it to signed-in users, whose `Me` it passes as `auth`.

import gleam/dynamic/decode
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/result
import gleam/string
import notes/db
import notes/session
import notes/shared.{
  type Me, type Note, type NotesError, EmptyNote, Note, NoteNotFound,
  NoteTooLong, ServerError, SignedOut,
}
import starflame/d1
import starflame/server.{type Context}
import starflame_db/runtime

const max_length = 10_000

pub fn me(context: Context) -> Promise(Result(Me, NotesError)) {
  promise.resolve(require_user(context))
}

/// The user's notes, newest first.
pub fn list_notes(context: Context) -> Promise(Result(List(Note), NotesError)) {
  use me <- signed_in(context)
  let sql =
    "SELECT "
    <> db.note_columns
    <> " FROM notes WHERE user_id = ? ORDER BY id DESC"
  use rows <- promise.map(d1.all(
    database(context),
    sql,
    [d1.int(me.id)],
    db.note_decoder(),
  ))
  rows
  |> result.map(list.map(_, to_note))
  |> result.map_error(log)
}

pub fn add_note(
  context: Context,
  body body: String,
) -> Promise(Result(Note, NotesError)) {
  use me <- signed_in(context)
  let body = string.trim(body)
  case body, string.length(body) > max_length {
    "", _ -> promise.resolve(Error(EmptyNote))
    _, True -> promise.resolve(Error(NoteTooLong(max_length)))
    _, False -> {
      let new =
        db.NewNote(user_id: me.id, body:, created_at: runtime.UseDefault)
      use inserted <- promise.map(db.insert_note(database(context), new))
      inserted |> result.map(to_note) |> result.map_error(log)
    }
  }
}

pub fn delete_note(
  context: Context,
  id id: Int,
) -> Promise(Result(Nil, NotesError)) {
  use me <- signed_in(context)
  use deleted <- promise.map(
    d1.run(database(context), "DELETE FROM notes WHERE id = ? AND user_id = ?", [
      d1.int(id),
      d1.int(me.id),
    ]),
  )
  case deleted {
    Ok(0) -> Error(NoteNotFound)
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(log(error))
  }
}

fn require_user(context: Context) -> Result(Me, NotesError) {
  server.auth(context)
  |> decode.run(session.decoder())
  |> result.replace_error(SignedOut)
}

fn signed_in(
  context: Context,
  next: fn(Me) -> Promise(Result(a, NotesError)),
) -> Promise(Result(a, NotesError)) {
  case require_user(context) {
    Ok(me) -> next(me)
    Error(error) -> promise.resolve(Error(error))
  }
}

fn database(context: Context) -> d1.Database {
  d1.database(context, "DB")
}

fn to_note(row: db.Note) -> Note {
  Note(id: row.id, body: row.body)
}

fn log(error: d1.Error) -> NotesError {
  io.println_error("Database error: " <> d1.describe(error))
  ServerError
}
