//// GENERATED (hand-written for now): typed client stubs.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import starflame/client.{type RpcError, type Stub}
import starflame/plain
import todos/generated/wire
import todos/shared.{type Change, type Todo, type TodoError}

pub fn from_stub(stub: Stub) -> Api {
  Api(stub)
}

pub fn from_dynamic(value: Dynamic) -> Api {
  Api(unsafe_stub(value))
}

@external(javascript, "../client_ffi.mjs", "identity")
fn unsafe_stub(value: Dynamic) -> Stub

pub fn subscribe(
  api: Api,
  callback: fn(Change) -> Nil,
) -> Promise(Result(Nil, RpcError)) {
  client.call(
    api.stub,
    "subscribe",
    [
      client.callback1(callback, wire.change_decoder()),
    ],
    decode.success(Nil),
  )
}

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
