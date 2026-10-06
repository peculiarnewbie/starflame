//// Server-side runtime used by generated RPC dispatchers.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError, type Decoder}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string
import starflame/plain.{type Plain}

/// Passed as the first argument to every API function.
pub opaque type Context {
  Context(env: Dynamic, execution: Dynamic, auth: Dynamic)
}

pub fn new_context(env: Dynamic, execution: Dynamic) -> Context {
  Context(env:, execution:, auth: dynamic.nil())
}

/// The context with `auth`, such as the user the Worker verified for this
/// request.
pub fn with_auth(context: Context, auth: Dynamic) -> Context {
  Context(..context, auth:)
}

pub fn env(context: Context) -> Dynamic {
  context.env
}

/// What the Worker passed as `auth` to `newApi`, or `Nil` when it passed
/// nothing. Decode it into the app's own type:
///
/// ```gleam
/// fn require_user(context: Context) -> Result(User, AuthError) {
///   server.auth(context)
///   |> decode.run(user_decoder())
///   |> result.replace_error(SignedOut)
/// }
/// ```
pub fn auth(context: Context) -> Dynamic {
  context.auth
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
/// callback taking the encoded arguments. Calls are fire-and-forget.
pub fn callback(
  value: Dynamic,
  next: fn(fn(List(Plain)) -> Nil) -> Promise(Plain),
) -> Promise(Plain) {
  case is_function(value) {
    True -> next(fn(arguments) { call_stub(value, arguments) })
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
