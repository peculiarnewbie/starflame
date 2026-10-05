//// D1 bindings. Queries resolve to `Result`: D1 failures become `Error`
//// values instead of rejected promises.
////
//// D1 stores booleans as 0/1, returns BLOBs as arrays of numbers and rounds
//// integers beyond ±(2^53 - 1) without an error, so decode columns with
//// `int_decoder`, `bool_decoder` and `bit_array_decoder` rather than the
//// generic `gleam/dynamic/decode` ones.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type DecodeError, type Decoder}
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import starflame/server.{type Context}

pub type Database

/// Look up a D1 binding by its name in the Worker's env.
@external(javascript, "./d1_ffi.mjs", "database")
pub fn database(context: Context, binding: String) -> Database

// VALUES ----------------------------------------------------------------------

/// A value for a `?` parameter.
pub opaque type Value {
  Integer(Int)
  Real(Float)
  Text(String)
  Blob(BitArray)
  Null
}

/// Must be within ±(2^53 - 1), the integers JavaScript represents exactly.
pub fn int(value: Int) -> Value {
  Integer(value)
}

/// Must be finite: D1 stores NaN and infinities as NULL.
pub fn float(value: Float) -> Value {
  Real(value)
}

pub fn string(value: String) -> Value {
  Text(value)
}

/// Stored as 1 or 0.
pub fn bool(value: Bool) -> Value {
  case value {
    True -> Integer(1)
    False -> Integer(0)
  }
}

/// A BLOB. Must be a whole number of bytes.
pub fn bit_array(value: BitArray) -> Value {
  Blob(value)
}

pub fn null() -> Value {
  Null
}

pub fn nullable(value: Option(a), to_value: fn(a) -> Value) -> Value {
  case value {
    Some(inner) -> to_value(inner)
    None -> Null
  }
}

// ERRORS ----------------------------------------------------------------------

pub type Error {
  /// A constraint rejected a write. The statement, or the whole batch, had no
  /// effect.
  ConstraintError(constraint: Constraint, message: String)
  /// D1 rejected or failed to run the statement: a SQL error, a limit, an
  /// authorizer denial or a connection problem. `code` is the SQLite result
  /// code, such as `"SQLITE_ERROR"`, when D1 reports one; otherwise it is
  /// empty.
  QueryError(code: String, message: String)
  /// A parameter can't be stored faithfully, so nothing was sent. Parameters
  /// are numbered from 1.
  InvalidValue(parameter: Int, reason: String)
  /// A row didn't match its decoder.
  DecodeError(List(DecodeError))
}

/// Parsed from D1's error messages, which have no documented stable format.
/// Anything unrecognised is `OtherConstraint` or a `QueryError`.
pub type Constraint {
  /// The columns, as `table.column`.
  Unique(columns: List(String))
  PrimaryKey(columns: List(String))
  NotNull(column: String)
  /// The constraint's name, or its expression when it is unnamed.
  Check(name: String)
  /// D1 doesn't say which foreign key failed.
  ForeignKey
  /// A STRICT column, or any INTEGER PRIMARY KEY, rejected a value of the
  /// wrong type.
  Datatype
  /// A trigger called `RAISE(ABORT, …)`; the message is the trigger's.
  Trigger
  OtherConstraint(code: String)
}

pub fn describe(error: Error) -> String {
  case error {
    ConstraintError(message:, ..) -> message
    QueryError(code: "", message:) -> message
    QueryError(code:, message:) -> message <> " (" <> code <> ")"
    InvalidValue(parameter:, reason:) ->
      "Invalid value for parameter "
      <> int.to_string(parameter)
      <> ": "
      <> reason
    DecodeError(errors) ->
      "Unexpected row: "
      <> list.map(errors, fn(error) {
        let at = case error.path {
          [] -> ""
          path -> " at " <> string.join(path, ".")
        }
        "expected " <> error.expected <> ", found " <> error.found <> at
      })
      |> string.join("; ")
  }
}

// QUERIES ---------------------------------------------------------------------

/// Rows as objects keyed by column name. If two result columns share a name,
/// only the last survives; alias them or use `raw`.
pub fn all(
  database: Database,
  sql: String,
  params: List(Value),
  decoder: Decoder(a),
) -> Promise(Result(List(a), Error)) {
  use bindings <- with_bindings(params)
  use rows <- promise.map_try(do_all(database, sql, bindings))
  decode_rows(rows, decoder)
}

/// Rows as arrays in column order. Decode fields by position, for example
/// `decode.field(0, d1.int_decoder(), ...)`.
pub fn raw(
  database: Database,
  sql: String,
  params: List(Value),
  decoder: Decoder(a),
) -> Promise(Result(List(a), Error)) {
  use bindings <- with_bindings(params)
  use rows <- promise.map_try(do_raw(database, sql, bindings))
  decode_rows(rows, decoder)
}

