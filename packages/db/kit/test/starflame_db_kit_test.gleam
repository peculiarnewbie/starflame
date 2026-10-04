import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import simplifile
import starflame_db/schema as s
import starflame_db_kit.{type Config, Config}
import starflame_db_kit/history
import starflame_db_kit/plan.{Options, Rename}
import starflame_db_kit/snapshot.{Snapshot}
import starflame_db_kit/sqlite
import starflame_db_kit/validate

pub fn main() -> Nil {
  gleeunit.main()
}

// SCHEMAS ---------------------------------------------------------------------

fn users(name_column: String) -> s.Table {
  s.table("users", row: "User")
  |> s.int("id", [s.primary_key()])
  |> s.text("email", [s.unique()])
  |> s.text(name_column, [])
  |> s.bool("admin", [s.default(False)])
  |> s.timestamp("created_at", [s.default_now()])
  |> s.check("users_email_at", "instr(email, '@') > 1")
}

fn posts() -> s.Table {
  s.table("posts", row: "Post")
  |> s.int("id", [s.primary_key()])
  |> s.int("user_id", [s.references("users", "id", on_delete: s.Cascade)])
  |> s.text("title", [])
  |> s.text("body", [s.nullable()])
  |> s.index("posts_user_idx", ["user_id"])
}

fn comments() -> s.Table {
  s.table("comments", row: "Comment")
  |> s.int("id", [s.primary_key()])
  |> s.int("post_id", [s.references("posts", "id", on_delete: s.Cascade)])
  |> s.int("editor_id", [
    s.nullable(),
    s.references("users", "id", on_delete: s.SetNull),
  ])
  |> s.text("body", [])
}

fn v1() -> s.Schema {
  s.schema([users("name"), posts(), comments()])
}

/// In place: a nullable column, a defaulted NOT NULL column, a new table.
fn v2() -> s.Schema {
  s.schema([
    users("name") |> s.text("bio", [s.nullable()]),
    posts() |> s.int("views", [s.default(0)]),
    comments(),
    s.table("tags", row: "Tag")
      |> s.int("id", [s.primary_key()])
      |> s.text("name", [s.unique()]),
  ])
}

/// A rename, with an index on the renamed column.
fn v3() -> s.Schema {
  s.schema([
    users("display_name")
      |> s.text("bio", [s.nullable()])
      |> s.index("users_display_name_idx", ["display_name"]),
    posts() |> s.int("views", [s.default(0)]),
    comments(),
    s.table("tags", row: "Tag")
      |> s.int("id", [s.primary_key()])
      |> s.text("name", [s.unique()]),
  ])
}

/// A changed check on the root table rebuilds every table under it.
fn v4() -> s.Schema {
  s.schema([
    users("display_name")
      |> s.text("bio", [s.nullable()])
      |> s.index("users_display_name_idx", ["display_name"])
      |> s.check("users_name_length", "length(display_name) <= 100"),
    posts() |> s.int("views", [s.default(0)]),
    comments(),
    s.table("tags", row: "Tag")
      |> s.int("id", [s.primary_key()])
      |> s.text("name", [s.unique()]),
  ])
}

/// Destructive: drop a column and a table.
fn v5() -> s.Schema {
  s.schema([
    users("display_name")
      |> s.index("users_display_name_idx", ["display_name"])
      |> s.check("users_name_length", "length(display_name) <= 100"),
    posts() |> s.int("views", [s.default(0)]),
    comments(),
  ])
}

/// Tightening a column rebuilds posts and comments, but not users.
fn v6() -> s.Schema {
  s.schema([
    users("display_name")
      |> s.index("users_display_name_idx", ["display_name"])
      |> s.check("users_name_length", "length(display_name) <= 100"),
    s.table("posts", row: "Post")
      |> s.int("id", [s.primary_key()])
      |> s.int("user_id", [s.references("users", "id", on_delete: s.Cascade)])
      |> s.text("title", [])
      |> s.text("body", [s.default("")])
      |> s.index("posts_user_idx", ["user_id"])
      |> s.int("views", [s.default(0)]),
    comments(),
  ])
}

