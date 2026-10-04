//// Compares a database's actual schema with a snapshot. Both sides are
//// reduced to sorted lines of text ("facts"), so a difference reads as a
//// missing or unexpected line.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import starflame_db/schema.{type Schema}
import starflame_db_kit/sql.{quote}
import starflame_db_kit/sqlite.{type Database}

pub fn differences(database: Database, expected: Schema) -> List(String) {
  let actual = facts(database) |> set.from_list
  let expected = expected_facts(expected) |> set.from_list
  list.flatten([
    set.difference(expected, actual)
      |> set.to_list
      |> list.sort(string.compare)
      |> list.map(fn(fact) { "missing: " <> fact }),
    set.difference(actual, expected)
      |> set.to_list
      |> list.sort(string.compare)
      |> list.map(fn(fact) { "unexpected: " <> fact }),
  ])
}

fn expected_facts(schema: Schema) -> List(String) {
  list.flat_map(schema.tables, fn(table) {
    list.flatten([
      ["table " <> table.name <> " STRICT"],
      list.flat_map(table.columns, fn(column) {
        let at = table.name <> "." <> column.name
        list.flatten([
          [
            column_fact(
              at,
              sql.storage(column.kind),
              !column.nullable && !sql.is_rowid(column),
              case column.default {
                Some(schema.Literal(sql)) -> Some(sql)
                Some(schema.Expression(sql)) -> Some(sql)
                None -> None
              },
              column.primary_key,
            ),
          ],
          case column.unique {
            True -> ["unique " <> at]
            False -> []
          },
          case column.kind {
            schema.BoolKind -> ["0/1 check " <> at]
            _ -> []
          },
          case column.references {
            Some(reference) -> [
              "foreign key "
              <> at
              <> " -> "
              <> reference.table
              <> "."
              <> reference.column
              <> " ON DELETE "
              <> sql.action(reference.on_delete),
            ]
            None -> []
          },
        ])
      }),
      list.map(table.indexes, fn(index) {
        index_fact(table.name, index.name, index.unique, index.columns)
      }),
      list.map(table.checks, fn(check) {
        "check " <> table.name <> "." <> check.name
      }),
    ])
  })
}

fn column_fact(
  at: String,
  storage: String,
  not_null: Bool,
  default: option.Option(String),
  primary_key: Bool,
) -> String {
  "column "
  <> at
  <> " "
  <> storage
  <> case not_null {
    True -> " NOT NULL"
    False -> ""
  }
  <> case default {
    Some(sql) -> " DEFAULT " <> sql
    None -> ""
  }
  <> case primary_key {
    True -> " PRIMARY KEY"
    False -> ""
  }
}

fn index_fact(
  table: String,
  name: String,
  unique: Bool,
  columns: List(String),
) -> String {
  case unique {
    True -> "unique index "
    False -> "index "
  }
  <> name
  <> " on "
  <> table
  <> " ("
  <> string.join(columns, ", ")
  <> ")"
}

