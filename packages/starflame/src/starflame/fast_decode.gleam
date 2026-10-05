//// A fast path for decoding JavaScript objects into Gleam records, for
//// generated code.
////
//// `gleam/dynamic/decode` builds an `Ok(Some(value))` for every field it
//// reads, and V8 is slow to construct values with positional fields: about
//// 170ns each, against 30ns for a labelled field. Decoding 50 small records
//// that way takes around 200µs. Instead, `decoder` checks a whole object
//// against its fields in one pass and the generated `build` function reads
//// them directly. When the check fails, the full decoder runs, so errors are
//// exactly what it reports.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/option.{type Option, None, Some}

pub type Field {
  /// `nullable` fields may also be `null`.
  Field(name: String, kind: Kind, nullable: Bool)
}

pub type Kind {
  /// Whatever `decode.int` accepts.
  IntKind
  /// Whatever `d1.int_decoder` accepts: integers within ±(2^53 - 1).
  SafeIntKind
  /// Whatever `decode.float` accepts: any number.
  FloatKind
  /// Whatever `decode.string` accepts.
  StringKind
  /// Whatever `decode.bool` accepts: `true` and `false`.
  BoolKind
  /// Whatever `d1.bool_decoder` accepts: 0 and 1.
  ZeroOrOneKind
}

/// Uses `build` when the value is an object whose fields all match, and
/// `fallback` otherwise. `build` and `fallback` must agree on every value
/// that matches.
pub fn decoder(
  fields: List(Field),
  build: fn(Dynamic) -> a,
  fallback: Decoder(a),
) -> Decoder(a) {
  use value <- decode.then(decode.dynamic)
  case matches(value, fields) {
    True -> decode.success(build(value))
    False -> fallback
  }
}

@external(javascript, "./fast_decode_ffi.mjs", "matches")
fn matches(value: Dynamic, fields: List(Field)) -> Bool

/// A field `decoder` has already checked. Only for `build` functions.
@external(javascript, "./fast_decode_ffi.mjs", "get")
pub fn get(object: Dynamic, name: String) -> a

/// A `ZeroOrOneKind` field as a Bool.
pub fn zero_or_one(object: Dynamic, name: String) -> Bool {
  get(object, name) == 1
}

/// A nullable field, read with `read` unless it's null.
pub fn nullable(
  object: Dynamic,
  name: String,
  read: fn(Dynamic, String) -> a,
) -> Option(a) {
  case is_null(object, name) {
    True -> None
    False -> Some(read(object, name))
  }
}

@external(javascript, "./fast_decode_ffi.mjs", "is_null")
fn is_null(object: Dynamic, name: String) -> Bool