// SNAPSHOTS AND VALIDATION ----------------------------------------------------

pub fn snapshot_is_canonical_test() {
  let a = Snapshot("0001_a", "", None, False, v4())
  let shuffled = Snapshot(..a, schema: s.schema(list.reverse(v4().tables)))
  assert snapshot.to_string(a) == snapshot.to_string(shuffled)
  assert snapshot.hash(a) == snapshot.hash(shuffled)
  let assert Ok(parsed) = snapshot.parse(snapshot.to_string(a))
  assert parsed.schema == snapshot.canonical(a.schema)
  assert snapshot.hash(parsed) == snapshot.hash(a)
}

pub fn snapshot_rejects_unknown_versions_test() {
  let text =
    snapshot.to_string(Snapshot("0001_a", "", None, False, v1()))
    |> string.replace("\"version\": 1", "\"version\": 2")
  let assert Error(_) = snapshot.parse(text)
}

pub fn validation_test() {
  let bad =
    s.schema([
      s.table("users", row: "user")
        |> s.int("id", [s.primary_key(), s.nullable()])
        |> s.text("Email", [])
        |> s.int("team_id", [s.references("teams", "id", on_delete: s.Cascade)])
        |> s.int("manager_id", [
          s.references("users", "id", on_delete: s.SetNull),
        ])
        |> s.index("users", ["missing"]),
      s.table("sqlite_stuff", row: "Stuff") |> s.float("id", [s.primary_key()]),
    ])
  let assert Error(errors) = validate.validate(bad)
  assert errors
    == [
      "duplicate table or index name: users",
      "users: row type user must be UpperCamelCase",
      "Email: names must be lowercase snake_case, starting with a letter",
      "users.id: a primary key cannot be nullable",
      "users.team_id: references missing column teams.id",
      "users.manager_id: ON DELETE SET NULL needs a nullable column",
      "users: index users has no column missing",
      "sqlite_stuff: names must not start with sqlite_, _cf_, __sf_, d1_",
      "sqlite_stuff.id: primary keys must be int or text",
    ]
}

pub fn validation_rejects_generated_type_collisions_test() {
  let schema =
    s.schema([
      s.table("users", row: "User") |> s.int("id", [s.primary_key()]),
      s.table("new_users", row: "NewUser")
        |> s.int("id", [s.primary_key()]),
    ])
  let assert Error(errors) = validate.validate(schema)
  assert list.contains(
    errors,
    "new_users: row type NewUser conflicts with generated insert type NewUser from users",
  )
}

pub fn validation_rejects_reserved_generated_types_test() {
  let schema =
    s.schema([
      s.table("users", row: "Option") |> s.int("id", [s.primary_key()]),
    ])
  let assert Error(errors) = validate.validate(schema)
  assert list.contains(
    errors,
    "users: row type Option is reserved by code generation",
  )
}

pub fn validation_rejects_generated_function_collisions_test() {
  let schema =
    s.schema([
      s.table("one", row: "User") |> s.int("id", [s.primary_key()]),
      s.table("two", row: "user") |> s.int("id", [s.primary_key()]),
    ])
  let assert Error(errors) = validate.validate(schema)
  assert list.contains(errors, "duplicate generated function name: user")
}

pub fn validation_rejects_generated_field_collisions_test() {
  let schema =
    s.schema([
      s.table("users", row: "User")
      |> s.int("id", [s.primary_key()])
      |> s.text("type", [])
      |> s.text("type_", []),
    ])
  let assert Error(errors) = validate.validate(schema)
  assert list.contains(errors, "duplicate users generated field: type_")
}

// PLANNING --------------------------------------------------------------------