fn facts(database: Database) -> List(String) {
  let tables =
    sqlite.query(
      database,
      "SELECT name, strict FROM pragma_table_list
       WHERE schema = 'main' AND type = 'table'
         AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
         AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\'
         AND name <> 'd1_migrations'",
      [],
    )
    |> list.filter_map(
      decode.run(_, {
        use name <- decode.field("name", decode.string)
        use strict <- decode.field("strict", decode.int)
        decode.success(#(name, strict == 1))
      }),
    )
  list.flat_map(tables, fn(table) {
    let #(name, strict) = table
    list.flatten([
      [
        "table "
        <> name
        <> case strict {
          True -> " STRICT"
          False -> ""
        },
      ],
      column_facts(database, name),
      index_facts(database, name),
      foreign_key_facts(database, name),
      check_facts(database, name),
    ])
  })
}

fn column_facts(database: Database, table: String) -> List(String) {
  sqlite.query(
    database,
    "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?)",
    [table],
  )
  |> list.filter_map(
    decode.run(_, {
      use name <- decode.field("name", decode.string)
      use storage <- decode.field("type", decode.string)
      use not_null <- decode.field("notnull", decode.int)
      use default <- decode.field("dflt_value", decode.optional(decode.string))
      use primary_key <- decode.field("pk", decode.int)
      decode.success(column_fact(
        table <> "." <> name,
        storage,
        not_null == 1,
        default,
        primary_key > 0,
      ))
    }),
  )
}

fn index_facts(database: Database, table: String) -> List(String) {
  sqlite.query(
    database,
    "SELECT name, \"unique\", origin FROM pragma_index_list(?)",
    [table],
  )
  |> list.filter_map(
    decode.run(_, {
      use name <- decode.field("name", decode.string)
      use unique <- decode.field("unique", decode.int)
      use origin <- decode.field("origin", decode.string)
      decode.success(#(name, unique == 1, origin))
    }),
  )
  |> list.filter_map(fn(index) {
    let #(name, unique, origin) = index
    let columns =
      sqlite.query(
        database,
        "SELECT name FROM pragma_index_info(?) ORDER BY seqno",
        [name],
      )
      |> list.filter_map(decode.run(
        _,
        decode.field("name", decode.string, decode.success),
      ))
    case origin, columns {
      // A UNIQUE column constraint.
      "u", [column] -> Ok("unique " <> table <> "." <> column)
      // The primary key's own index, for non-rowid keys.
      "pk", _ -> Error(Nil)
      _, _ -> Ok(index_fact(table, name, unique, columns))
    }
  })
}

fn foreign_key_facts(database: Database, table: String) -> List(String) {
  sqlite.query(
    database,
    "SELECT \"from\", \"table\", \"to\", on_delete FROM pragma_foreign_key_list(?)",
    [table],
  )
  |> list.filter_map(
    decode.run(_, {
      use from <- decode.field("from", decode.string)
      use parent <- decode.field("table", decode.string)
      use to <- decode.field("to", decode.string)
      use on_delete <- decode.field("on_delete", decode.string)
      decode.success(
        "foreign key "
        <> table
        <> "."
        <> from
        <> " -> "
        <> parent
        <> "."
        <> to
        <> " ON DELETE "
        <> on_delete,
      )
    }),
  )
}

/// Named checks and the 0/1 check on Bool columns, found in the table's SQL.
fn check_facts(database: Database, table: String) -> List(String) {
  let definition =
    sqlite.query(
      database,
      "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?",
      [table],
    )
    |> list.filter_map(decode.run(
      _,
      decode.field("sql", decode.string, decode.success),
    ))
    |> string.join("")
  let named =
    string.split(definition, "CONSTRAINT ")
    |> list.drop(1)
    |> list.filter_map(fn(part) {
      case string.split_once(part, " CHECK ") {
        Ok(#(name, _)) -> Ok("check " <> table <> "." <> unquote(name))
        Error(Nil) -> Error(Nil)
      }
    })
  let bools =
    sqlite.query(database, "SELECT name FROM pragma_table_info(?)", [table])
    |> list.filter_map(decode.run(
      _,
      decode.field("name", decode.string, decode.success),
    ))
    |> list.filter(fn(column) {
      string.contains(definition, "CHECK (" <> quote(column) <> " IN (0, 1))")
    })
    |> list.map(fn(column) { "0/1 check " <> table <> "." <> column })
  list.append(named, bools)
}

fn unquote(name: String) -> String {
  case string.starts_with(name, "\"") && string.ends_with(name, "\"") {
    True ->
      name
      |> string.drop_start(1)
      |> string.drop_end(1)
      |> string.replace("\"\"", "\"")
    False -> name
  }
}

/// Tables that only the planner should ever create.
pub fn leftover_backups(database: Database) -> List(String) {
  sqlite.query(
    database,
    "SELECT name FROM sqlite_schema WHERE name LIKE '\\_\\_sf\\_%' ESCAPE '\\'",
    [],
  )
  |> list.filter_map(decode.run(
    _,
    decode.field("name", decode.string, decode.success),
  ))
}
