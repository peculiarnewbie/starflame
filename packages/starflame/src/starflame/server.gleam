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

/// The Worker's execution context, or a Durable Object's state. Used by
/// bindings that need the runtime, such as `do_sql`.
pub fn execution(context: Context) -> Dynamic {
  context.execution
}

/// Runs operations in order for this execution context. Durable Object APIs
/// use this to keep asynchronous reads, writes, and snapshots in commit order.
pub fn serialise(
  context: Context,
  operation: fn() -> Promise(a),
) -> Promise(a) {
  serialise_execution(context.execution, operation)
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

/// Registers cleanup for a returned capability. Generated targets run it when
/// the last target for this value is disposed, including when its session ends.
/// Return a fresh capability for each independently owned resource.
@external(javascript, "./server_ffi.mjs", "withDispose")
pub fn with_dispose(capability: a, cleanup: fn() -> Nil) -> a

/// Used by generated targets to retain their capability's resources.
@external(javascript, "./server_ffi.mjs", "retainCapability")
pub fn retain_capability(capability: a) -> Nil

/// Used by generated targets to release their capability's resources.
@external(javascript, "./server_ffi.mjs", "releaseCapability")
pub fn release_capability(capability: a) -> Nil

/// A callback owned by a generated target. Retain the Cap'n Web stub beyond
/// the current call, and release it with the target instead of losing it as
/// soon as the method returns.
pub fn callback_for(
  owner: a,
  value: Dynamic,
  next: fn(fn(List(Plain)) -> Nil) -> Promise(Plain),
) -> Promise(Plain) {
  case is_function(value) {
    True -> {
      let retained = retain_callback(owner, value)
      next(fn(arguments) { call_stub(retained, arguments) })
    }
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

@external(javascript, "./server_ffi.mjs", "retainCallback")
fn retain_callback(owner: a, stub: Dynamic) -> Dynamic

@external(javascript, "./server_ffi.mjs", "serialise")
fn serialise_execution(
  execution: Dynamic,
  operation: fn() -> Promise(a),
) -> Promise(a)