const no_options = Options(renames: [], allow_destructive: False)

pub fn no_op_test() {
  let assert Ok(plan) = plan.plan(v4(), v4(), no_options)
  assert plan.statements == []
}

pub fn refusals_suggest_renames_test() {
  let assert Error(errors) = plan.plan(v2(), v3(), no_options)
  assert errors
    == [
      "users.display_name is NOT NULL without a default, so existing rows have no value for it. Add a default, or add it as nullable, backfill it in a custom migration and then make it NOT NULL. If it was renamed, pass --rename users.name=display_name",
      "dropping users.name deletes its data; pass --allow-destructive to confirm. If it was renamed, pass --rename users.name=display_name",
    ]
  let assert Error(errors) = plan.plan(v4(), v5(), no_options)
  assert errors
    == [
      "dropping users.bio deletes its data; pass --allow-destructive to confirm",
      "dropping table tags deletes its data; pass --allow-destructive to confirm",
    ]
}

pub fn rename_is_in_place_test() {
  let options =
    Options(..no_options, renames: [Rename("users", "name", "display_name")])
  let assert Ok(plan) = plan.plan(v2(), v3(), options)
  assert plan.statements
    == [
      "ALTER TABLE \"users\" RENAME COLUMN \"name\" TO \"display_name\"",
      "CREATE INDEX \"users_display_name_idx\" ON \"users\" (\"display_name\")",
    ]
}

pub fn bad_renames_test() {
  let options =
    Options(..no_options, renames: [Rename("users", "nope", "display_name")])
  let assert Error([error, ..]) = plan.plan(v2(), v3(), options)
  assert error
    == "--rename users.nope=display_name: nope must exist only in the old schema"
}

pub fn closure_rebuild_order_test() {
  let assert Ok(plan) = plan.plan(v3(), v4(), no_options)
  let heads =
    list.map(plan.statements, fn(statement) {
      statement |> string.split("(") |> list.first |> unwrap |> string.trim
    })
  assert heads
    == [
      "PRAGMA defer_foreign_keys = ON",
      "CREATE TABLE \"__sf_bak_comments\" AS SELECT \"id\", \"post_id\", \"editor_id\", \"body\" FROM \"comments\"",
      "CREATE TABLE \"__sf_bak_posts\" AS SELECT \"id\", \"user_id\", \"title\", \"body\", \"views\" FROM \"posts\"",
      "CREATE TABLE \"__sf_bak_users\" AS SELECT \"id\", \"email\", \"display_name\", \"admin\", \"created_at\", \"bio\" FROM \"users\"",
      // Children before parents, so no ON DELETE action sees a child row.
      "DROP TABLE \"comments\"",
      "DROP TABLE \"posts\"",
      "DROP TABLE \"users\"",
      "CREATE TABLE \"users\"",
      "CREATE TABLE \"posts\"",
      "CREATE TABLE \"comments\"",
      "INSERT INTO \"users\"",
      "INSERT INTO \"posts\"",
      "INSERT INTO \"comments\"",
      "DROP TABLE \"__sf_bak_comments\"",
      "DROP TABLE \"__sf_bak_posts\"",
      "DROP TABLE \"__sf_bak_users\"",
      "CREATE INDEX \"posts_user_idx\" ON \"posts\"",
      "CREATE INDEX \"users_display_name_idx\" ON \"users\"",
    ]
  assert plan.notes
    == [
      "rebuild users: checks changed",
      "rebuild comments: references a rebuilt table, and D1 cannot disable foreign keys",
      "rebuild posts: references a rebuilt table, and D1 cannot disable foreign keys",
    ]
}

// THE WHOLE FLOW --------------------------------------------------------------

