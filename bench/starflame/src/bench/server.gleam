//// Hand-written RPC dispatchers called from worker.ts, as Starflame's RPC
//// generator would write them.

import bench/api
import bench/wire
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import starflame/plain.{type Plain}
import starflame/server.{type Context}

pub fn ping(context: Context, n: Dynamic) -> Promise(Plain) {
  use n <- server.arg(n, decode.int)
  api.ping(context, n) |> promise.map(plain.int)
}

pub fn echo_todos(context: Context, todos: Dynamic) -> Promise(Plain) {
  use todos <- server.arg(todos, decode.list(wire.todo_decoder()))
  api.echo_todos(context, todos)
  |> promise.map(plain.list(_, wire.todo_to_plain))
}

pub fn list_todos(context: Context) -> Promise(Plain) {
  api.list_todos(context)
  |> promise.map(plain.list(_, wire.todo_to_plain))
}

pub fn get_todo(context: Context, id: Dynamic) -> Promise(Plain) {
  use id <- server.arg(id, decode.int)
  api.get_todo(context, id)
  |> promise.map(plain.option(_, wire.todo_to_plain))
}

pub fn add_todo(context: Context, title: Dynamic) -> Promise(Plain) {
  use title <- server.arg(title, decode.string)
  api.add_todo(context, title) |> promise.map(wire.todo_to_plain)
}
