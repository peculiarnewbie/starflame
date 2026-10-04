//// Checks the type system cannot express: names, keys and references.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import starflame_db/schema.{
  type Column, type Reference, type Schema, type Table, SetDefault, SetNull,
}

pub fn validate(schema: Schema) -> Result(Schema, List(String)) {
  let tables = list.map(schema.tables, fn(table) { table.name })
  let indexes =
    list.flat_map(schema.tables, fn(table) {
      list.map(table.indexes, fn(index) { index.name })
    })
  let errors =
    list.flatten([
      duplicates(tables, "table"),
      duplicates(list.map(schema.tables, fn(table) { table.row }), "row type"),
      // Index names share one namespace with tables.
      duplicates(list.append(tables, indexes), "table or index name"),
      list.flat_map(schema.tables, validate_table(schema, _)),
    ])
  case errors {
    [] -> Ok(schema)
    _ -> Error(errors)
  }
}

fn validate_table(schema: Schema, table: Table) -> List(String) {
  let columns = list.map(table.columns, fn(column) { column.name })
  let keys = list.filter(table.columns, fn(column) { column.primary_key })
  list.flatten([
    identifier(table.name),
    type_name(table.name, table.row),
    case table.columns {
      [] -> [table.name <> ": has no columns"]
      _ -> []
    },
    duplicates(columns, table.name <> " column"),
    list.flat_map(columns, identifier),
    case keys {
      [_] -> []
      [] -> [table.name <> ": needs exactly one primary key column"]
      _ -> [table.name <> ": composite primary keys are not supported yet"]
    },
    list.flat_map(table.columns, validate_column(schema, table, _)),
    duplicates(
      list.map(table.checks, fn(check) { check.name }),
      table.name <> " check",
    ),
    list.flat_map(table.checks, fn(check) { identifier(check.name) }),
    list.flat_map(table.indexes, fn(index) {
      let at = table.name <> ": index " <> index.name
      list.flatten([
        identifier(index.name),
        case index.columns {
          [] -> [at <> " has no columns"]
          _ -> []
        },
        duplicates(index.columns, at <> " column"),
        list.filter_map(index.columns, fn(column) {
          case list.contains(columns, column) {
            True -> Error(Nil)
            False -> Ok(at <> " has no column " <> column)
          }
        }),
      ])
    }),
  ])
}

fn validate_column(
  schema: Schema,
  table: Table,
  column: Column,
) -> List(String) {
  let at = table.name <> "." <> column.name
  list.flatten([
    case column.primary_key, column.kind {
      True, schema.IntKind | True, schema.TextKind -> []
      True, _ -> [at <> ": primary keys must be int or text"]
      False, _ -> []
    },
    case column.primary_key && column.nullable {
      True -> [at <> ": a primary key cannot be nullable"]
      False -> []
    },
    case column.primary_key && column.default != None {
      True -> [at <> ": a primary key cannot have a default"]
      False -> []
    },
    case column.references {
      None -> []
      Some(reference) -> validate_reference(schema, at, column, reference)
    },
  ])
}

fn validate_reference(
  schema: Schema,
  at: String,
  column: Column,
  reference: Reference,
) -> List(String) {
  let target =
    find_table(schema, reference.table)
    |> option.then(fn(target) {
      list.find(target.columns, fn(c) { c.name == reference.column })
      |> option.from_result
    })
  let target_name = reference.table <> "." <> reference.column
  case target {
    None -> [at <> ": references missing column " <> target_name]
    Some(target) ->
      list.flatten([
        case target.kind == column.kind {
          True -> []
          False -> [at <> ": type differs from " <> target_name]
        },
        case target.primary_key || target.unique {
          True -> []
          False -> [
            at <> ": " <> target_name <> " must be a primary key or unique",
          ]
        },
        case reference.on_delete, column.nullable, column.default {
          SetNull, False, _ -> [
            at <> ": ON DELETE SET NULL needs a nullable column",
          ]
          SetDefault, _, None -> [
            at <> ": ON DELETE SET DEFAULT needs a default",
          ]
          _, _, _ -> []
        },
      ])
  }
}

fn find_table(schema: Schema, name: String) -> Option(Table) {
  list.find(schema.tables, fn(table) { table.name == name })
  |> option.from_result
}

const reserved_prefixes = ["sqlite_", "_cf_", "__sf_", "d1_"]

fn identifier(name: String) -> List(String) {
  let reserved = list.any(reserved_prefixes, string.starts_with(name, _))
  let valid = case string.to_graphemes(name) {
    [first, ..rest] ->
      string.contains(lowercase, first)
      && list.all(rest, fn(char) { string.contains(lowercase <> digits, char) })
    [] -> False
  }
  case valid, reserved {
    True, False -> []
    False, _ -> [
      name <> ": names must be lowercase snake_case, starting with a letter",
    ]
    True, True -> [
      name
      <> ": names must not start with "
      <> string.join(reserved_prefixes, ", "),
    ]
  }
}

const lowercase = "abcdefghijklmnopqrstuvwxyz_"

const digits = "0123456789"

fn type_name(table: String, name: String) -> List(String) {
  let upper = string.uppercase(lowercase)
  let valid = case string.to_graphemes(name) {
    [first, ..rest] ->
      string.contains(upper, first)
      && first != "_"
      && list.all(rest, fn(char) {
        string.contains(upper <> lowercase <> digits, char) && char != "_"
      })
    [] -> False
  }
  case valid {
    True -> []
    False -> [table <> ": row type " <> name <> " must be UpperCamelCase"]
  }
}

fn duplicates(names: List(String), what: String) -> List(String) {
  names
  |> list.group(fn(name) { name })
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.filter_map(fn(group) {
    case group {
      #(name, [_, _, ..]) -> Ok("duplicate " <> what <> ": " <> name)
      _ -> Error(Nil)
    }
  })
}
