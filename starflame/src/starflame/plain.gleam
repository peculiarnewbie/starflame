//// Plain JavaScript values: the subset Cap'n Web can serialise. Gleam values
//// compile to class instances, which Cap'n Web rejects, so every value that
//// crosses the wire is encoded to `Plain` first and decoded with
//// `gleam/dynamic/decode` on the other side.
////
//// Wire format:
//// - Int, Float, String, Bool are themselves; Nil is `null`.
//// - List and tuples are arrays.
//// - Option is `null` or the inner value.
//// - Dict(String, a) is an object.
//// - Custom types are objects keyed by field label (positional fields use
////   their index). Types with more than one variant add a `"$"` tag.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Plain

@external(javascript, "./plain_ffi.mjs", "identity")
pub fn int(value: Int) -> Plain

@external(javascript, "./plain_ffi.mjs", "identity")
pub fn float(value: Float) -> Plain

@external(javascript, "./plain_ffi.mjs", "identity")
pub fn string(value: String) -> Plain

@external(javascript, "./plain_ffi.mjs", "identity")
pub fn bool(value: Bool) -> Plain

@external(javascript, "./plain_ffi.mjs", "null_")
pub fn null() -> Plain

pub fn nil(_value: Nil) -> Plain {
  null()
}

@external(javascript, "./plain_ffi.mjs", "array")
pub fn array(items: List(Plain)) -> Plain

pub fn list(items: List(a), encode: fn(a) -> Plain) -> Plain {
  array(list.map(items, encode))
}

@external(javascript, "./plain_ffi.mjs", "object")
pub fn object(entries: List(#(String, Plain))) -> Plain

pub fn tagged(tag: String, fields: List(#(String, Plain))) -> Plain {
  object([#("$", string(tag)), ..fields])
}

pub fn option(value: Option(a), encode: fn(a) -> Plain) -> Plain {
  case value {
    Some(inner) -> encode(inner)
    None -> null()
  }
}

pub fn dict(value: Dict(String, a), encode: fn(a) -> Plain) -> Plain {
  value
  |> dict.to_list
  |> list.map(fn(entry) { #(entry.0, encode(entry.1)) })
  |> object
}

pub fn result(
  value: Result(a, e),
  ok: fn(a) -> Plain,
  error: fn(e) -> Plain,
) -> Plain {
  case value {
    Ok(inner) -> tagged("Ok", [#("0", ok(inner))])
    Error(inner) -> tagged("Error", [#("0", error(inner))])
  }
}

/// Pass a JS value through untouched. Used for Cap'n Web stubs, RpcTargets and
/// functions, which Cap'n Web passes by reference.
@external(javascript, "./plain_ffi.mjs", "identity")
pub fn unsafe_reference(value: a) -> Plain

@external(javascript, "./plain_ffi.mjs", "identity")
pub fn to_dynamic(value: Plain) -> Dynamic

// DECODERS --------------------------------------------------------------------

pub fn result_decoder(
  ok: Decoder(a),
  error: Decoder(e),
) -> Decoder(Result(a, e)) {
  use tag <- decode.field("$", decode.string)
  case tag {
    "Ok" -> decode.field("0", ok, fn(value) { decode.success(Ok(value)) })
    "Error" ->
      decode.field("0", error, fn(value) { decode.success(Error(value)) })
    _ -> decode.failure(Error(dynamic.nil()), "Result") |> unsafe_coerce
  }
}

/// Only used to satisfy the type checker for the zero value of a failing
/// decoder; the value is never observed.
@external(javascript, "./plain_ffi.mjs", "identity")
fn unsafe_coerce(value: a) -> b
