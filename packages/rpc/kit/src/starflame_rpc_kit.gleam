//// Generates Starflame's RPC code from an API module: wire codecs, server
//// dispatchers, Cap'n Web targets and typed client functions.
////
//// Add it as a dev dependency and run it from the app's directory:
////
//// ```sh
//// gleam run -m starflame_rpc_kit -- generate
//// gleam run -m starflame_rpc_kit -- check
//// ```
////
//// By default the API is `<app>/api` and the code goes to
//// `src/<app>/generated/`. `--api todos/rpc` and `--out todos/rpc_generated`
//// change them; pass the same flags to `check`.
//// Standalone codecs use `codecs <module> --out <module path>`, or `codecs`
//// for every entry in `[starflame].codecs`. `check` includes those entries.

import argv
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile
import starflame_rpc_kit/codegen
import starflame_rpc_kit/interface
import starflame_rpc_kit/model

/// Runs the command in the process arguments and exits non-zero on failure.
pub fn main() -> Nil {
  case run(".", argv.load().arguments) {
    Ok(output) -> io.println(output)
    Error(error) -> {
      io.println_error(error)
      set_exit_code(1)
    }
  }
}

const usage =
  "Usage:
  generate [--api <module>] [--out <module path>]
  check [--api <module>] [--out <module path>]
  codecs [<module> --out <module path>]"

type Command {
  Generate
  Check
}

type Config {
  Config(api: String, out: String)
}

