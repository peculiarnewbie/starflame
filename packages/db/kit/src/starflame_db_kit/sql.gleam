//// DDL for STRICT D1 tables. Identifiers are always quoted, so names that are
//// SQL keywords work.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import starflame_db/schema.{type Action, type Column, type Index, type Table}

pub fn create_table(table: Table) -> String {
  let columns = list.map(table.columns, column)
  let checks =
    list.map(table.checks, fn(check) {
      "CONSTRAINT " <> quote(check.name) <> " CHECK (" <> check.sql <> ")"
    })
  "CREATE TABLE "
  <> quote(table.name)
  <> " (\n  "
  <> string.join(list.append(columns, checks), ",\n  ")
  <> "\n) STRICT"
}

pub fn create_index(table: String, index: Index) -> String {
  "CREATE "
  <> case index.unique {
    True -> "UNIQUE "
    False -> ""
  }
  <> "INDEX "
  <> quote(index.name)
  <> " ON "
  <> quote(table)
  <> " ("
  <> string.join(list.map(index.columns, quote), ", ")
  <> ")"
}

pub fn column(column: Column) -> String {
  string.join(
    list.flatten([
      [quote(column.name), storage(column.kind)],
      when(column.primary_key, "PRIMARY KEY"),
      // An INTEGER PRIMARY KEY is the rowid and never NULL; other keys need
      // NOT NULL spelled out.
      when(!column.nullable && !is_rowid(column), "NOT NULL"),
      when(column.unique, "UNIQUE"),
      case column.default {
        Some(schema.Literal(sql)) -> ["DEFAULT " <> sql]
        Some(schema.Expression(sql)) -> ["DEFAULT (" <> sql <> ")"]
        None -> []
      },
      // The storage type can't enforce this kind.
      case column.kind {
        schema.BoolKind -> ["CHECK (" <> quote(column.name) <> " IN (0, 1))"]
        _ -> []
      },
      case column.references {
        Some(reference) -> [
          "REFERENCES "
          <> quote(reference.table)
          <> " ("
          <> quote(reference.column)
          <> ") ON DELETE "
          <> action(reference.on_delete),
        ]
        None -> []
      },
    ]),
    " ",
  )
}

pub fn storage(kind: schema.Kind) -> String {
  case kind {
    schema.IntKind | schema.BoolKind | schema.TimestampKind -> "INTEGER"
    schema.FloatKind -> "REAL"
    schema.TextKind -> "TEXT"
  }
}

pub fn is_rowid(column: Column) -> Bool {
  column.primary_key && storage(column.kind) == "INTEGER"
}

pub fn action(action: Action) -> String {
  case action {
    schema.NoAction -> "NO ACTION"
    schema.Restrict -> "RESTRICT"
    schema.Cascade -> "CASCADE"
    schema.SetNull -> "SET NULL"
    schema.SetDefault -> "SET DEFAULT"
  }
}

pub fn quote(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

fn when(condition: Bool, value: String) -> List(String) {
  case condition {
    True -> [value]
    False -> []
  }
}
