//// GENERATED (hand-written for now): typed client stubs.

import cf_gleam/client.{type RpcError, type Stub}
import cf_gleam/plain
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import todos/generated/wire
import todos/shared.{type Todo, type TodoError}

pub opaque type Api {
  Api(stub: Stub)
}

pub fn connect(url: String) -> Api {
  Api(client.connect(url))
}

pub fn on_broken(api: Api, callback: fn(String) -> Nil) -> Nil {
  client.on_broken(api.stub, callback)
}

pub fn dispose(api: Api) -> Nil {
  client.dispose(api.stub)
}

pub fn list_todos(api: Api) -> Promise(Result(List(Todo), RpcError)) {
  client.call(api.stub, "list_todos", [], decode.list(wire.todo_decoder()))
}

pub fn add_todo(
  api: Api,
  title: String,
) -> Promise(Result(Result(Todo, TodoError), RpcError)) {
  client.call(
    api.stub,
    "add_todo",
    [plain.string(title)],
    plain.result_decoder(wire.todo_decoder(), wire.todo_error_decoder()),
  )
}

pub fn set_done(
  api: Api,
  id: Int,
  done: Bool,
) -> Promise(Result(Result(Todo, TodoError), RpcError)) {
  client.call(
    api.stub,
    "set_done",
    [plain.int(id), plain.bool(done)],
    plain.result_decoder(wire.todo_decoder(), wire.todo_error_decoder()),
  )
}

pub fn delete_todo(
  api: Api,
  id: Int,
) -> Promise(Result(Result(Nil, TodoError), RpcError)) {
  client.call(
    api.stub,
    "delete_todo",
    [plain.int(id)],
    plain.result_decoder(decode.success(Nil), wire.todo_error_decoder()),
  )
}

pub fn clear_completed(api: Api) -> Promise(Result(Int, RpcError)) {
  client.call(api.stub, "clear_completed", [], decode.int)
}
