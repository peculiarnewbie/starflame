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

const usage = "Usage:
  generate [--api <module>] [--out <module path>]
  check [--api <module>] [--out <module path>]"

type Command {
  Generate
  Check
}

type Config {
  Config(api: String, out: String)
}

/// Runs a command for the app in `root`.
pub fn run(root: String, arguments: List(String)) -> Result(String, String) {
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
    Check -> check(root, files)
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
  use json <- result.try(export_interface(root, config.api, config.out))
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
          simplifile.write(full, content)
          |> result.map(fn(_) { "Wrote " <> path })
          |> result.map_error(fn(error) {
            "Couldn't write "
            <> path
            <> ": "
            <> simplifile.describe_error(error)
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
    [] -> Ok("The generated RPC code is up to date.")
    _ ->
      Error(
        string.join(stale, "\n")
        <> "\nRun `gleam run -m starflame_rpc_kit -- generate`.",
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
) -> Result(String, String)