/// Runs a command for the app in `root`.
pub fn run(root: String, arguments: List(String)) -> Result(String, String) {
  case arguments {
    ["codecs", ..flags] -> {
      use entries <- result.try(case flags {
        [] -> configured_codecs(root)
        [module, "--out", out] -> validate_codec_entries([#(module, out)])
        _ -> Error(usage)
      })
      use files <- result.try(codec_files(root, entries))
      case files {
        [] -> Ok("No codecs configured in [starflame].codecs.")
        _ -> write(root, files)
      }
    }
    _ -> run_rpc(root, arguments)
  }
}

fn run_rpc(root: String, arguments: List(String)) -> Result(String, String) {
  use #(command, flags) <- result.try(case arguments {
    ["generate", ..flags] -> Ok(#(Generate, flags))
    ["check", ..flags] -> Ok(#(Check, flags))
    _ -> Error(usage)
  })
  use name <- result.try(package_name(root))
  use config <- result.try(parse_flags(flags, Config(name <> "/api", "")))
  let config = case config.out {
    "" -> Config(..config, out: default_out(config.api))
    _ -> config
  }
  use files <- result.try(files(root, config))
  case command {
    Generate -> write(root, files)
    Check -> {
      use entries <- result.try(configured_codecs(root))
      use codecs <- result.try(codec_files(root, entries))
      let generate_command =
        "generate --api " <> config.api <> " --out " <> config.out
      use rpc_status <- result.try(check(root, files, generate_command))
      use codec_status <- result.map(check(root, codecs, "codecs"))
      rpc_status <> "\n" <> codec_status
    }
  }
}

fn parse_flags(flags: List(String), config: Config) -> Result(Config, String) {
  case flags {
    [] -> Ok(config)
    ["--api", api, ..rest] -> parse_flags(rest, Config(..config, api:))
    ["--out", out, ..rest] -> parse_flags(rest, Config(..config, out:))
    _ -> Error(usage)
  }
}

/// Next to the API module: `todos/api` generates into `todos/generated`.
fn default_out(api: String) -> String {
  case string.split(api, "/") |> list.reverse {
    [_, ..parents] if parents != [] ->
      string.join(list.reverse(["generated", ..parents]), "/")
    _ -> "generated"
  }
}

fn package_name(root: String) -> Result(String, String) {
  use toml <- result.try(
    simplifile.read(root <> "/gleam.toml")
    |> result.replace_error("There's no gleam.toml in " <> root <> "."),
  )
  toml
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case string.split(line, "\"") {
      [key, name, _] ->
        case string.trim(key) {
          "name =" -> Ok(name)
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> result.replace_error("gleam.toml has no package name.")
}

/// Each generated file's path and content.
fn files(
  root: String,
  config: Config,
) -> Result(List(#(String, String)), String) {
  use json <- result.try(export_interface(root, config.api, config.out, False))
  use interface <- result.try(interface.parse(json))
  use api <- result.try(model.analyse(interface, config.api))
  use output <- result.try(codegen.generate(api, config.out))
  use wire <- result.try(format(output.wire))
  use server <- result.try(format(output.server))
  use client <- result.try(format(output.client))
  let dir = "src/" <> config.out <> "/"
  Ok([
    #(dir <> "wire.gleam", wire),
    #(dir <> "server.gleam", server),
    #(dir <> "client.gleam", client),
    #(dir <> "targets.ts", output.targets),
  ])
}

fn configured_codecs(root: String) -> Result(List(#(String, String)), String) {
  use toml <- result.try(
    simplifile.read(root <> "/gleam.toml")
    |> result.replace_error("There's no gleam.toml in " <> root <> "."),
  )
  use entries <- result.try(codec_entries(toml))
  validate_codec_entries(entries)
}

fn codec_files(
  root: String,
  entries: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  list.try_map(entries, fn(entry) {
    let #(module, out) = entry
    use json <- result.try(export_interface(root, module, out, True))
    use interface <- result.try(interface.parse(json))
    use types <- result.try(model.analyse_types(interface, module))
    use source <- result.try(codegen.generate_codecs(types, out))
    use source <- result.map(format(source))
    #("src/" <> out <> ".gleam", source)
  })
}

fn write(
  root: String,
  files: List(#(String, String)),
) -> Result(String, String) {
  use written <- result.map(
    list.try_map(files, fn(file) {
      let #(path, content) = file
      let full = root <> "/" <> path
      case simplifile.read(full) {
        Ok(existing) if existing == content -> Ok("Unchanged " <> path)
        _ -> {
          use Nil <- result.try(
            simplifile.create_directory_all(parent(full))
            |> result.map_error(fn(error) {
              "Couldn't create the directory for "
              <> path
              <> ": "
              <> simplifile.describe_error(error)
            }),
          )
          atomic_write(full, content)
          |> result.map(fn(_) { "Wrote " <> path })
          |> result.map_error(fn(error) {
            "Couldn't write " <> path <> ": " <> error
          })
        }
      }
    }),
  )
  string.join(written, "\n")
}

fn check(
  root: String,
  files: List(#(String, String)),
  command: String,
) -> Result(String, String) {
  let stale =
    list.filter_map(files, fn(file) {
      let #(path, content) = file
      case simplifile.read(root <> "/" <> path) {
        Ok(existing) if existing == content -> Error(Nil)
        Ok(_) -> Ok("  " <> path <> " is out of date")
        Error(_) -> Ok("  " <> path <> " is missing")
      }
    })
  case stale {
    [] ->
      Ok(
        "The generated "
        <> case command {
          "codecs" -> "codecs are"
          _ -> "RPC code is"
        }
        <> " up to date.",
      )
    _ ->
      Error(
        string.join(stale, "\n")
        <> "\nRun `gleam run -m starflame_rpc_kit -- "
        <> command
        <> "`.",
      )
  }
}

fn parent(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..parents] -> string.join(list.reverse(parents), "/")
    [] -> "."
  }
}

@external(javascript, "./starflame_rpc_kit_ffi.mjs", "set_exit_code")
fn set_exit_code(code: Int) -> Nil

@external(javascript, "./starflame_rpc_kit_ffi.mjs", "format")
fn format(source: String) -> Result(String, String)

@external(javascript, "./starflame_rpc_kit_ffi.mjs", "export_interface")
fn export_interface(
  root: String,
  api: String,
  generated: String,
  types_only: Bool,
) -> Result(String, String)

@external(javascript, "./starflame_rpc_kit_ffi.mjs", "codec_entries")
fn codec_entries(toml: String) -> Result(List(#(String, String)), String)

@external(javascript, "./starflame_rpc_kit_ffi.mjs", "validate_codec_entries")
fn validate_codec_entries(
  entries: List(#(String, String)),
) -> Result(List(#(String, String)), String)

@external(javascript, "./starflame_rpc_kit_ffi.mjs", "atomic_write")
fn atomic_write(path: String, content: String) -> Result(Nil, String)
