//// Generates reviewable D1 migrations from a `starflame_db` schema.
////
//// An app runs it from a dev module that passes its schema in, so the
//// schema is evaluated rather than parsed:
////
//// ```gleam
//// // dev/db_kit.gleam
//// import app/schema
//// import starflame_db_kit
////
//// pub fn main() {
////   starflame_db_kit.main(schema.schema())
//// }
//// ```
////
//// ```sh
//// gleam run -m db_kit -- generate add_posts
//// gleam run -m db_kit -- generate rename_name --rename users.name=display_name
//// gleam run -m db_kit -- generate drop_bio --allow-destructive
//// gleam run -m db_kit -- generate backfill_slugs --custom
//// gleam run -m db_kit -- check
//// ```
////
//// Migrations go to `migrations/`, where `wrangler d1 migrations apply`
//// finds them, and snapshots to `db/snapshots/`. The kit never applies
//// migrations to D1 itself.

import argv
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import starflame_db/schema.{type Schema, Schema}
import starflame_db_kit/history.{type Migration}
import starflame_db_kit/introspect
import starflame_db_kit/plan.{type Options, Options, Rename}
import starflame_db_kit/snapshot.{Snapshot}
import starflame_db_kit/sqlite
import starflame_db_kit/validate

pub type Config {
  Config(migrations_dir: String, snapshots_dir: String)
}

pub fn default_config() -> Config {
  Config(migrations_dir: "migrations", snapshots_dir: "db/snapshots")
}

/// Runs the command in the process arguments and exits non-zero on failure.
pub fn main(schema: Schema) -> Nil {
  case run(schema, default_config(), argv.load().arguments) {
    Ok(output) -> io.println(output)
    Error(error) -> {
      io.println_error(error)
      set_exit_code(1)
    }
  }
}

pub fn run(
  schema: Schema,
  config: Config,
  arguments: List(String),
) -> Result(String, String) {
  case arguments {
    ["generate", name, ..flags] -> {
      use #(options, custom) <- result.try(parse_flags(
        flags,
        plan.Options([], False),
        False,
      ))
      generate(schema, config, name, options, custom)
    }
    ["check"] -> check(schema, config)
    _ -> Error(usage)
  }
}

const usage = "Usage:
  generate <name> [--rename table.old=new]... [--allow-destructive]
  generate <name> --custom
  check"

