//// Server-side runtime used by generated RPC dispatchers.

import cf_gleam/plain.{type Plain}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError, type Decoder}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string

/// Passed as the first argument to every API function.
pub opaque type Context {
  Context(env: Dynamic, execution: Dynamic)
}

pub fn new_context(env: Dynamic, execution: Dynamic) -> Context {
  Context(env:, execution:)
}

pub fn env(context: Context) -> Dynamic {
  context.env
}

/// Decode an RPC argument, rejecting the call if it doesn't match.
pub fn arg(
  value: Dynamic,
  decoder: Decoder(a),
  next: fn(a) -> Promise(Plain),
) -> Promise(Plain) {
  case decode.run(value, decoder) {
    Ok(value) -> next(value)
    Error(errors) -> reject("Invalid RPC argument: " <> describe(errors))
  }
}

/// Turn a Cap'n Web function stub received as an argument into a Gleam
/// callback. Calls are fire-and-forget.
pub fn callback1(
  value: Dynamic,
  encode: fn(a) -> Plain,
  next: fn(fn(a) -> Nil) -> Promise(Plain),
) -> Promise(Plain) {
  case is_function(value) {
    True -> next(fn(a) { call_stub(value, [encode(a)]) })
    False -> reject("Invalid RPC argument: expected a function")
  }
}

fn describe(errors: List(DecodeError)) -> String {
  errors
  |> list.map(fn(error) {
    let at = case error.path {
      [] -> ""
      path -> " at " <> string.join(path, ".")
    }
    "expected " <> error.expected <> ", found " <> error.found <> at
  })
  |> string.join("; ")
}

@external(javascript, "./server_ffi.mjs", "reject")
fn reject(message: String) -> Promise(a)

@external(javascript, "./server_ffi.mjs", "isFunction")
fn is_function(value: Dynamic) -> Bool

@external(javascript, "./server_ffi.mjs", "callStub")
fn call_stub(stub: Dynamic, args: List(Plain)) -> Nil
