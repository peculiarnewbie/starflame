//// GENERATED (hand-written for now): RPC dispatchers called from targets.ts.

import starflame/plain.{type Plain}
import starflame/server.{type Context}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import todos/api
import todos/generated/wire

pub fn list_todos(context: Context) -> Promise(Plain) {
  api.list_todos(context)
  |> promise.map(plain.list(_, wire.todo_to_plain))
}

pub fn add_todo(context: Context, title: Dynamic) -> Promise(Plain) {
  use title <- server.arg(title, decode.string)
  api.add_todo(context, title)
  |> promise.map(plain.result(_, wire.todo_to_plain, wire.todo_error_to_plain))
}

pub fn set_done(context: Context, id: Dynamic, done: Dynamic) -> Promise(Plain) {
  use id <- server.arg(id, decode.int)
  use done <- server.arg(done, decode.bool)
  api.set_done(context, id, done)
  |> promise.map(plain.result(_, wire.todo_to_plain, wire.todo_error_to_plain))
}

pub fn delete_todo(context: Context, id: Dynamic) -> Promise(Plain) {
  use id <- server.arg(id, decode.int)
  api.delete_todo(context, id)
  |> promise.map(plain.result(_, plain.nil, wire.todo_error_to_plain))
}

pub fn clear_completed(context: Context) -> Promise(Plain) {
  api.clear_completed(context)
  |> promise.map(plain.int)
}
