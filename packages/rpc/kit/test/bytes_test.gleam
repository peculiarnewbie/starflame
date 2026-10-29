import gleam/string
import simplifile
import starflame_rpc_kit
import starflame_rpc_kit_test.{fixture_project}

pub fn bytes_compile_and_runtime_test() {
  let root = fixture_project("bytes")
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/spike/api.gleam",
      "import spike/types\nimport starflame/server.{type Context}\npub fn roundtrip(_context: Context, bytes bytes: BitArray) -> BitArray { bytes }\npub fn upload(_context: Context, value value: types.Upload) -> types.Upload { value }\n",
    )
  let assert Ok(_) = starflame_rpc_kit.run(root, ["generate"])
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])
  let assert Ok(client) =
    simplifile.read(root <> "/src/spike/generated/client.gleam")
  let assert True = string.contains(client, "bytes bytes: BitArray")
  let assert True = string.contains(client, "plain.bit_array(bytes)")
  let assert True = string.contains(client, "plain.bit_array_decoder()")
  let assert Ok(_) =
    simplifile.write(root <> "/src/spike/bytes_runtime.gleam", runtime)
  let assert Ok(_) = shell(root, "gleam", ["build", "--warnings-as-errors"])
  case shell(root, "gleam", ["run", "-m", "spike/bytes_runtime"]) {
    Ok(output) -> {
      let assert True = string.contains(output, "PASS bytes runtime")
      Nil
    }
    Error(output) -> panic as output
  }
}

const runtime =
  "import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/io
import gleam/list
import spike/codecs
import spike/types.{Upload}
import starflame/fast_decode
import starflame/plain

pub fn main() {
  let expected = <<0, 127, 128, 255>>
  list.each(byte_inputs(), fn(data) { check(data, expected) })
  check(plain.to_dynamic(plain.bit_array(<<>>)), <<>>)
  check(plain.to_dynamic(plain.bit_array(expected)), expected)
  let assert <<_:size(3), offset:bits-size(8), _:size(5)>> = <<5:size(3), 171, 0:size(5)>>
  check(plain.to_dynamic(plain.bit_array(offset)), <<171>>)
  let assert True = encoding_rejected(fn() { plain.bit_array(<<1:size(1)>>) })
  list.each(non_bytes(), fn(data) {
    let assert Error(_) = decode.run(data, plain.bit_array_decoder())
    let strict = fast_decode.kind_decoder(fast_decode.BytesKind,
      fn(_) { panic as \"non-bytes matched BytesKind\" },
      fn() { decode.failure(<<>>, \"bytes\") })
    let assert Error(_) = decode.run(data, strict)
    let assert Error(_) = decode.run(upload(data), codecs.upload_decoder())
  })
  io.println(\"PASS bytes runtime\")
}

fn check(data: Dynamic, expected: BitArray) {
  let assert Ok(decoded) = decode.run(data, plain.bit_array_decoder())
  let assert True = decoded == expected
  let strict = fast_decode.kind_decoder(fast_decode.BytesKind, fast_decode.bit_array,
    fn() { decode.failure(<<>>, \"fast bytes\") })
  let assert Ok(fast) = decode.run(data, strict)
  let assert True = fast == expected
  let expected_upload = Upload(expected, [expected], #(expected, \"bytes\"))
  let strict_upload = fast_decode.kind_decoder(codecs.upload_kind, codecs.upload_from_plain,
    fn() { decode.failure(expected_upload, \"fast upload\") })
  let assert Ok(fast_upload) = decode.run(upload(data), strict_upload)
  let assert True = fast_upload == expected_upload
  let assert Ok(full_upload) = decode.run(upload(data), codecs.upload_decoder())
  let assert True = full_upload == expected_upload
  let assert Ok(roundtrip) = decode.run(
    plain.to_dynamic(codecs.upload_to_plain(expected_upload)), codecs.upload_decoder())
  let assert True = roundtrip == expected_upload
}

@external(javascript, \"./bytes_runtime_ffi.mjs\", \"byte_inputs\")
fn byte_inputs() -> List(Dynamic)

@external(javascript, \"./bytes_runtime_ffi.mjs\", \"non_bytes\")
fn non_bytes() -> List(Dynamic)

@external(javascript, \"./bytes_runtime_ffi.mjs\", \"upload\")
fn upload(value: Dynamic) -> Dynamic

@external(javascript, \"./bytes_runtime_ffi.mjs\", \"encoding_rejected\")
fn encoding_rejected(encode: fn() -> plain.Plain) -> Bool
"

@external(javascript, "./starflame_rpc_kit_test_ffi.mjs", "shell")
fn shell(
  directory: String,
  command: String,
  args: List(String),
) -> Result(String, String)