fn parse_flags(
  flags: List(String),
  options: Options,
  custom: Bool,
) -> Result(#(Options, Bool), String) {
  case flags {
    [] ->
      Ok(#(Options(..options, renames: list.reverse(options.renames)), custom))
    ["--allow-destructive", ..rest] ->
      parse_flags(rest, Options(..options, allow_destructive: True), custom)
    ["--custom", ..rest] -> parse_flags(rest, options, True)
    ["--rename", rename, ..rest] ->
      case string.split_once(rename, ".") {
        Ok(#(table, columns)) ->
          case string.split_once(columns, "=") {
            Ok(#(from, to)) if table != "" && from != "" && to != "" ->
              parse_flags(
                rest,
                Options(..options, renames: [
                  Rename(table:, from:, to:),
                  ..options.renames
                ]),
                custom,
              )
            _ -> Error("--rename expects table.old=new, got " <> rename)
          }
        Error(Nil) -> Error("--rename expects table.old=new, got " <> rename)
      }
    [flag, ..] -> Error("Unknown option " <> flag <> "\n\n" <> usage)
  }
}

// GENERATE --------------------------------------------------------------------

fn generate(
  schema: Schema,
  config: Config,
  name: String,
  options: Options,
  custom: Bool,
) -> Result(String, String) {
  use <- stop_if(
    !valid_name(name),
    Error("Migration names must be lowercase snake_case: " <> name),
  )
  use history <- result.try(load(config))
  let previous = list.last(history) |> option.from_result
  let previous_schema = case previous {
    Some(migration) -> migration.snapshot.schema
    None -> Schema([])
  }
  let parent = case previous {
    Some(migration) -> snapshot.hash(migration.snapshot)
    None -> ""
  }

  use #(statements, notes, new_schema) <- result.try(case custom {
    True ->
      validate.validate(schema)
      |> result.map(fn(_) { #([], [], previous_schema) })
      |> result.map_error(problems("The schema is invalid"))
    False ->
      case plan.plan(previous_schema, schema, options) {
        Ok(plan) -> Ok(#(plan.statements, plan.notes, schema))
        Error(errors) -> Error(problems("Can't generate a migration")(errors))
      }
  })
  let unchanged =
    snapshot.canonical(new_schema) == snapshot.canonical(previous_schema)
  use <- stop_if(!custom && unchanged, Ok("No schema changes."))

  let id = history.pad(list.length(history) + 1) <> "_" <> name
  let draft =
    Snapshot(id:, parent:, checksum: None, custom:, schema: new_schema)
  let this = snapshot.hash(draft)
  let sql = render(statements, notes, parent, this, custom)
  let new_snapshot = case custom {
    // Left open so the custom migration can be edited until the next one.
    True -> draft
    False -> Snapshot(..draft, checksum: Some(snapshot.checksum(sql)))
  }
  let new = history.Migration(id:, sql:, snapshot: new_snapshot)

  // Freeze an open custom migration now that another follows it.
  let history =
    list.map(history, fn(migration) {
      case migration.snapshot.checksum {
        None ->
          history.Migration(
            ..migration,
            snapshot: Snapshot(
              ..migration.snapshot,
              checksum: Some(snapshot.checksum(migration.sql)),
            ),
          )
        Some(_) -> migration
      }
    })
  use _ <- result.try(
    scratch(list.append(history, [new]))
    |> result.map_error(problems(
      "The generated migration failed on a scratch database, so nothing was written",
    )),
  )

  use _ <- result.try(
    list.try_each(list.append(history, [new]), write(config, _))
    |> result.map_error(fn(error) { "Couldn't write files: " <> error }),
  )
  Ok(
    string.join(
      [
        "Wrote "
          <> config.migrations_dir
          <> "/"
          <> id
          <> ".sql and "
          <> config.snapshots_dir
          <> "/"
          <> id
          <> ".json",
        ..list.map(notes, fn(note) { "  " <> note })
      ],
      "\n",
    )
    <> case custom {
      True ->
        "\nAdd your statements to the migration. It can be edited until the next one is generated."
      False -> ""
    },
  )
}

fn render(
  statements: List(String),
  notes: List(String),
  parent: String,
  this: String,
  custom: Bool,
) -> String {
  let header = [
    case custom {
      True ->
        "-- Custom migration. Add statements below; the schema snapshot doesn't change."
      False ->
        "-- Generated by starflame_db_kit. Review before applying with `wrangler d1 migrations apply`."
    },
    "-- parent: "
      <> case parent {
      "" -> "none"
      _ -> parent
    },
    "-- snapshot: " <> this,
    ..list.map(notes, fn(note) { "-- " <> note })
  ]
  string.join(header, "\n")
  <> "\n\n"
  <> string.join(list.map(statements, fn(statement) { statement <> ";" }), "\n")
  <> case statements {
    [] -> ""
    _ -> "\n"
  }
}

fn write(config: Config, migration: Migration) -> Result(Nil, String) {
  let sql_path = config.migrations_dir <> "/" <> migration.id <> ".sql"
  let json_path = config.snapshots_dir <> "/" <> migration.id <> ".json"
  let describe = fn(path) {
    fn(error) { path <> ": " <> simplifile.describe_error(error) }
  }
  use _ <- result.try(
    simplifile.create_directory_all(config.migrations_dir)
    |> result.map_error(describe(config.migrations_dir)),
  )
  use _ <- result.try(
    simplifile.create_directory_all(config.snapshots_dir)
    |> result.map_error(describe(config.snapshots_dir)),
  )
  use _ <- result.try(write_if_changed(sql_path, migration.sql, describe))
  write_if_changed(json_path, snapshot.to_string(migration.snapshot), describe)
}

fn write_if_changed(path, contents, describe) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(existing) if existing == contents -> Ok(Nil)
    _ -> simplifile.write(path, contents) |> result.map_error(describe(path))
  }
}

// CHECK -----------------------------------------------------------------------

fn check(schema: Schema, config: Config) -> Result(String, String) {
  use history <- result.try(load(config))
  use _ <- result.try(
    validate.validate(schema)
    |> result.map_error(problems("The schema is invalid")),
  )
  use _ <- result.try(
    scratch(history)
    |> result.map_error(problems(
      "The migrations don't reproduce their snapshots",
    )),
  )
  let latest = case list.last(history) {
    Ok(migration) -> migration.snapshot.schema
    Error(Nil) -> Schema([])
  }
  case snapshot.canonical(latest) == snapshot.canonical(schema) {
    True ->
      Ok(
        string.inspect(list.length(history))
        <> " migrations verified; the schema matches the latest snapshot.",
      )
    False -> Error("The schema has changes without a migration. Run generate.")
  }
}

// SHARED ----------------------------------------------------------------------

fn load(config: Config) -> Result(List(Migration), String) {
  history.load(config.migrations_dir, config.snapshots_dir)
  |> result.map_error(problems("The migration history has problems"))
}

/// Applies every migration to an empty scratch database, one transaction per
/// file as wrangler does, and compares the result with each snapshot.
fn scratch(migrations: List(Migration)) -> Result(Nil, List(String)) {
  let database = sqlite.open()
  let result =
    list.try_each(migrations, fn(migration) {
      use _ <- result.try(
        sqlite.apply(database, migration.sql)
        |> result.map_error(fn(error) { [migration.id <> ": " <> error] }),
      )
      let differences =
        list.append(
          introspect.differences(database, migration.snapshot.schema),
          introspect.leftover_backups(database)
            |> list.map(fn(table) { "unexpected: backup table " <> table }),
        )
      case differences {
        [] -> Ok(Nil)
        _ ->
          Error(
            list.map(differences, fn(difference) {
              migration.id <> ": " <> difference
            }),
          )
      }
    })
  sqlite.close(database)
  result
}

fn problems(title: String) -> fn(List(String)) -> String {
  fn(errors) {
    title
    <> ":\n"
    <> list.map(errors, fn(error) { "- " <> error }) |> string.join("\n")
  }
}

fn valid_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(char) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", char)
  })
}

fn stop_if(
  condition: Bool,
  result: Result(String, String),
  next: fn() -> Result(String, String),
) -> Result(String, String) {
  case condition {
    True -> result
    False -> next()
  }
}

@external(javascript, "./starflame_db_kit_ffi.mjs", "set_exit_code")
fn set_exit_code(code: Int) -> Nil
