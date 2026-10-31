//// Every public function here is an RPC method.

import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/string
import starflame/d1
import starflame/server.{type Context}
import todos/live
import todos/shared.{
  type Change, type Todo, type TodoError, CompletedCleared, EmptyTitle, NotFound,
  Removed, Snapshot, TitleTooLong, Todo, Upsert, max_title_length,
}

pub fn list_todos(context: Context) -> Promise(List(Todo)) {
  use <- server.serialise(context)
  current_todos(context)
}

fn current_todos(context: Context) -> Promise(List(Todo)) {
  use db <- with_db(context)
  use todos <- or_reject(d1.all(
    db,
    "SELECT id, title, done FROM todos ORDER BY id",
    [],
    todo_decoder(),
  ))
  todos
}

pub fn add_todo(
  context: Context,
  title title: String,
) -> Promise(Result(Todo, TodoError)) {
  use <- server.serialise(context)
  let title = string.trim(title)
  case string.length(title) {
    0 -> promise.resolve(Error(EmptyTitle))
    length if length > max_title_length ->
      promise.resolve(Error(TitleTooLong(max_title_length)))
    _ -> {
      use db <- with_db(context)
      use todos <- or_reject(d1.all(
        db,
        "INSERT INTO todos (title) VALUES (?) RETURNING id, title, done",
        [d1.string(title)],
        todo_decoder(),
      ))
      changed(context, single(todos, 0))
    }
  }
}

pub fn set_done(
  context: Context,
  id id: Int,
  done done: Bool,
) -> Promise(Result(Todo, TodoError)) {
  use <- server.serialise(context)
  use db <- with_db(context)
  use todos <- or_reject(d1.all(
    db,
    "UPDATE todos SET done = ? WHERE id = ? RETURNING id, title, done",
    [d1.bool(done), d1.int(id)],
    todo_decoder(),
  ))
  changed(context, single(todos, id))
}

pub fn delete_todo(
  context: Context,
  id id: Int,
) -> Promise(Result(Nil, TodoError)) {
  use <- server.serialise(context)
  use db <- with_db(context)
  use changes <- or_reject(
    d1.run(db, "DELETE FROM todos WHERE id = ?", [
      d1.int(id),
    ]),
  )
  case changes {
    0 -> Error(NotFound(id))
    _ -> {
      live.publish(context, Removed(id))
      Ok(Nil)
    }
  }
}

/// Returns how many todos were removed.
pub fn clear_completed(context: Context) -> Promise(Int) {
  use <- server.serialise(context)
  use db <- with_db(context)
  use changes <- or_reject(d1.run(db, "DELETE FROM todos WHERE done = 1", []))
  live.publish(context, CompletedCleared)
  changes
}

fn changed(context: Context, reply: Result(Todo, TodoError)) {
  case reply {
    Ok(item) -> live.publish(context, Upsert(item))
    Error(_) -> Nil
  }
  reply
}

/// Sends a snapshot, then every committed change through a typed callback.
pub fn subscribe(
  context: Context,
  on_change on_change: fn(Change) -> Nil,
) -> Promise(Nil) {
  use <- server.serialise(context)
  use todos <- promise.map(current_todos(context))
  live.subscribe(context, on_change)
  on_change(Snapshot(todos))
}

// DATABASE --------------------------------------------------------------------

fn with_db(
  context: Context,
  next: fn(d1.Database) -> Promise(a),
) -> Promise(a) {
  let db = d1.database(context, "DB")
  use setup <- promise.await(
    d1.setup(db, [
      "CREATE TABLE IF NOT EXISTS todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0
      )",
    ]),
  )
  case setup {
    Ok(Nil) -> next(db)
    Error(error) -> panic as d1.describe(error)
  }
}

/// These methods don't return database errors, so a failure rejects the call.
fn or_reject(
  query: Promise(Result(a, d1.Error)),
  next: fn(a) -> b,
) -> Promise(b) {
  use result <- promise.map(query)
  case result {
    Ok(value) -> next(value)
    Error(error) -> panic as d1.describe(error)
  }
}

fn single(todos: List(Todo), id: Int) -> Result(Todo, TodoError) {
  case todos {
    [item] -> Ok(item)
    _ -> Error(NotFound(id))
  }
}

fn todo_decoder() -> decode.Decoder(Todo) {
  use id <- decode.field("id", d1.int_decoder())
  use title <- decode.field("title", decode.string)
  use done <- decode.field("done", d1.bool_decoder())
  decode.success(Todo(id:, title:, done:))
}
