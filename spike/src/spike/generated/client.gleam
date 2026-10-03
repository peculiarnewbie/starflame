//// GENERATED (hand-written for the spike): typed client stubs.

import cf_gleam/client.{type RpcError, type Stub}
import cf_gleam/plain
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option}
import spike/generated/wire
import spike/shared.{type ApiError, type Everything, type Role, type User}

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

pub fn get_user(
  api: Api,
  id: Int,
) -> Promise(Result(Result(User, ApiError), RpcError)) {
  client.call(
    api.stub,
    "get_user",
    [plain.int(id)],
    plain.result_decoder(wire.user_decoder(), wire.api_error_decoder()),
  )
}

pub fn list_users(
  api: Api,
  role: Option(Role),
) -> Promise(Result(List(User), RpcError)) {
  client.call(
    api.stub,
    "list_users",
    [plain.option(role, wire.role_to_plain)],
    decode.list(wire.user_decoder()),
  )
}

pub fn login(
  api: Api,
  name: String,
) -> Promise(Result(Result(Session, ApiError), RpcError)) {
  client.call(
    api.stub,
    "login",
    [plain.string(name)],
    plain.result_decoder(session_decoder(), wire.api_error_decoder()),
  )
}

pub fn count_slowly(
  api: Api,
  to: Int,
  on_progress: fn(Int) -> Nil,
) -> Promise(Result(Int, RpcError)) {
  client.call(
    api.stub,
    "count_slowly",
    [plain.int(to), client.callback1(on_progress, decode.int)],
    decode.int,
  )
}

pub fn echo_everything(
  api: Api,
  everything: Everything,
) -> Promise(Result(Everything, RpcError)) {
  client.call(
    api.stub,
    "echo_everything",
    [wire.everything_to_plain(everything)],
    wire.everything_decoder(),
  )
}

pub fn crash(api: Api, reason: String) -> Promise(Result(Int, RpcError)) {
  client.call(api.stub, "crash", [plain.string(reason)], decode.int)
}

// Session capability ----------------------------------------------------------

pub opaque type Session {
  Session(stub: Stub)
}

fn session_decoder() -> decode.Decoder(Session) {
  client.stub_decoder() |> decode.map(Session)
}

pub fn session_me(session: Session) -> Promise(Result(User, RpcError)) {
  client.call(session.stub, "me", [], wire.user_decoder())
}

pub fn session_rename(
  session: Session,
  name: String,
) -> Promise(Result(Result(User, ApiError), RpcError)) {
  client.call(
    session.stub,
    "rename",
    [plain.string(name)],
    plain.result_decoder(wire.user_decoder(), wire.api_error_decoder()),
  )
}

pub fn session_dispose(session: Session) -> Nil {
  client.dispose(session.stub)
}