pub fn history_preserves_data_test() {
  let config = workspace("history")
  // Mirrors a deployed database: migrations are applied as they are made.
  let live = sqlite.open()

  assert generate(v1(), config, ["init"])
    == "Wrote build/kit-test/history/migrations/0001_init.sql and build/kit-test/history/db/snapshots/0001_init.json"
  apply_latest(live, config)
  exec(live, [
    "INSERT INTO users (id, email, name) VALUES (1, 'a@x.io', 'Ann'), (2, 'b@x.io', 'Bo')",
    "INSERT INTO posts (id, user_id, title) VALUES (10, 1, 'Hello'), (11, 2, 'Hi')",
    "INSERT INTO comments (id, post_id, editor_id, body) VALUES (100, 10, 2, 'Nice'), (101, 11, 1, 'Yo')",
  ])

  let _ = generate(v2(), config, ["profiles"])
  assert !string.contains(latest_sql(config), "__sf_bak_")
  apply_latest(live, config)
  exec(live, ["INSERT INTO tags (id, name) VALUES (1, 'gleam')"])

  let _ =
    generate(v3(), config, [
      "rename_name",
      "--rename",
      "users.name=display_name",
    ])
  apply_latest(live, config)

  let _ = generate(v4(), config, ["name_length"])
  assert string.contains(latest_sql(config), "DROP TABLE \"comments\"")
  apply_latest(live, config)
  // Cascades and SET NULL never fired: every row and value survived.
  assert rows(live, "SELECT id, display_name FROM users ORDER BY id")
    == ["1|Ann", "2|Bo"]
  assert rows(live, "SELECT id, user_id, views FROM posts ORDER BY id")
    == ["10|1|0", "11|2|0"]
  assert rows(live, "SELECT id, post_id, editor_id FROM comments ORDER BY id")
    == ["100|10|2", "101|11|1"]

  let assert Error(error) =
    starflame_db_kit.run(v5(), config, ["generate", "drop_bio"])
  assert string.contains(error, "pass --allow-destructive")
  let _ = generate(v5(), config, ["drop_bio", "--allow-destructive"])
  assert string.contains(
    latest_sql(config),
    "ALTER TABLE \"users\" DROP COLUMN \"bio\"",
  )
  apply_latest(live, config)

  let _ = generate(v6(), config, ["body_required"])
  let sql = latest_sql(config)
  assert string.contains(sql, "-- rebuild posts: body changed")
  assert !string.contains(sql, "DROP TABLE \"users\"")
  // Existing NULL bodies make the tightened column fail, atomically.
  exec(live, ["UPDATE posts SET body = 'text' WHERE body IS NULL"])
  apply_latest(live, config)
  assert rows(live, "SELECT count(*) FROM comments") == ["2"]
  assert rows(live, "PRAGMA foreign_key_check") == []

  assert starflame_db_kit.run(v6(), config, ["generate", "again"])
    == Ok("No schema changes.")
  let assert Ok(_) = starflame_db_kit.run(v6(), config, ["check"])
}

pub fn custom_migrations_test() {
  let config = workspace("custom")
  let _ = generate(v1(), config, ["init"])
  let output = generate(v1(), config, ["backfill", "--custom"])
  assert string.contains(output, "can be edited until the next one")
  let path = config.migrations_dir <> "/0002_backfill.sql"
  let assert Ok(sql) = simplifile.read(path)
  let assert Ok(_) =
    simplifile.write(path, sql <> "UPDATE users SET name = trim(name);\n")
  // Still open, so the edit is fine.
  let assert Ok(_) = starflame_db_kit.run(v1(), config, ["check"])

  let _ = generate(v2(), config, ["profiles"])
  let assert Ok(snapshot) =
    simplifile.read(config.snapshots_dir <> "/0002_backfill.json")
  assert !string.contains(snapshot, "\"checksum\": null")
  // Now frozen.
  let assert Ok(sql) = simplifile.read(path)
  let assert Ok(_) = simplifile.write(path, sql <> "DELETE FROM users;\n")
  let assert Error(error) = starflame_db_kit.run(v2(), config, ["check"])
  assert string.contains(
    error,
    "0002_backfill.sql was edited after it was generated",
  )
}

