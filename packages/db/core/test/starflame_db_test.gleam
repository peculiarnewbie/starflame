import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/time/timestamp
import gleeunit
import starflame/d1
import starflame_db/runtime

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn timestamp_decoder_uses_safe_d1_integer_test() {
  let seconds = 1_725_000_123
  assert decode.run(dynamic.int(seconds), runtime.timestamp_decoder())
    == Ok(timestamp.from_unix_seconds(seconds))

  let assert Error(_) =
    decode.run(dynamic.string("not an integer"), runtime.timestamp_decoder())
  let assert Error(_) =
    decode.run(unsafe_integer(), runtime.timestamp_decoder())
}

pub fn timestamp_value_drops_subsecond_precision_test() {
  let value =
    timestamp.from_unix_seconds_and_nanoseconds(
      seconds: 1_725_000_123,
      nanoseconds: 987_654_321,
    )
    |> runtime.timestamp_value
  assert is_integer_value(value, 1_725_000_123)
}

@external(javascript, "./starflame_db_runtime_test_ffi.mjs", "is_integer_value")
fn is_integer_value(value: d1.Value, expected: Int) -> Bool

@external(javascript, "./starflame_db_runtime_test_ffi.mjs", "unsafe_integer")
fn unsafe_integer() -> Dynamic
