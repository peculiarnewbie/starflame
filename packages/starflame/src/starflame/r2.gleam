//// Cloudflare R2 bindings. Bodies are `BitArray` values: they cross the wire
//// as Cap'n Web bytes, so an upload can go through an ordinary RPC call.
////
//// This module only covers what an app needs to store and read opaque objects.
//// Range requests, multipart uploads and presigned URLs are not wrapped.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import gleam/result
import starflame/plain
import starflame/server.{type Context}

pub type Error {
  /// R2 rejected the operation, or the binding is missing.
  Failed(message: String)
}

pub fn describe(error: Error) -> String {
  case error {
    Failed(message) -> message
  }
}

/// Look up an R2 binding by its name in the Worker's env.
@external(javascript, "./r2_ffi.mjs", "bucket")
pub fn bucket(context: Context, binding: String) -> Bucket

pub opaque type Bucket

pub type Object {
  Object(body: BitArray, content_type: String, size: Int)
}

/// Writes `body` under `key`. `content_type` is stored as R2's HTTP metadata,
/// so serving the object later keeps the type.
pub fn put(
  bucket: Bucket,
  key: String,
  body: BitArray,
  content_type: String,
) -> Promise(Result(Nil, Error)) {
  use reply <- promise.map(do_put(bucket, key, body, content_type))
  result.map_error(reply, Failed)
}

pub fn get(
  bucket: Bucket,
  key: String,
) -> Promise(Result(Option(Object), Error)) {
  use reply <- promise.map(do_get(bucket, key))
  case reply {
    Error(message) -> Error(Failed(message))
    Ok(value) ->
      case decode.run(value, decode.optional(object_decoder())) {
        Ok(object) -> Ok(object)
        Error(_) -> {
          let message = "R2 decode failed: " <> describe_value(value)
          panic as message
        }
      }
  }
}

pub fn delete(bucket: Bucket, key: String) -> Promise(Result(Nil, Error)) {
  use reply <- promise.map(do_delete(bucket, key))
  result.map_error(reply, Failed)
}

fn object_decoder() -> decode.Decoder(Object) {
  use body <- decode.field("body", plain.bit_array_decoder())
  use content_type <- decode.field("content_type", decode.string)
  use size <- decode.field("size", decode.int)
  decode.success(Object(body:, content_type:, size:))
}

// FFI -------------------------------------------------------------------------

@external(javascript, "./r2_ffi.mjs", "put")
fn do_put(
  bucket: Bucket,
  key: String,
  body: BitArray,
  content_type: String,
) -> Promise(Result(Nil, String))

@external(javascript, "./r2_ffi.mjs", "get")
fn do_get(
  bucket: Bucket,
  key: String,
) -> Promise(Result(Dynamic, String))

@external(javascript, "./r2_ffi.mjs", "describe_value")
fn describe_value(value: Dynamic) -> String

@external(javascript, "./r2_ffi.mjs", "delete_")
fn do_delete(bucket: Bucket, key: String) -> Promise(Result(Nil, String))
