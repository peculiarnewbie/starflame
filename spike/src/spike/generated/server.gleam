//// GENERATED (hand-written for the spike): decodes RPC arguments, calls the
//// API, encodes the reply. Called from the RpcTarget classes in targets.ts.

import cf_gleam/plain.{type Plain}
import cf_gleam/server.{type Context}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import spike/api.{type Session}
import spike/generated/wire

pub fn get_user(context: Context, id: Dynamic) -> Promise(Plain) {
  use id <- server.arg(id, decode.int)
  api.get_user(context, id)
  |> promise.map(plain.result(_, wire.user_to_plain, wire.api_error_to_plain))
}

pub fn list_users(context: Context, role: Dynamic) -> Promise(Plain) {
  use role <- server.arg(role, decode.optional(wire.role_decoder()))
  api.list_users(context, role)
  |> promise.map(plain.list(_, wire.user_to_plain))
}

pub fn login(context: Context, name: Dynamic) -> Promise(Plain) {
  use name <- server.arg(name, decode.string)
  api.login(context, name)
  |> promise.map(plain.result(_, session_to_plain, wire.api_error_to_plain))
}

pub fn count_slowly(
  context: Context,
  to: Dynamic,
  on_progress: Dynamic,
) -> Promise(Plain) {
  use to <- server.arg(to, decode.int)
  use on_progress <- server.callback1(on_progress, plain.int)
  api.count_slowly(context, to, on_progress)
  |> promise.map(plain.int)
}

pub fn echo_everything(context: Context, everything: Dynamic) -> Promise(Plain) {
  use everything <- server.arg(everything, wire.everything_decoder())
  api.echo_everything(context, everything)
  |> promise.map(wire.everything_to_plain)
}

pub fn crash(context: Context, reason: Dynamic) -> Promise(Plain) {
  use reason <- server.arg(reason, decode.string)
  api.crash(context, reason)
  |> promise.map(plain.int)
}

// Session capability ----------------------------------------------------------

@external(javascript, "./targets.ts", "newSessionTarget")
fn session_to_plain(session: Session) -> Plain

pub fn session_me(session: Session) -> Promise(Plain) {
  session.me()
  |> promise.map(wire.user_to_plain)
}

pub fn session_rename(session: Session, name: Dynamic) -> Promise(Plain) {
  use name <- server.arg(name, decode.string)
  session.rename(name)
  |> promise.map(plain.result(_, wire.user_to_plain, wire.api_error_to_plain))
}
