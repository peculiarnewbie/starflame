//// Runtime helpers shared by code generated from a starflame_db schema.

import gleam/dynamic/decode.{type Decoder}
import gleam/time/timestamp.{type Timestamp}
import starflame/d1

/// An insert field for a column that has a database default.
pub type Defaulted(a) {
  /// Leave the column out of the INSERT, so the database default applies.
  UseDefault
  Given(a)
}

/// Decodes an INTEGER containing Unix seconds.
pub fn timestamp_decoder() -> Decoder(Timestamp) {
  d1.int_decoder() |> decode.map(timestamp.from_unix_seconds)
}

/// Encodes whole Unix seconds, dropping sub-second precision.
pub fn timestamp_value(value: Timestamp) -> d1.Value {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(value)
  d1.int(seconds)
}
