//// Every public function here is an RPC method. Each benchmark app
//// implements the same five methods.

import bench/db.{type Todo}
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option}
import starflame/d1
import starflame/server.{type Context}
import starflame_db/runtime

/// RPC overhead alone.
pub fn ping(_context: Context, n: Int) -> Promise(Int) {
  promise.resolve(n + 1)
}

/// Decoding and encoding a larger payload.
pub fn echo_todos(_context: Context, todos: List(Todo)) -> Promise(List(Todo)) {
  promise.resolve(todos)
}

pub fn list_todos(context: Context) -> Promise(List(Todo)) {
  d1.all(
    db(context),
    "SELECT " <> db.todo_columns <> " FROM todos ORDER BY id LIMIT 50",
    [],
    db.todo_decoder(),
  )
  |> or_reject
}

pub fn get_todo(context: Context, id: Int) -> Promise(Option(Todo)) {
  db.get_todo(db(context), id) |> or_reject
}

pub fn add_todo(context: Context, title: String) -> Promise(Todo) {
  db.insert_todo(db(context), db.NewTodo(title:, done: runtime.UseDefault))
  |> or_reject
}

fn db(context: Context) -> d1.Database {
  d1.database(context, "DB")
}

/// These methods don't return database errors, so a failure rejects the call.
fn or_reject(query: Promise(Result(a, d1.Error))) -> Promise(a) {
  use result <- promise.map(query)
  case result {
    Ok(value) -> value
    Error(error) -> panic as d1.describe(error)
  }
}