/// Returns the number of rows changed.
pub fn run(
  database: Database,
  sql: String,
  params: List(Value),
) -> Promise(Result(Int, Error)) {
  use bindings <- with_bindings(params)
  do_run(database, sql, bindings)
}

pub opaque type Statement {
  Statement(sql: String, params: List(Value))
}

pub fn statement(sql: String, params: List(Value)) -> Statement {
  Statement(sql:, params:)
}

/// The rows from `.all()` and the number of rows changed.
pub type Outcome {
  Outcome(rows: List(Dynamic), changes: Int)
}

/// Runs the statements in order as one transaction: if any fails, none take
/// effect. D1 rejects `BEGIN` and `SAVEPOINT`, so this is the only way to
/// group writes. Decode each outcome's rows with `decode_rows`.
pub fn batch(
  database: Database,
  statements: List(Statement),
) -> Promise(Result(List(Outcome), Error)) {
  let prepared =
    list.index_map(statements, fn(statement, index) {
      encode(statement.params)
      |> result.map(fn(bindings) { #(statement.sql, bindings) })
      |> result.map_error(fn(error) {
        case error {
          InvalidValue(parameter:, reason:) ->
            InvalidValue(
              parameter:,
              reason: reason
                <> " (statement "
                <> int.to_string(index + 1)
                <> ")",
            )
          _ -> error
        }
      })
    })
    |> result.all
  case prepared {
    Ok(prepared) -> do_batch(database, prepared)
    Error(error) -> promise.resolve(Error(error))
  }
}

pub fn decode_rows(
  rows: List(Dynamic),
  decoder: Decoder(a),
) -> Result(List(a), Error) {
  // One `decode.run` for all rows: each run allocates a Result, which V8 is
  // slow to construct. On failure, decode row by row so error paths don't
  // gain a row index.
  case decode.run(dynamic.list(rows), decode.list(decoder)) {
    Ok(values) -> Ok(values)
    Error(_) ->
      list.try_map(rows, decode.run(_, decoder))
      |> result.map_error(DecodeError)
  }
}

/// Run statements once per isolate, before the first query that asks for it.
/// Meant for `CREATE TABLE IF NOT EXISTS` style setup. A failure is retried
/// on the next call.
pub fn setup(
  database: Database,
  statements: List(String),
) -> Promise(Result(Nil, Error)) {
  ffi_setup(database, statements)
  |> promise.map(result.map_error(_, classify))
}

// DECODERS --------------------------------------------------------------------

const max_safe_integer = 9_007_199_254_740_991

/// Rejects integers that D1 may have rounded, rather than returning a
/// different number.
pub fn int_decoder() -> Decoder(Int) {
  use value <- decode.then(decode.int)
  case value > max_safe_integer || value < -max_safe_integer {
    True -> decode.failure(0, "Int within ±(2^53 - 1)")
    False -> decode.success(value)
  }
}

/// Decodes 0 and 1.
pub fn bool_decoder() -> Decoder(Bool) {
  use value <- decode.then(decode.int)
  case value {
    0 -> decode.success(False)
    1 -> decode.success(True)
    _ -> decode.failure(False, "Bool stored as 0 or 1")
  }
}

/// Decodes a BLOB, which D1 returns as an array of byte values.
pub fn bit_array_decoder() -> Decoder(BitArray) {
  decode.new_primitive_decoder("BitArray", fn(value) {
    case to_bit_array(value) {
      Ok(bits) -> Ok(bits)
      Error(Nil) -> Error(<<>>)
    }
  })
}

// INTERNALS -------------------------------------------------------------------

/// A JavaScript value D1 binds as intended.
type Binding

fn with_bindings(
  params: List(Value),
  next: fn(List(Binding)) -> Promise(Result(a, Error)),
) -> Promise(Result(a, Error)) {
  case encode(params) {
    Ok(bindings) -> next(bindings)
    Error(error) -> promise.resolve(Error(error))
  }
}

fn encode(params: List(Value)) -> Result(List(Binding), Error) {
  list.index_map(params, fn(value, index) {
    binding(value)
    |> result.map_error(fn(reason) {
      InvalidValue(parameter: index + 1, reason:)
    })
  })
  |> result.all
}

fn binding(value: Value) -> Result(Binding, String) {
  case value {
    Integer(value) ->
      case value > max_safe_integer || value < -max_safe_integer {
        True -> Error("integer outside ±(2^53 - 1)")
        False -> Ok(coerce(value))
      }
    Real(value) ->
      case is_finite(value) {
        True -> Ok(coerce(value))
        False -> Error("NaN or infinite float")
      }
    Text(value) -> Ok(coerce(value))
    Blob(value) ->
      case bit_array.bit_size(value) % 8 {
        0 -> Ok(to_uint8array(value))
        _ -> Error("bit array is not a whole number of bytes")
      }
    Null -> Ok(null_binding())
  }
}

/// Splits a D1 message such as `UNIQUE constraint failed: t.x: SQLITE_CONSTRAINT
/// (extended: SQLITE_CONSTRAINT_UNIQUE)` into its parts.
fn classify(text: String) -> Error {
  // Strip `(extended: …)` first: it contains `: SQLITE_` too.
  let #(text, extended) = case string.split_once(text, " (extended: ") {
    Ok(#(text, extended)) -> #(text, string.replace(extended, ")", ""))
    Error(Nil) -> #(text, "")
  }
  let #(message, primary) = case string.split(text, ": SQLITE_") {
    [_] -> #(text, "")
    parts -> {
      let assert [primary, ..rest] = list.reverse(parts)
      #(list.reverse(rest) |> string.join(": SQLITE_"), "SQLITE_" <> primary)
    }
  }
  let code = case extended {
    "" -> primary
    _ -> extended
  }
  let constraint = case message {
    "UNIQUE constraint failed: " <> columns ->
      case extended {
        "SQLITE_CONSTRAINT_PRIMARYKEY" ->
          Some(PrimaryKey(string.split(columns, ", ")))
        _ -> Some(Unique(string.split(columns, ", ")))
      }
    "NOT NULL constraint failed: " <> column -> Some(NotNull(column))
    "CHECK constraint failed: " <> name -> Some(Check(name))
    // RESTRICT reports SQLITE_CONSTRAINT_TRIGGER, so match the message first.
    "FOREIGN KEY constraint failed" <> _ -> Some(ForeignKey)
    _ ->
      case primary, extended {
        "SQLITE_CONSTRAINT", "SQLITE_CONSTRAINT_DATATYPE" -> Some(Datatype)
        // A non-integer for an INTEGER PRIMARY KEY.
        "SQLITE_MISMATCH", _ -> Some(Datatype)
        "SQLITE_CONSTRAINT", "SQLITE_CONSTRAINT_TRIGGER" -> Some(Trigger)
        "SQLITE_CONSTRAINT", _ -> Some(OtherConstraint(code))
        _, _ -> None
      }
  }
  case constraint {
    Some(constraint) -> ConstraintError(constraint:, message:)
    None -> QueryError(code:, message:)
  }
}

fn do_all(
  database: Database,
  sql: String,
  bindings: List(Binding),
) -> Promise(Result(List(Dynamic), Error)) {
  ffi_all(database, sql, bindings) |> promise.map(result.map_error(_, classify))
}

fn do_raw(
  database: Database,
  sql: String,
  bindings: List(Binding),
) -> Promise(Result(List(Dynamic), Error)) {
  ffi_raw(database, sql, bindings) |> promise.map(result.map_error(_, classify))
}

fn do_run(
  database: Database,
  sql: String,
  bindings: List(Binding),
) -> Promise(Result(Int, Error)) {
  ffi_run(database, sql, bindings) |> promise.map(result.map_error(_, classify))
}

fn do_batch(
  database: Database,
  statements: List(#(String, List(Binding))),
) -> Promise(Result(List(Outcome), Error)) {
  use outcomes <- promise.map(ffi_batch(database, statements))
  case outcomes {
    Ok(outcomes) ->
      Ok(list.map(outcomes, fn(outcome) { Outcome(outcome.0, outcome.1) }))
    Error(text) -> Error(classify(text))
  }
}

@external(javascript, "./d1_ffi.mjs", "all")
fn ffi_all(
  database: Database,
  sql: String,
  bindings: List(Binding),
) -> Promise(Result(List(Dynamic), String))

@external(javascript, "./d1_ffi.mjs", "raw")
fn ffi_raw(
  database: Database,
  sql: String,
  bindings: List(Binding),
) -> Promise(Result(List(Dynamic), String))

@external(javascript, "./d1_ffi.mjs", "run")
fn ffi_run(
  database: Database,
  sql: String,
  bindings: List(Binding),
) -> Promise(Result(Int, String))

@external(javascript, "./d1_ffi.mjs", "batch")
fn ffi_batch(
  database: Database,
  statements: List(#(String, List(Binding))),
) -> Promise(Result(List(#(List(Dynamic), Int)), String))

@external(javascript, "./d1_ffi.mjs", "setup")
fn ffi_setup(
  database: Database,
  statements: List(String),
) -> Promise(Result(Nil, String))

@external(javascript, "./d1_ffi.mjs", "identity")
fn coerce(value: a) -> Binding

@external(javascript, "./d1_ffi.mjs", "null_binding")
fn null_binding() -> Binding

@external(javascript, "./d1_ffi.mjs", "to_uint8array")
fn to_uint8array(value: BitArray) -> Binding

@external(javascript, "./d1_ffi.mjs", "is_finite")
fn is_finite(value: Float) -> Bool

@external(javascript, "./d1_ffi.mjs", "to_bit_array")
fn to_bit_array(value: Dynamic) -> Result(BitArray, Nil)
