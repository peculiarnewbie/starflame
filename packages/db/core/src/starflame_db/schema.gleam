//// Database schemas as plain Gleam values. Helpers, constants and pipelines
//// need no special support: `starflame_db_kit` runs the compiled schema
//// module rather than parsing its source.
////
//// ```gleam
//// import starflame_db/schema as s
////
//// pub fn schema() -> s.Schema {
////   s.schema([
////     s.table("users", row: "User")
////     |> s.int("id", [s.primary_key()])
////     |> s.text("email", [s.unique()])
////     |> s.bool("admin", [s.default(False)])
////     |> s.timestamp("created_at", [s.default_now()])
////     |> s.check("users_email_at", "instr(email, '@') > 1"),
////   ])
//// }
//// ```
////
//// Columns are NOT NULL unless `nullable()`. Every table is STRICT.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp.{type Timestamp}

pub type Schema {
  Schema(tables: List(Table))
}

pub type Table {
  Table(
    name: String,
    /// The Gleam type name for a row, such as `User`.
    row: String,
    columns: List(Column),
    indexes: List(Index),
    checks: List(Check),
  )
}

pub type Column {
  Column(
    name: String,
    kind: Kind,
    nullable: Bool,
    primary_key: Bool,
    unique: Bool,
    default: Option(Default),
    references: Option(Reference),
  )
}

/// Each kind fixes the storage type and the Gleam type.
pub type Kind {
  /// INTEGER; Gleam `Int`.
  IntKind
  /// REAL; Gleam `Float`.
  FloatKind
  /// TEXT; Gleam `String`.
  TextKind
  /// INTEGER constrained to 0 or 1; Gleam `Bool`.
  BoolKind
  /// INTEGER Unix seconds; Gleam `Timestamp` from `gleam_time`.
  TimestampKind
}

pub type Default {
  /// A constant SQL literal.
  Literal(sql: String)
  /// A SQL expression, such as `unixepoch()`. Adding a column with one to an
  /// existing table needs a table rebuild.
  Expression(sql: String)
}

pub type Reference {
  Reference(table: String, column: String, on_delete: Action)
}

pub type Action {
  NoAction
  Restrict
  Cascade
  SetNull
  SetDefault
}

pub type Index {
  Index(name: String, columns: List(String), unique: Bool)
}

pub type Check {
  Check(name: String, sql: String)
}

// BUILDING --------------------------------------------------------------------

/// Column options. The type parameter ties `default` to the column's Gleam
/// type, so `bool("admin", [default(1)])` is a compile error.
pub opaque type Modifier(a) {
  PrimaryKey
  Unique
  Nullable
  DefaultValue(a)
  DefaultSql(String)
  References(Reference)
}

pub fn primary_key() -> Modifier(a) {
  PrimaryKey
}

pub fn unique() -> Modifier(a) {
  Unique
}

pub fn nullable() -> Modifier(a) {
  Nullable
}

pub fn default(value: a) -> Modifier(a) {
  DefaultValue(value)
}

/// A SQL expression default, for example `default_sql("lower(hex(randomblob(8)))")`.
/// Its SQL is not checked until the kit applies the migration to a scratch
/// database.
pub fn default_sql(sql: String) -> Modifier(a) {
  DefaultSql(sql)
}

/// The time of insertion.
pub fn default_now() -> Modifier(Timestamp) {
  DefaultSql("unixepoch()")
}

/// The referenced column must be a primary key or unique.
pub fn references(
  table: String,
  column: String,
  on_delete on_delete: Action,
) -> Modifier(a) {
  References(Reference(table:, column:, on_delete:))
}

pub fn schema(tables: List(Table)) -> Schema {
  Schema(tables)
}

pub fn table(name: String, row row: String) -> Table {
  Table(name:, row:, columns: [], indexes: [], checks: [])
}

pub fn int(
  table: Table,
  name: String,
  modifiers: List(Modifier(Int)),
) -> Table {
  add(table, name, IntKind, modifiers, int.to_string)
}

pub fn float(
  table: Table,
  name: String,
  modifiers: List(Modifier(Float)),
) -> Table {
  add(table, name, FloatKind, modifiers, float.to_string)
}

pub fn text(
  table: Table,
  name: String,
  modifiers: List(Modifier(String)),
) -> Table {
  add(table, name, TextKind, modifiers, quote)
}

pub fn bool(
  table: Table,
  name: String,
  modifiers: List(Modifier(Bool)),
) -> Table {
  add(table, name, BoolKind, modifiers, fn(value) {
    case value {
      True -> "1"
      False -> "0"
    }
  })
}

/// Stored as whole Unix seconds; sub-second precision is dropped.
pub fn timestamp(
  table: Table,
  name: String,
  modifiers: List(Modifier(Timestamp)),
) -> Table {
  add(table, name, TimestampKind, modifiers, fn(value) {
    let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(value)
    int.to_string(seconds)
  })
}

pub fn index(table: Table, name: String, columns: List(String)) -> Table {
  Table(
    ..table,
    indexes: list.append(table.indexes, [Index(name:, columns:, unique: False)]),
  )
}

pub fn unique_index(
  table: Table,
  name: String,
  columns: List(String),
) -> Table {
  Table(
    ..table,
    indexes: list.append(table.indexes, [Index(name:, columns:, unique: True)]),
  )
}

/// A named CHECK constraint. D1 reports the name when it fails.
pub fn check(table: Table, name: String, sql: String) -> Table {
  Table(..table, checks: list.append(table.checks, [Check(name:, sql:)]))
}

fn add(
  table: Table,
  name: String,
  kind: Kind,
  modifiers: List(Modifier(a)),
  literal: fn(a) -> String,
) -> Table {
  let column =
    list.fold(
      modifiers,
      Column(name, kind, False, False, False, None, None),
      fn(column, modifier) {
        case modifier {
          PrimaryKey -> Column(..column, primary_key: True)
          Unique -> Column(..column, unique: True)
          Nullable -> Column(..column, nullable: True)
          DefaultValue(value) ->
            Column(..column, default: Some(Literal(literal(value))))
          DefaultSql(sql) -> Column(..column, default: Some(Expression(sql)))
          References(reference) -> Column(..column, references: Some(reference))
        }
      },
    )
  Table(..table, columns: list.append(table.columns, [column]))
}

fn quote(value: String) -> String {
  "'" <> string.replace(value, "'", "''") <> "'"
}
