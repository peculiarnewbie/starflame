//// The committed migrations and their snapshots, verified.
////
//// wrangler records applied migrations by file name only: it ignores edits
//// to applied files and still applies a new file numbered below applied
//// ones. So the kit enforces numbering, the snapshot chain and checksums.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import starflame_db_kit/snapshot.{type Snapshot}

pub type Migration {
  Migration(id: String, sql: String, snapshot: Snapshot)
}

pub fn load(
  migrations_dir: String,
  snapshots_dir: String,
) -> Result(List(Migration), List(String)) {
  use migrations <- result.try(read_dir(migrations_dir, ".sql"))
  use snapshots <- result.try(read_dir(snapshots_dir, ".json"))
  verify(migrations, snapshots)
}

/// Files as #(name without extension, contents).
fn read_dir(
  dir: String,
  extension: String,
) -> Result(List(#(String, String)), List(String)) {
  case simplifile.read_directory(dir) {
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> Error([dir <> ": " <> simplifile.describe_error(error)])
    Ok(names) ->
      names
      |> list.filter(string.ends_with(_, extension))
      |> list.sort(string.compare)
      |> list.try_map(fn(name) {
        simplifile.read(dir <> "/" <> name)
        |> result.map(fn(text) {
          #(string.drop_end(name, string.length(extension)), text)
        })
        |> result.map_error(fn(error) {
          dir <> "/" <> name <> ": " <> simplifile.describe_error(error)
        })
      })
      |> result.map_error(fn(error) { [error] })
  }
}

pub fn verify(
  migrations: List(#(String, String)),
  snapshots: List(#(String, String)),
) -> Result(List(Migration), List(String)) {
  let names = fn(files: List(#(String, String))) {
    list.map(files, fn(file) { file.0 })
  }
  let numbers = list.filter_map(migrations, fn(file) { number(file.0) })
  let structure =
    list.flatten([
      list.filter_map(migrations, fn(file) {
        case number(file.0) {
          Ok(_) -> Error(Nil)
          Error(Nil) ->
            Ok(file.0 <> ".sql: migration names must look like 0001_name")
        }
      }),
      numbers
        |> list.group(fn(n) { n })
        |> dict.to_list
        |> list.filter_map(fn(group) {
          case group {
            #(n, [_, _, ..]) ->
              Ok(
                "two migrations are numbered "
                <> pad(n)
                <> ", probably from two branches. Delete the one from your "
                <> "branch, with its snapshot, and run generate again",
              )
            _ -> Error(Nil)
          }
        })
        |> list.sort(string.compare),
      case
        list.unique(numbers)
        |> list.sort(int.compare)
        |> list.index_map(fn(n, index) { n == index + 1 })
        |> list.all(fn(ok) { ok })
      {
        True -> []
        False -> ["migration numbers must run from 0001 without gaps"]
      },
      list.filter(names(migrations), fn(id) {
        !list.contains(names(snapshots), id)
      })
        |> list.map(fn(id) { id <> ".sql has no snapshot " <> id <> ".json" }),
      list.filter(names(snapshots), fn(id) {
        !list.contains(names(migrations), id)
      })
        |> list.map(fn(id) { id <> ".json has no migration " <> id <> ".sql" }),
    ])
  use <- guard(structure)

  let parsed =
    list.map(migrations, fn(file) {
      let #(id, sql) = file
      let assert Ok(#(_, text)) = list.find(snapshots, fn(s) { s.0 == id })
      snapshot.parse(text)
      |> result.map(fn(snapshot) { Migration(id:, sql:, snapshot:) })
      |> result.map_error(fn(error) { id <> ".json: " <> error })
    })
  use <- guard(
    list.filter_map(parsed, fn(result) {
      case result {
        Error(error) -> Ok(error)
        Ok(_) -> Error(Nil)
      }
    }),
  )
  let migrations = result.values(parsed)
  let count = list.length(migrations)
  let #(errors, _) =
    list.index_fold(migrations, #([], ""), fn(acc, migration, index) {
      let #(errors, parent) = acc
      let current = migration.snapshot
      let this = snapshot.hash(current)
      let latest = index == count - 1
      let errors =
        list.flatten([
          errors,
          case current.id == migration.id {
            True -> []
            False -> [migration.id <> ".json: its id is " <> current.id]
          },
          case current.parent == parent {
            True -> []
            False -> [
              migration.id
              <> " was generated on top of a different history than the "
              <> "migrations before it, probably on another branch. Delete it, "
              <> "with its snapshot, and run generate again",
            ]
          },
          case
            header(migration.sql, "parent"),
            header(migration.sql, "snapshot")
          {
            Ok(p), Ok(s) if s == this ->
              case p == parent || p == "none" && parent == "" {
                True -> []
                False -> [
                  migration.id <> ".sql: its header names another parent",
                ]
              }
            _, _ -> [
              migration.id
              <> ".sql: its header doesn't match its snapshot "
              <> this,
            ]
          },
          case current.checksum {
            Some(checksum) ->
              case checksum == snapshot.checksum(migration.sql) {
                True -> []
                False -> [
                  migration.id
                  <> ".sql was edited after it was generated. wrangler won't "
                  <> "reapply an applied file, so put further changes in a new "
                  <> "migration",
                ]
              }
            None if latest && current.custom -> []
            None -> [migration.id <> ".json: has no checksum"]
          },
        ])
      #(errors, this)
    })
  use <- guard(errors)
  Ok(migrations)
}

/// The value of a `-- name: value` header line.
pub fn header(sql: String, name: String) -> Result(String, Nil) {
  string.split(sql, "\n")
  |> list.take_while(string.starts_with(_, "--"))
  |> list.find_map(fn(line) {
    case string.split_once(line, "-- " <> name <> ": ") {
      Ok(#("", value)) -> Ok(string.trim(value))
      _ -> Error(Nil)
    }
  })
}

fn number(id: String) -> Result(Int, Nil) {
  case string.split_once(id, "_") {
    Ok(#(digits, name)) if name != "" ->
      case string.length(digits) >= 4 {
        True -> int.parse(digits)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

pub fn pad(number: Int) -> String {
  string.pad_start(int.to_string(number), 4, "0")
}

fn guard(
  errors: List(String),
  next: fn() -> Result(a, List(String)),
) -> Result(a, List(String)) {
  case errors {
    [] -> next()
    _ -> Error(errors)
  }
}