pub fn custom_migrations_must_not_change_the_schema_test() {
  let config = workspace("custom_schema")
  let _ = generate(v1(), config, ["init"])
  let _ = generate(v1(), config, ["sneaky", "--custom"])
  let path = config.migrations_dir <> "/0002_sneaky.sql"
  let assert Ok(sql) = simplifile.read(path)
  let assert Ok(_) =
    simplifile.write(path, sql <> "ALTER TABLE users ADD COLUMN bio TEXT;\n")
  let assert Error(error) = starflame_db_kit.run(v1(), config, ["check"])
  assert string.contains(
    error,
    "0002_sneaky: unexpected: column users.bio TEXT",
  )
}

pub fn divergent_branches_test() {
  let config = workspace("branches")
  let _ = generate(v1(), config, ["init"])
  // Two branches each generate 0002 from 0001.
  let _ = generate(v2(), config, ["ours"])
  let assert Ok(ours_sql) =
    simplifile.read(config.migrations_dir <> "/0002_ours.sql")
  let assert Ok(ours_json) =
    simplifile.read(config.snapshots_dir <> "/0002_ours.json")
  let theirs =
    s.schema([
      users("name") |> s.text("bio", [s.nullable()]),
      posts(),
      comments(),
    ])
  let assert Ok(_) =
    simplifile.delete(config.migrations_dir <> "/0002_ours.sql")
  let assert Ok(_) =
    simplifile.delete(config.snapshots_dir <> "/0002_ours.json")
  let _ = generate(theirs, config, ["theirs"])
  let assert Ok(_) =
    simplifile.write(config.migrations_dir <> "/0002_ours.sql", ours_sql)
  let assert Ok(_) =
    simplifile.write(config.snapshots_dir <> "/0002_ours.json", ours_json)

  let assert Error(error) = starflame_db_kit.run(v2(), config, ["check"])
  assert string.contains(error, "two migrations are numbered 0002")

  // Renumbering by hand doesn't help: the chain shows the fork.
  let assert Ok(_) =
    simplifile.rename(
      config.migrations_dir <> "/0002_ours.sql",
      config.migrations_dir <> "/0003_ours.sql",
    )
  let assert Ok(_) =
    simplifile.rename(
      config.snapshots_dir <> "/0002_ours.json",
      config.snapshots_dir <> "/0003_ours.json",
    )
  let assert Error(error) = starflame_db_kit.run(v2(), config, ["check"])
  assert string.contains(
    error,
    "0003_ours was generated on top of a different history",
  )
}

pub fn check_finds_pending_changes_test() {
  let config = workspace("pending")
  let _ = generate(v1(), config, ["init"])
  assert starflame_db_kit.run(v2(), config, ["check"])
    == Error("The schema has changes without a migration. Run generate.")
}

pub fn codegen_and_module_drift_test() {
  let config = workspace("codegen")
  assert starflame_db_kit.run(v1(), config, ["codegen"])
    == Error("No migrations yet; run generate first.")

  let _ = generate(v1(), config, ["init"])
  let assert Ok(generated) = simplifile.read(config.module)
  assert string.starts_with(generated, "//// Generated by starflame_db_kit")
  assert starflame_db_kit.run(v1(), config, ["codegen"])
    == Ok("Wrote " <> config.module)
  let assert Ok(regenerated) = simplifile.read(config.module)
  assert generated == regenerated
  let assert Ok(_) =
    simplifile.write(config.module, generated <> "// hand edit\n")
  let assert Error(out_of_date) = starflame_db_kit.run(v1(), config, ["check"])
  assert out_of_date == config.module <> " is out of date; run codegen"
  let assert Ok(_) = simplifile.delete(config.module)
  let assert Error(missing) = starflame_db_kit.run(v1(), config, ["check"])
  assert missing == config.module <> " is missing; run codegen"
  let assert Ok(_) = starflame_db_kit.run(v1(), config, ["codegen"])
  let assert Ok(_) = starflame_db_kit.run(v1(), config, ["check"])
}

