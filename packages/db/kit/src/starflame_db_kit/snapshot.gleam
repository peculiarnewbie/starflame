//// Schema snapshots: canonical JSON, one file per migration. Tables, indexes
//// and checks are sorted by name; columns keep declaration order, which only
//// matters for new tables. Each snapshot names its parent's hash, so a
//// history that diverged on two branches is detectable.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import starflame_db/schema.{
  type Action, type Column, type Default, type Kind, type Schema, type Table,
  Check, Column, Expression, Index, Literal, Reference, Schema, Table,
}
import starflame_db_kit/sql

pub const version = 1

pub type Snapshot {
  Snapshot(
    /// The migration's file name without `.sql`, such as `0002_add_posts`.
    id: String,
    /// The parent snapshot's hash; empty for the first.
    parent: String,
    /// SHA-256 of the migration file. `None` only while a custom migration is
    /// the latest and may still be edited.
    checksum: Option(String),
    custom: Bool,
    schema: Schema,
  )
}

pub fn canonical(schema: Schema) -> Schema {
  let by_name = fn(a: String, b: String) { string.compare(a, b) }
  Schema(
    schema.tables
    |> list.map(fn(table) {
      Table(
        ..table,
        indexes: list.sort(table.indexes, fn(a, b) { by_name(a.name, b.name) }),
        checks: list.sort(table.checks, fn(a, b) { by_name(a.name, b.name) }),
      )
    })
    |> list.sort(fn(a, b) { by_name(a.name, b.name) }),
  )
}

/// Identifies the schema and its position in the history. The id and
/// checksum are excluded, so filling in a custom migration's checksum later
/// doesn't change it.
pub fn hash(snapshot: Snapshot) -> String {
  Object([
    #("version", Int(version)),
    #("dialect", String("d1")),
    #("parent", String(snapshot.parent)),
    #("tables", Array(list.map(canonical(snapshot.schema).tables, table_json))),
  ])
  |> compact
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
  |> bit_array.base16_encode
  |> string.lowercase
  |> string.slice(0, 16)
}

pub fn checksum(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn to_string(snapshot: Snapshot) -> String {
  Object([
    #("version", Int(version)),
    #("dialect", String("d1")),
    #("id", String(snapshot.id)),
    #("parent", String(snapshot.parent)),
    #("checksum", case snapshot.checksum {
      Some(checksum) -> String(checksum)
      None -> Null
    }),
    #("custom", Bool(snapshot.custom)),
    #("tables", Array(list.map(canonical(snapshot.schema).tables, table_json))),
  ])
  |> pretty("")
  <> "\n"
}

fn table_json(table: Table) -> Json {
  Object([
    #("name", String(table.name)),
    #("row", String(table.row)),
    #("columns", Array(list.map(table.columns, column_json))),
    #(
      "indexes",
      Array(
        list.map(table.indexes, fn(index) {
          Object([
            #("name", String(index.name)),
            #("columns", Array(list.map(index.columns, String))),
            #("unique", Bool(index.unique)),
          ])
        }),
      ),
    ),
    #(
      "checks",
      Array(
        list.map(table.checks, fn(check) {
          Object([#("name", String(check.name)), #("sql", String(check.sql))])
        }),
      ),
    ),
  ])
}

fn column_json(column: Column) -> Json {
  Object([
    #("name", String(column.name)),
    #("kind", String(kind_name(column.kind))),
    #("nullable", Bool(column.nullable)),
    #("primary_key", Bool(column.primary_key)),
    #("unique", Bool(column.unique)),
    #("default", case column.default {
      Some(default) -> default_json(default)
      None -> Null
    }),
    #("references", case column.references {
      Some(reference) ->
        Object([
          #("table", String(reference.table)),
          #("column", String(reference.column)),
          #("on_delete", String(sql.action(reference.on_delete))),
        ])
      None -> Null
    }),
  ])
}

