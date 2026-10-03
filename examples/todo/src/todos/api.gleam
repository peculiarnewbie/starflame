//// Every public function here is an RPC method.

import starflame/d1
import starflame/plain
import starflame/server.{type Context}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string
import todos/shared.{
  type Todo, type TodoError, EmptyTitle, NotFound, TitleTooLong, Todo,
  max_title_length,
}

pub fn list_todos(context: Context) -> Promise(List(Todo)) {
  use db <- with_db(context)
  use rows <- promise.map(d1.all(
    db,
    "SELECT id, title, done FROM todos ORDER BY id",
    [],
  ))
  decode_rows(rows)
}

pub fn add_todo(context: Context, title: String) -> Promise(Result(Todo, TodoError)) {
  let title = string.trim(title)
  case string.length(title) {
    0 -> promise.resolve(Error(EmptyTitle))
    length if length > max_title_length ->
      promise.resolve(Error(TitleTooLong(max_title_length)))
    _ -> {
      use db <- with_db(context)
      use rows <- promise.map(d1.all(
        db,
        "INSERT INTO todos (title) VALUES (?) RETURNING id, title, done",
        [plain.string(title)],
      ))
      single(rows, 0)
    }
  }
}

pub fn set_done(
  context: Context,
  id: Int,
  done: Bool,
) -> Promise(Result(Todo, TodoError)) {
  use db <- with_db(context)
  use rows <- promise.map(d1.all(
    db,
    "UPDATE todos SET done = ? WHERE id = ? RETURNING id, title, done",
    [plain.bool(done), plain.int(id)],
  ))
  single(rows, id)
}

pub fn delete_todo(context: Context, id: Int) -> Promise(Result(Nil, TodoError)) {
  use db <- with_db(context)
  use changes <- promise.map(d1.run(db, "DELETE FROM todos WHERE id = ?", [
    plain.int(id),
  ]))
  case changes {
    0 -> Error(NotFound(id))
    _ -> Ok(Nil)
  }
}

/// Returns how many todos were removed.
pub fn clear_completed(context: Context) -> Promise(Int) {
  use db <- with_db(context)
  d1.run(db, "DELETE FROM todos WHERE done = 1", [])
}

// DATABASE --------------------------------------------------------------------

fn with_db(
  context: Context,
  next: fn(d1.Database) -> Promise(a),
) -> Promise(a) {
  let db = d1.database(context, "DB")
  use _ <- promise.await(
    d1.setup(db, [
      "CREATE TABLE IF NOT EXISTS todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0
      )",
    ]),
  )
  next(db)
}

fn single(rows: List(Dynamic), id: Int) -> Result(Todo, TodoError) {
  case decode_rows(rows) {
    [item] -> Ok(item)
    _ -> Error(NotFound(id))
  }
}

fn decode_rows(rows: List(Dynamic)) -> List(Todo) {
  let row = {
    use id <- decode.field("id", decode.int)
    use title <- decode.field("title", decode.string)
    use done <- decode.field("done", decode.int)
    decode.success(Todo(id:, title:, done: done == 1))
  }
  list.filter_map(rows, decode.run(_, row))
}
