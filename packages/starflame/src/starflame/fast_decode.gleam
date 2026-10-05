//// A fast path for decoding JavaScript values into Gleam values, for
//// generated code.
////
//// `gleam/dynamic/decode` builds an `Ok(Some(value))` for every field it
//// reads, and V8 is slow to construct values with positional fields: about
//// 170ns each, against 30ns for a labelled field. Decoding 50 small records
//// that way takes around 200µs. Instead, a fast decoder checks the whole
//// value against its `Kind` in one pass and the generated `build` function
//// reads it directly. When the check fails, the full decoder runs, so errors
//// are exactly what it reports.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Field {
  /// `nullable` fields may also be `null`.
  Field(name: String, kind: Kind, nullable: Bool)
}

/// The values a fast decoder accepts. Each kind accepts at most what the
/// matching full decoder accepts, so the two agree on every value that
/// matches.
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
  /// Whatever `plain.nil_decoder` accepts: `null` and `undefined`.
  NilKind
  /// An array of `item`s.
  ListKind(item: Kind)
  /// `null`, `undefined` or `some`, like `decode.optional`.
  OptionKind(some: Kind)
  /// A plain object with `value`s, like `decode.dict(decode.string, _)`.
  DictKind(value: Kind)
  /// An array of exactly these elements.
  TupleKind(elements: List(Kind))
  /// An object with these fields.
  RecordKind(fields: List(Field))
  /// An object with one of these variants' fields and its tag in `"$"`.
  VariantsKind(variants: List(Variant))
  /// What `plain.result` encodes: `{"$": "Ok" | "Error", "0": value}`.
  ResultKind(ok: Kind, error: Kind)
  /// The kind `get` returns, so recursive types can refer to themselves.
  LazyKind(get: fn() -> Kind)
}

pub type Variant {
  Variant(tag: String, fields: List(Field))
}

/// Uses `build` when the value is an object whose fields all match, and
/// `fallback` otherwise. `build` and `fallback` must agree on every value
/// that matches.
pub fn decoder(
  fields: List(Field),
  build: fn(Dynamic) -> a,
  fallback: Decoder(a),
) -> Decoder(a) {
  kind_decoder(RecordKind(fields), build, fn() { fallback })
}

/// Uses `build` when the value matches `kind`, and the decoder `fallback`
/// returns otherwise. `build` and the fallback must agree on every value that
/// matches.
pub fn kind_decoder(
  kind: Kind,
  build: fn(Dynamic) -> a,
  fallback: fn() -> Decoder(a),
) -> Decoder(a) {
  use value <- decode.then(decode.dynamic)
  case matches(value, kind) {
    True -> decode.success(build(value))
    False -> fallback()
  }
}

@external(javascript, "./fast_decode_ffi.mjs", "matches")
fn matches(value: Dynamic, kind: Kind) -> Bool

// BUILDING --------------------------------------------------------------------
// Only for `build` functions, on values that have already matched.

/// A field of a matched object, or an element of a matched tuple by index.
@external(javascript, "./fast_decode_ffi.mjs", "get")
pub fn get(object: Dynamic, name: String) -> a

/// A matched `IntKind`, `FloatKind`, `StringKind` or `BoolKind` value, which
/// is already the Gleam value.
@external(javascript, "./fast_decode_ffi.mjs", "identity")
pub fn coerce(value: Dynamic) -> a

/// A matched `VariantsKind` value's tag.
pub fn tag(object: Dynamic) -> String {
  get(object, "$")
}

/// A matched `ListKind` value.
@external(javascript, "./fast_decode_ffi.mjs", "list")
pub fn list(array: Dynamic, build: fn(Dynamic) -> a) -> List(a)

/// A matched `OptionKind` value.
pub fn option(value: Dynamic, build: fn(Dynamic) -> a) -> Option(a) {
  case is_nil(value) {
    True -> None
    False -> Some(build(value))
  }
}

/// A matched `DictKind` value.
pub fn dict(object: Dynamic, build: fn(Dynamic) -> a) -> Dict(String, a) {
  entries(object)
  |> list.fold(dict.new(), fn(dict, entry) {
    dict.insert(dict, entry.0, build(entry.1))
  })
}

/// A matched `ResultKind` value.
pub fn result(
  value: Dynamic,
  ok: fn(Dynamic) -> a,
  error: fn(Dynamic) -> e,
) -> Result(a, e) {
  case tag(value) {
    "Ok" -> Ok(ok(get(value, "0")))
    _ -> Error(error(get(value, "0")))
  }
}

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
  case is_nil(get(object, name)) {
    True -> None
    False -> Some(read(object, name))
  }
}

@external(javascript, "./fast_decode_ffi.mjs", "is_nil")
fn is_nil(value: Dynamic) -> Bool

@external(javascript, "./fast_decode_ffi.mjs", "entries")
fn entries(object: Dynamic) -> List(#(String, Dynamic))