fn default_json(default: Default) -> Json {
  case default {
    Literal(sql) -> Object([#("literal", String(sql))])
    Expression(sql) -> Object([#("expression", String(sql))])
  }
}

pub fn kind_name(kind: Kind) -> String {
  case kind {
    schema.IntKind -> "int"
    schema.FloatKind -> "float"
    schema.TextKind -> "text"
    schema.BoolKind -> "bool"
    schema.TimestampKind -> "timestamp"
  }
}

// JSON ------------------------------------------------------------------------

/// A JSON tree, so snapshots can be pretty-printed with stable formatting
/// and hashed compactly.
type Json {
  Object(List(#(String, Json)))
  Array(List(Json))
  String(String)
  Int(Int)
  Bool(Bool)
  Null
}

fn compact(value: Json) -> String {
  case value {
    Object(fields) ->
      "{"
      <> list.map(fields, fn(field) {
        quote(field.0) <> ":" <> compact(field.1)
      })
      |> string.join(",")
      <> "}"
    Array(items) -> "[" <> list.map(items, compact) |> string.join(",") <> "]"
    _ -> scalar(value)
  }
}

/// Objects and arrays of objects are broken over lines; arrays of scalars
/// stay on one line.
fn pretty(value: Json, indent: String) -> String {
  let inner = indent <> "  "
  case value {
    Object([]) -> "{}"
    Object(fields) ->
      "{\n"
      <> list.map(fields, fn(field) {
        inner <> quote(field.0) <> ": " <> pretty(field.1, inner)
      })
      |> string.join(",\n")
      <> "\n"
      <> indent
      <> "}"
    Array([]) -> "[]"
    Array(items) ->
      case list.all(items, is_scalar) {
        True -> "[" <> list.map(items, scalar) |> string.join(", ") <> "]"
        False ->
          "[\n"
          <> list.map(items, fn(item) { inner <> pretty(item, inner) })
          |> string.join(",\n")
          <> "\n"
          <> indent
          <> "]"
      }
    _ -> scalar(value)
  }
}

fn is_scalar(value: Json) -> Bool {
  case value {
    Object(_) | Array(_) -> False
    _ -> True
  }
}

fn scalar(value: Json) -> String {
  case value {
    String(text) -> quote(text)
    Int(value) -> int.to_string(value)
    Bool(True) -> "true"
    Bool(False) -> "false"
    Null -> "null"
    Object(_) | Array(_) -> compact(value)
  }
}

fn quote(text: String) -> String {
  json.to_string(json.string(text))
}

// DECODING --------------------------------------------------------------------

pub fn parse(text: String) -> Result(Snapshot, String) {
  case json.parse(text, decoder()) {
    Ok(snapshot) -> Ok(snapshot)
    Error(json.UnableToDecode(errors)) ->
      Error(
        list.map(errors, fn(error) {
          "expected "
          <> error.expected
          <> ", found "
          <> error.found
          <> " at "
          <> string.join(error.path, ".")
        })
        |> string.join("; "),
      )
    Error(_) -> Error("invalid JSON")
  }
}

fn decoder() -> Decoder(Snapshot) {
  use found <- decode.field("version", decode.int)
  use <- guard(found == version, "snapshot version " <> int.to_string(version))
  use dialect <- decode.field("dialect", decode.string)
  use <- guard(dialect == "d1", "dialect d1")
  use id <- decode.field("id", decode.string)
  use parent <- decode.field("parent", decode.string)
  use checksum <- decode.field("checksum", decode.optional(decode.string))
  use custom <- decode.field("custom", decode.bool)
  use tables <- decode.field("tables", decode.list(table_decoder()))
  decode.success(Snapshot(
    id:,
    parent:,
    checksum:,
    custom:,
    schema: Schema(tables),
  ))
}

fn guard(
  condition: Bool,
  expected: String,
  next: fn() -> Decoder(Snapshot),
) -> Decoder(Snapshot) {
  case condition {
    True -> next()
    False -> decode.failure(Snapshot("", "", None, False, Schema([])), expected)
  }
}

fn table_decoder() -> Decoder(Table) {
  use name <- decode.field("name", decode.string)
  use row <- decode.field("row", decode.string)
  use columns <- decode.field("columns", decode.list(column_decoder()))
  use indexes <- decode.field(
    "indexes",
    decode.list({
      use name <- decode.field("name", decode.string)
      use columns <- decode.field("columns", decode.list(decode.string))
      use unique <- decode.field("unique", decode.bool)
      decode.success(Index(name:, columns:, unique:))
    }),
  )
  use checks <- decode.field(
    "checks",
    decode.list({
      use name <- decode.field("name", decode.string)
      use sql <- decode.field("sql", decode.string)
      decode.success(Check(name:, sql:))
    }),
  )
  decode.success(Table(name:, row:, columns:, indexes:, checks:))
}

fn column_decoder() -> Decoder(Column) {
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.string |> decode.then(kind_decoder))
  use nullable <- decode.field("nullable", decode.bool)
  use primary_key <- decode.field("primary_key", decode.bool)
  use unique <- decode.field("unique", decode.bool)
  use default <- decode.field(
    "default",
    decode.optional(
      decode.one_of(
        decode.field("literal", decode.string, fn(sql) {
          decode.success(Literal(sql))
        }),
        [
          decode.field("expression", decode.string, fn(sql) {
            decode.success(Expression(sql))
          }),
        ],
      ),
    ),
  )
  use references <- decode.field(
    "references",
    decode.optional({
      use table <- decode.field("table", decode.string)
      use column <- decode.field("column", decode.string)
      use on_delete <- decode.field(
        "on_delete",
        decode.string |> decode.then(action_decoder),
      )
      decode.success(Reference(table:, column:, on_delete:))
    }),
  )
  decode.success(Column(
    name:,
    kind:,
    nullable:,
    primary_key:,
    unique:,
    default:,
    references:,
  ))
}

fn kind_decoder(name: String) -> Decoder(Kind) {
  case name {
    "int" -> decode.success(schema.IntKind)
    "float" -> decode.success(schema.FloatKind)
    "text" -> decode.success(schema.TextKind)
    "bool" -> decode.success(schema.BoolKind)
    "timestamp" -> decode.success(schema.TimestampKind)
    _ -> decode.failure(schema.IntKind, "column kind")
  }
}

fn action_decoder(name: String) -> Decoder(Action) {
  case name {
    "NO ACTION" -> decode.success(schema.NoAction)
    "RESTRICT" -> decode.success(schema.Restrict)
    "CASCADE" -> decode.success(schema.Cascade)
    "SET NULL" -> decode.success(schema.SetNull)
    "SET DEFAULT" -> decode.success(schema.SetDefault)
    _ -> decode.failure(schema.NoAction, "foreign key action")
  }
}
