import gleam/list
import gleam/string
import simplifile
import starflame_rpc_kit
import starflame_rpc_kit_test.{fixture_project}

pub fn codecs_cli_and_freshness_test() {
  let root = fixture_project("codecs")
  let assert Ok(_) =
    shell(root, "gleam", ["run", "-m", "starflame_rpc_kit", "--", "generate"])
  let assert Ok(output) =
    shell(root, "gleam", ["run", "-m", "starflame_rpc_kit", "--", "codecs"])
  let assert True = string.contains(output, "Wrote src/spike/codecs.gleam")
  let assert True =
    string.contains(output, "Wrote src/spike/other_codecs.gleam")
  let path = root <> "/src/spike/codecs.gleam"
  let assert Ok(source) = simplifile.read(path)
  let assert True = string.contains(source, "import spike/types")
  let assert True = string.contains(source, "import spike/other")
  list.each(["state", "detail", "tree", "unused", "item"], fn(name) {
    list.each(["_to_plain", "_decoder", "_from_plain", "_kind"], fn(suffix) {
      let assert True = string.contains(source, name <> suffix)
      Nil
    })
  })
  let assert Ok(_) = shell(root, "gleam", ["build", "--warnings-as-errors"])
  let assert Ok(_) =
    shell(root, "gleam", ["run", "-m", "starflame_rpc_kit", "--", "check"])

  let assert Ok(_) = simplifile.write(path, source <> "\n// stale\n")
  let assert Error(error) =
    shell(root, "gleam", ["run", "-m", "starflame_rpc_kit", "--", "check"])
  let assert True =
    string.contains(error, "src/spike/codecs.gleam is out of date")
  let assert True = string.contains(error, "-- codecs`")
  let assert Ok(still_stale) = simplifile.read(path)
  let assert True = string.contains(still_stale, "// stale")
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])
  let assert Ok(unchanged) = starflame_rpc_kit.run(root, ["codecs"])
  let assert True =
    string.contains(unchanged, "Unchanged src/spike/codecs.gleam")
  let assert Ok(_) = starflame_rpc_kit.run(root, ["check"])
  let assert Ok(_) = simplifile.delete(root <> "/src/spike/other_codecs.gleam")
  let assert Error(missing) = starflame_rpc_kit.run(root, ["check"])
  let assert True =
    string.contains(missing, "src/spike/other_codecs.gleam is missing")
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])

  let assert Ok(_) =
    starflame_rpc_kit.run(root, [
      "codecs",
      "spike/types",
      "--out",
      "spike/standalone",
    ])
  let assert Ok(standalone) =
    simplifile.read(root <> "/src/spike/standalone.gleam")
  let assert True =
    string.contains(standalone, "-- codecs spike/types --out spike/standalone")
  let assert Ok(_) = shell(root, "gleam", ["build", "--warnings-as-errors"])
  Nil
}

pub fn codecs_failure_preserves_previous_files_test() {
  let root = fixture_project("codecs_failure")
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])
  let path = root <> "/src/spike/codecs.gleam"
  let other_path = root <> "/src/spike/other_codecs.gleam"
  let assert Ok(before) = simplifile.read(path)
  let assert Ok(other_before) = simplifile.read(other_path)
  // The first configured module could generate successfully, but a later
  // module fails analysis. No configured output should have been replaced.
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/spike/other.gleam",
      "pub type Item { Item(name: String) }\npub opaque type Secret { Secret }\n",
    )
  let assert Error(error) = starflame_rpc_kit.run(root, ["codecs"])
  let assert True =
    string.contains(error, "spike/other.Secret has no public constructors")
  let assert Ok(after) = simplifile.read(path)
  let assert Ok(other_after) = simplifile.read(other_path)
  let assert True = before == after
  let assert True = other_before == other_after

  // Stale codec constructors must not prevent regenerating the types closure.
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/spike/other.gleam",
      "pub type Item { Item(name: String, id: Int) }\n",
    )
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])
  let assert Ok(api) = simplifile.read(root <> "/src/spike/api.gleam")
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/spike/api.gleam",
      string.replace(api, "other.Item(\"pong\")", "other.Item(\"pong\", 1)"),
    )
  let assert Ok(_) = shell(root, "gleam", ["build", "--warnings-as-errors"])
  Nil
}

pub fn api_can_import_standalone_codecs_test() {
  let root = fixture_project("codecs_import")
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/spike/api.gleam",
      "import spike/codecs\nimport spike/other\nimport starflame/server.{type Context}\npub fn ping(_context: Context) -> other.Item { let _ = codecs.state_decoder() other.Item(\"pong\") }\n",
    )
  let assert Ok(_) = starflame_rpc_kit.run(root, ["generate"])
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])
  let assert Ok(_) = starflame_rpc_kit.run(root, ["check"])
  let assert Ok(_) = shell(root, "gleam", ["build", "--warnings-as-errors"])
  Nil
}

pub fn codecs_configuration_validation_test() {
  let root = fixture_project("codecs_config")
  let assert Ok(toml) = simplifile.read(root <> "/gleam.toml")
  let assert Ok(base) = toml |> string.split("[starflame]") |> list.first
  let assert Ok(_) = simplifile.write(root <> "/gleam.toml", base)
  let assert Ok(output) = starflame_rpc_kit.run(root, ["codecs"])
  let assert True = string.contains(output, "No codecs configured")
  // CRLF, comments, multiline arrays and literal strings are valid TOML.
  let assert Ok(_) =
    simplifile.write(
      root <> "/gleam.toml",
      base
        <> "[starflame] # comment\r\ncodecs = [\r\n 'spike/other:spike/codecs',\r\n]\r\n",
    )
  let assert Ok(_) = starflame_rpc_kit.run(root, ["codecs"])
  list.each(
    [
      #("codecs = [\"spike/types\"]", "Invalid codecs entry"),
      #("codecs = [\"spike/types:../escape\"]", "Invalid codecs entry"),
      #("codecs = [\"spike/types:spike/types\"]", "cannot overwrite"),
      #(
        "codecs = [\"spike/types:spike/codecs\", \"spike/other:spike/codecs\"]",
        "More than one",
      ),
      #("codecs = \"spike/types:spike/codecs\"", "must be an array"),
    ],
    fn(entry) {
      let assert Ok(_) =
        simplifile.write(
          root <> "/gleam.toml",
          base <> "[starflame]\n" <> entry.0 <> "\n",
        )
      let assert Error(error) = starflame_rpc_kit.run(root, ["codecs"])
      let assert True = string.contains(error, entry.1)
      Nil
    },
  )
  let assert Error(error) =
    starflame_rpc_kit.run(root, ["codecs", "spike/types"])
  let assert True = string.contains(error, "Usage:")
  Nil
}

@external(javascript, "./starflame_rpc_kit_test_ffi.mjs", "shell")
fn shell(
  directory: String,
  command: String,
  args: List(String),
) -> Result(String, String)
