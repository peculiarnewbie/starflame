//// Client-side runtime used by generated RPC stubs.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError, type Decoder}
import gleam/javascript/promise.{type Promise}
import gleam/result
import lustre/effect.{type Effect}
import starflame/plain.{type Plain}

/// A Cap'n Web stub: the session's main API or a capability it returned.
pub type Stub

pub type RpcError {
  /// The call was rejected: the session broke, the server threw, or it
  /// rejected the arguments.
  Remote(message: String)
  /// The server's reply didn't match the expected type.
  Decode(errors: List(DecodeError))
}

/// Open a WebSocket RPC session. The connection opens lazily on first call.
@external(javascript, "./client_ffi.mjs", "connect")
pub fn connect(url: String) -> Stub

/// The WebSocket URL for `path` on the page's own origin, e.g. "/rpc".
@external(javascript, "./client_ffi.mjs", "sameOriginUrl")
pub fn same_origin_url(path: String) -> String

@external(javascript, "./client_ffi.mjs", "onBroken")
pub fn on_broken(stub: Stub, callback: fn(String) -> Nil) -> Nil

@external(javascript, "./client_ffi.mjs", "dispose")
pub fn dispose(stub: Stub) -> Nil

pub fn call(
  stub: Stub,
  method: String,
  args: List(Plain),
  decoder: Decoder(a),
) -> Promise(Result(a, RpcError)) {
  use reply <- promise.map(do_call(stub, method, args))
  use value <- result.try(result.map_error(reply, Remote))
  decode.run(value, decoder) |> result.map_error(Decode)
}

/// Decoder for a capability: keeps the Cap'n Web stub as it is.
pub fn stub_decoder() -> Decoder(Stub) {
  decode.dynamic |> decode.map(unsafe_stub)
}

/// Encode a Gleam callback so the server can call it. `arguments` decodes
/// the array of arguments it's called with; calls whose arguments don't
/// decode are dropped.
pub fn callback(arguments: Decoder(a), callback: fn(a) -> Nil) -> Plain {
  variadic(fn(values: Dynamic) {
    case decode.run(values, arguments) {
      Ok(values) -> callback(values)
      Error(_) -> Nil
    }
  })
}

/// Run an RPC call as a Lustre effect.
pub fn effect(call: Promise(a), to_msg: fn(a) -> msg) -> Effect(msg) {
  use dispatch <- effect.from
  promise.map(call, fn(reply) { dispatch(to_msg(reply)) })
  Nil
}

@external(javascript, "./client_ffi.mjs", "call")
fn do_call(
  stub: Stub,
  method: String,
  args: List(Plain),
) -> Promise(Result(Dynamic, String))

@external(javascript, "./plain_ffi.mjs", "identity")
fn unsafe_stub(value: Dynamic) -> Stub

@external(javascript, "./client_ffi.mjs", "variadic")
fn variadic(callback: fn(Dynamic) -> Nil) -> Plain