pub fn self_reference_and_set_default_test() {
  let config = workspace("self")
  let categories = fn(check) {
    s.table("categories", row: "Category")
    |> s.int("id", [s.primary_key()])
    |> s.int("parent_id", [
      s.nullable(),
      s.references("categories", "id", on_delete: s.Restrict),
    ])
    |> s.int("fallback_id", [
      s.default(1),
      s.references("categories", "id", on_delete: s.SetDefault),
    ])
    |> s.text("name", [])
    |> s.check("categories_name", check)
  }
  let _ = generate(s.schema([categories("name <> ''")]), config, ["init"])
  let live = sqlite.open()
  apply_latest(live, config)
  exec(live, [
    "INSERT INTO categories (id, parent_id, fallback_id, name) VALUES (1, NULL, 1, 'root'), (2, 1, 1, 'a'), (3, 2, 2, 'b')",
  ])
  let _ =
    generate(s.schema([categories("length(name) > 0")]), config, ["check"])
  apply_latest(live, config)
  assert rows(
      live,
      "SELECT id, parent_id, fallback_id FROM categories ORDER BY id",
    )
    == ["1||1", "2|1|1", "3|2|2"]
}

pub fn keywords_are_quoted_test() {
  let config = workspace("keywords")
  let schema =
    s.schema([
      s.table("order", row: "Order")
      |> s.int("id", [s.primary_key()])
      |> s.text("group", [s.default("it's")])
      |> s.index("order_group", ["group"]),
    ])
  let _ = generate(schema, config, ["init"])
  let assert Ok(_) = starflame_db_kit.run(schema, config, ["check"])
}

pub fn header_test() {
  assert history.header(
      "-- parent: none\n-- snapshot: abc\n\nSELECT 1;",
      "snapshot",
    )
    == Ok("abc")
}

// HELPERS ---------------------------------------------------------------------

fn workspace(name: String) -> Config {
  let root = "build/kit-test/" <> name
  let _ = simplifile.delete(root)
  Config(
    migrations_dir: root <> "/migrations",
    snapshots_dir: root <> "/db/snapshots",
    module: root <> "/src/db.gleam",
  )
}

fn generate(
  schema: s.Schema,
  config: Config,
  arguments: List(String),
) -> String {
  case starflame_db_kit.run(schema, config, ["generate", ..arguments]) {
    Ok(output) -> output
    Error(error) -> panic as error
  }
}

fn latest_sql(config: Config) -> String {
  let assert Ok(names) = simplifile.read_directory(config.migrations_dir)
  let assert Ok(name) = list.sort(names, string.compare) |> list.last
  let assert Ok(sql) = simplifile.read(config.migrations_dir <> "/" <> name)
  sql
}

fn apply_latest(database: sqlite.Database, config: Config) -> Nil {
  case sqlite.apply(database, latest_sql(config)) {
    Ok(Nil) -> Nil
    Error(error) -> panic as error
  }
}

fn exec(database: sqlite.Database, statements: List(String)) -> Nil {
  list.each(statements, fn(sql) {
    case sqlite.exec(database, sql) {
      Ok(Nil) -> Nil
      Error(error) -> panic as { sql <> ": " <> error }
    }
  })
}

/// Rows as `|`-separated text, NULL as empty.
fn rows(database: sqlite.Database, sql: String) -> List(String) {
  sqlite.query(database, sql, [])
  |> list.map(row_text)
}

@external(javascript, "./starflame_db_kit_test_ffi.mjs", "row_text")
fn row_text(row: Dynamic) -> String

fn unwrap(result: Result(String, Nil)) -> String {
  let assert Ok(value) = result
  value
}
