//// Cases for `starflame/d1`, run against local D1 by `test/d1.mjs`. Each
//// check gets a fresh table set, so cases don't depend on each other.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import starflame/d1.{
  Check, ConstraintError, DecodeError, ForeignKey, InvalidValue, NotNull,
  Outcome, PrimaryKey, QueryError, Trigger, Unique,
}
import starflame/fast_decode.{Field}
import starflame/plain
import starflame/server

const max_safe = 9_007_199_254_740_991

pub type Check {
  Pass(name: String)
  Fail(name: String, detail: String)
}

const schema = [
  "DROP TABLE IF EXISTS posts", "DROP TABLE IF EXISTS users",
  "CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    age INTEGER CONSTRAINT adult CHECK (age >= 18),
    admin INTEGER NOT NULL DEFAULT 0,
    avatar BLOB,
    score REAL
  ) STRICT",
  "CREATE TABLE posts (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    title TEXT NOT NULL
  ) STRICT",
  "CREATE TRIGGER IF NOT EXISTS no_spam BEFORE INSERT ON posts
    WHEN NEW.title = 'spam' BEGIN SELECT RAISE(ABORT, 'no spam'); END",
]

pub fn main(env: Dynamic, execution: Dynamic) -> Promise(List(Check)) {
  let context = server.new_context(env, execution)
  let db = d1.database(context, "DB")
  let other = d1.database(context, "OTHER")
  let cases = [
    #("round trip of every value kind", round_trip),
    #("D1-aware decoders", decoders),
    #("raw keeps duplicate column names", raw_duplicates),
    #("unsafe values are refused before reaching D1", invalid_values),
    #("constraint errors are classified", constraint_errors),
    #("query errors keep the SQLite code", query_errors),
    #("decode errors are reported", decode_errors),
    #("fast decoders agree with their fallbacks", fast_decoders),
    #("decode_rows decodes all rows; errors keep their paths", fast_rows),
    #("batch is atomic and returns each outcome", batch),
    #("setup runs once", fn(db, name) { setup(db, Nil, name) }),
    #("setup reports failures and retries", fn(_, name) {
      setup_failure(other, Nil, name)
    }),
  ]
  run_in_order(cases, db, [])
}

/// Every case resets the same tables, so they must not overlap.
fn run_in_order(
  cases: List(#(String, fn(d1.Database, String) -> Promise(List(Check)))),
  db: d1.Database,
  done: List(Check),
) -> Promise(List(Check)) {
  case cases {
    [] -> promise.resolve(done)
    [#(name, run), ..rest] -> {
      use reset <- promise.await(d1.batch(
        db,
        list.map(schema, d1.statement(_, [])),
      ))
      use checks <- promise.await(case reset {
        Error(error) ->
          promise.resolve([Fail(name, "reset: " <> d1.describe(error))])
        Ok(_) -> run(db, name)
      })
      run_in_order(rest, db, list.append(done, checks))
    }
  }
}

fn expect(name: String, actual: a, expected: a) -> Check {
  case actual == expected {
    True -> Pass(name)
    False ->
      Fail(
        name,
        "expected "
          <> string.inspect(expected)
          <> ", got "
          <> string.inspect(actual),
      )
  }
}

// CASES -----------------------------------------------------------------------

type User {
  User(
    id: Int,
    email: String,
    age: option.Option(Int),
    admin: Bool,
    avatar: option.Option(BitArray),
    score: option.Option(Float),
  )
}

fn user_decoder() {
  use id <- decode.field("id", d1.int_decoder())
  use email <- decode.field("email", decode.string)
  use age <- decode.field("age", decode.optional(d1.int_decoder()))
  use admin <- decode.field("admin", d1.bool_decoder())
  use avatar <- decode.field("avatar", decode.optional(d1.bit_array_decoder()))
  use score <- decode.field("score", decode.optional(decode.float))
  decode.success(User(id:, email:, age:, admin:, avatar:, score:))
}

const insert_user = "INSERT INTO users (id, email, age, admin, avatar, score)
  VALUES (?, ?, ?, ?, ?, ?) RETURNING *"

fn round_trip(db, name) {
  // A slice shares its parent's buffer; only its own bytes must be stored.
  let assert Ok(slice) = bit_array.slice(<<9, 8, 0, 255, 7>>, 1, 3)
  let max = max_safe
  use inserted <- promise.await(d1.all(
    db,
    insert_user,
    [
      d1.int(max),
      d1.string("a@example.com 🚀"),
      d1.nullable(None, d1.int),
      d1.bool(True),
      d1.bit_array(slice),
      d1.float(1.5),
    ],
    user_decoder(),
  ))
  use read <- promise.map(d1.all(
    db,
    "SELECT * FROM users WHERE id = ?",
    [d1.int(max)],
    user_decoder(),
  ))
  let expected =
    User(
      id: max,
      email: "a@example.com 🚀",
      age: None,
      admin: True,
      avatar: Some(<<8, 0, 255>>),
      score: Some(1.5),
    )
  [
    expect(name <> ": RETURNING", inserted, Ok([expected])),
    expect(name <> ": SELECT", read, Ok([expected])),
  ]
}

fn decoders(db, name) {
  use big <- promise.await(scalar(
    db,
    "SELECT 9007199254740993",
    d1.int_decoder(),
  ))
  use generic <- promise.await(scalar(db, "SELECT 9007199254740993", decode.int))
  use two <- promise.await(scalar(db, "SELECT 2", d1.bool_decoder()))
  use zero <- promise.await(scalar(db, "SELECT 0", d1.bool_decoder()))
  use empty <- promise.await(scalar(db, "SELECT x''", d1.bit_array_decoder()))
  use text <- promise.map(scalar(db, "SELECT 'abc'", d1.bit_array_decoder()))
  [
    expect(
      name <> ": int above 2^53 rejected",
      result_is_decode_error(big),
      True,
    ),
    // The generic decoder silently returns D1's rounded value.
    expect(
      name <> ": decode.int accepts the rounded value",
      generic,
      Ok([max_safe + 1]),
    ),
    expect(name <> ": bool 2 rejected", result_is_decode_error(two), True),
    expect(name <> ": bool 0", zero, Ok([False])),
    expect(name <> ": empty blob", empty, Ok([<<>>])),
    expect(name <> ": text is not a blob", result_is_decode_error(text), True),
  ]
}

fn raw_duplicates(db, name) {
  let pair = {
    use a <- decode.field(0, d1.int_decoder())
    use b <- decode.field(1, d1.int_decoder())
    decode.success(#(a, b))
  }
  use raw <- promise.await(d1.raw(db, "SELECT 1 AS x, 2 AS x", [], pair))
  use all <- promise.map(d1.all(
    db,
    "SELECT 1 AS x, 2 AS x",
    [],
    decode.field("x", d1.int_decoder(), decode.success),
  ))
  [
    expect(name <> ": raw", raw, Ok([#(1, 2)])),
    expect(name <> ": all keeps the last", all, Ok([2])),
  ]
}

fn invalid_values(db, name) {
  let attempt = fn(value) {
    d1.run(db, "INSERT INTO users (id, email) VALUES (1, ?)", [value])
  }
  use big <- promise.await(attempt(d1.int(max_safe + 1)))
  use bits <- promise.await(attempt(d1.bit_array(<<1:3>>)))
  use in_batch <- promise.await(
    d1.batch(db, [
      d1.statement("SELECT 1", []),
      d1.statement("SELECT ?, ?", [d1.int(1), d1.int(-max_safe - 1)]),
    ]),
  )
  use count <- promise.map(d1.all(
    db,
    "SELECT count(*) AS n FROM users",
    [],
    decode.field("n", d1.int_decoder(), decode.success),
  ))
  [
    expect(
      name <> ": unsafe int",
      big,
      Error(InvalidValue(1, "integer outside ±(2^53 - 1)")),
    ),
    expect(
      name <> ": partial byte",
      bits,
      Error(InvalidValue(1, "bit array is not a whole number of bytes")),
    ),
    expect(
      name <> ": batch names the statement",
      in_batch,
      Error(InvalidValue(2, "integer outside ±(2^53 - 1) (statement 2)")),
    ),
    expect(name <> ": nothing written", count, Ok([0])),
  ]
}

fn constraint_errors(db, name) {
  let insert = fn(id, email, age) {
    d1.run(db, "INSERT INTO users (id, email, age) VALUES (?, ?, ?)", [
      d1.int(id),
      d1.nullable(email, d1.string),
      d1.int(age),
    ])
  }
  let constraint = fn(result) {
    case result {
      Error(ConstraintError(constraint:, ..)) -> Ok(constraint)
      other -> Error(string.inspect(other))
    }
  }
  use first <- promise.await(insert(1, Some("a@example.com"), 20))
  use unique <- promise.await(insert(2, Some("a@example.com"), 20))
  use primary <- promise.await(insert(1, Some("b@example.com"), 20))
  use not_null <- promise.await(insert(3, None, 20))
  use check <- promise.await(insert(4, Some("c@example.com"), 5))
  use foreign_key <- promise.await(
    d1.run(db, "INSERT INTO posts (user_id, title) VALUES (99, 'x')", []),
  )
  use _ <- promise.await(
    d1.run(db, "INSERT INTO posts (user_id, title) VALUES (1, 'x')", []),
  )
  use restrict <- promise.await(d1.run(db, "DELETE FROM users", []))
  use datatype <- promise.await(
    d1.run(
      db,
      "INSERT INTO users (id, email, age) VALUES (5, 'd@example.com', 'x')",
      [],
    ),
  )
  use mismatch <- promise.await(
    d1.run(
      db,
      "INSERT INTO users (id, email) VALUES ('x', 'e@example.com')",
      [],
    ),
  )
  use trigger <- promise.map(
    d1.run(db, "INSERT INTO posts (user_id, title) VALUES (1, 'spam')", []),
  )
  [
    expect(name <> ": first insert", first, Ok(1)),
    expect(name <> ": unique", constraint(unique), Ok(Unique(["users.email"]))),
    expect(
      name <> ": primary key",
      constraint(primary),
      Ok(PrimaryKey(["users.id"])),
    ),
    expect(
      name <> ": not null",
      constraint(not_null),
      Ok(NotNull("users.email")),
    ),
    expect(name <> ": named check", constraint(check), Ok(Check("adult"))),
    expect(name <> ": foreign key", constraint(foreign_key), Ok(ForeignKey)),
    expect(
      name <> ": RESTRICT is a foreign key",
      constraint(restrict),
      Ok(ForeignKey),
    ),
    expect(name <> ": STRICT datatype", constraint(datatype), Ok(d1.Datatype)),
    expect(name <> ": rowid mismatch", constraint(mismatch), Ok(d1.Datatype)),
    expect(
      name <> ": trigger",
      trigger,
      Error(ConstraintError(Trigger, "no spam")),
    ),
    expect(
      name <> ": message",
      unique,
      Error(ConstraintError(
        Unique(["users.email"]),
        "UNIQUE constraint failed: users.email",
      )),
    ),
  ]
}

fn query_errors(db, name) {
  use syntax <- promise.await(d1.run(db, "SELEC 1", []))
  use missing <- promise.await(d1.run(db, "SELECT * FROM nope", []))
  use bindings <- promise.await(d1.run(db, "SELECT ?, ?", [d1.int(1)]))
  use begin <- promise.map(d1.run(db, "BEGIN", []))
  let code = fn(result) {
    case result {
      Error(QueryError(code:, ..)) -> Ok(code)
      other -> Error(string.inspect(other))
    }
  }
  [
    expect(
      name <> ": syntax",
      syntax,
      Error(QueryError(
        "SQLITE_ERROR",
        "near \"SELEC\": syntax error at offset 0",
      )),
    ),
    expect(
      name <> ": missing table",
      missing,
      Error(QueryError("SQLITE_ERROR", "no such table: nope")),
    ),
    // No SQLite code: D1 checks the count itself.
    expect(name <> ": binding count", code(bindings), Ok("")),
    expect(name <> ": BEGIN is refused", result_is_query_error(begin), True),
  ]
}

fn decode_errors(db, name) {
  use result <- promise.map(d1.all(
    db,
    "SELECT 'x' AS id",
    [],
    decode.field("id", d1.int_decoder(), decode.success),
  ))
  [
    expect(
      name,
      result,
      Error(DecodeError([decode.DecodeError("Int", "String", ["id"])])),
    ),
  ]
}

fn batch(db, name) {
  use failed <- promise.await(
    d1.batch(db, [
      d1.statement(
        "INSERT INTO users (id, email) VALUES (1, 'a@example.com')",
        [],
      ),
      d1.statement(
        "INSERT INTO users (id, email) VALUES (2, 'a@example.com')",
        [],
      ),
    ]),
  )
  use after_failure <- promise.await(count_users(db))
  use ok <- promise.await(
    d1.batch(db, [
      d1.statement("INSERT INTO users (id, email) VALUES (?, ?)", [
        d1.int(1),
        d1.string("a@example.com"),
      ]),
      d1.statement("UPDATE users SET admin = 1", []),
      d1.statement("SELECT id FROM users", []),
    ]),
  )
  let ids = case ok {
    Ok([_, _, Outcome(rows:, ..)]) ->
      d1.decode_rows(rows, decode.field("id", d1.int_decoder(), decode.success))
    _ -> Ok([])
  }
  let changes = case ok {
    Ok(outcomes) -> list.map(outcomes, fn(outcome) { outcome.changes })
    Error(_) -> []
  }
  use _ <- promise.map(promise.resolve(Nil))
  [
    expect(
      name <> ": failure is a constraint error",
      failed,
      Error(ConstraintError(
        Unique(["users.email"]),
        "UNIQUE constraint failed: users.email",
      )),
    ),
    expect(name <> ": failure rolled back", after_failure, Ok([0])),
    expect(name <> ": changes", changes, [1, 1, 0]),
    expect(name <> ": rows", ids, Ok([1])),
  ]
}

fn setup(db, _ignored, name) {
  let statements = [
    "CREATE TABLE setup_runs (n INTEGER)",
    "INSERT INTO setup_runs VALUES (1)",
  ]
  use first <- promise.await(d1.setup(db, statements))
  use second <- promise.await(d1.setup(db, statements))
  use runs <- promise.map(d1.all(
    db,
    "SELECT count(*) AS n FROM setup_runs",
    [],
    decode.field("n", d1.int_decoder(), decode.success),
  ))
  [
    expect(name <> ": first", first, Ok(Nil)),
    expect(name <> ": second is cached", second, Ok(Nil)),
    expect(name <> ": ran once", runs, Ok([1])),
  ]
}

fn setup_failure(other, _ignored, name) {
  use broken <- promise.await(d1.setup(other, ["CREATE TABLE ("]))
  use retried <- promise.map(d1.setup(other, ["CREATE TABLE fixed (x)"]))
  [
    expect(name <> ": failure", result_is_query_error(broken), True),
    expect(name <> ": retried", retried, Ok(Nil)),
  ]
}

// HELPERS ---------------------------------------------------------------------

type Sample {
  Sample(
    int: Int,
    safe: Int,
    float: Float,
    string: String,
    bool: Bool,
    zero_one: Bool,
    maybe: option.Option(Int),
  )
}

const sample_fields = [
  Field("int", fast_decode.IntKind, False),
  Field("safe", fast_decode.SafeIntKind, False),
  Field("float", fast_decode.FloatKind, False),
  Field("string", fast_decode.StringKind, False),
  Field("bool", fast_decode.BoolKind, False),
  Field("zero_one", fast_decode.ZeroOrOneKind, False),
  Field("maybe", fast_decode.SafeIntKind, True),
]

fn sample_from(value: Dynamic) -> Sample {
  Sample(
    int: fast_decode.get(value, "int"),
    safe: fast_decode.get(value, "safe"),
    float: fast_decode.get(value, "float"),
    string: fast_decode.get(value, "string"),
    bool: fast_decode.get(value, "bool"),
    zero_one: fast_decode.zero_or_one(value, "zero_one"),
    maybe: fast_decode.nullable(value, "maybe", fast_decode.get),
  )
}

fn sample_fallback() -> decode.Decoder(Sample) {
  use int <- decode.field("int", decode.int)
  use safe <- decode.field("safe", d1.int_decoder())
  use float <- decode.field("float", decode.float)
  use string <- decode.field("string", decode.string)
  use bool <- decode.field("bool", decode.bool)
  use zero_one <- decode.field("zero_one", d1.bool_decoder())
  use maybe <- decode.field("maybe", decode.optional(d1.int_decoder()))
  decode.success(Sample(int:, safe:, float:, string:, bool:, zero_one:, maybe:))
}

/// A valid sample object with one field replaced, or removed if `value` is
/// None.
fn sample(field: String, value: option.Option(plain.Plain)) -> Dynamic {
  [
    #("int", plain.int(-3)),
    #("safe", plain.int(max_safe)),
    #("float", plain.float(1.5)),
    #("string", plain.string("text")),
    #("bool", plain.bool(True)),
    #("zero_one", plain.int(1)),
    #("maybe", plain.int(7)),
  ]
  |> list.filter_map(fn(entry) {
    case entry.0 == field, value {
      False, _ -> Ok(entry)
      True, Some(value) -> Ok(#(field, value))
      True, None -> Error(Nil)
    }
  })
  |> plain.object
  |> plain.to_dynamic
}

fn fast_decoders(_db, name) {
  let fast = fast_decode.decoder(sample_fields, sample_from, sample_fallback())
  // Fails everything, so a decoded value proves the fast path ran.
  let fast_only =
    fast_decode.decoder(
      sample_fields,
      sample_from,
      decode.failure(sample_from(sample("", None)), "fast path"),
    )
  let valid = [
    #("valid", sample("", None)),
    #("null nullable", sample("maybe", Some(plain.null()))),
    #("whole float", sample("float", Some(plain.int(3)))),
    #("zero", sample("zero_one", Some(plain.int(0)))),
  ]
  let invalid = [
    #("fractional int", sample("int", Some(plain.float(1.5)))),
    #("unsafe int", sample("safe", Some(plain.float(9_007_199_254_740_992.0)))),
    #("string for float", sample("float", Some(plain.string("1.5")))),
    #("1 for bool", sample("bool", Some(plain.int(1)))),
    #("true for 0/1", sample("zero_one", Some(plain.bool(True)))),
    #("2 for 0/1", sample("zero_one", Some(plain.int(2)))),
    #("null for non-null", sample("string", Some(plain.null()))),
    #("wrong nullable", sample("maybe", Some(plain.string("7")))),
    #("missing field", sample("string", None)),
    #("not an object", plain.to_dynamic(plain.string("text"))),
  ]
  promise.resolve(
    list.flatten([
      list.map(list.append(valid, invalid), fn(input) {
        expect(
          name <> ": " <> input.0,
          decode.run(input.1, fast),
          decode.run(input.1, sample_fallback()),
        )
      }),
      list.map(valid, fn(input) {
        expect(
          name <> ": " <> input.0 <> " takes the fast path",
          decode.run(input.1, fast_only) |> result_is_ok,
          True,
        )
      }),
    ]),
  )
}

/// `decode_rows` decodes all rows in one run, and falls back to one run per
/// row for errors without a row index.
fn fast_rows(db, name) {
  use inserted <- promise.await(
    d1.run(
      db,
      "INSERT INTO users (id, email, admin) VALUES (1, 'a@b', 0), (2, 'c@d', 1)",
      [],
    ),
  )
  use rows <- promise.await(
    d1.all(db, "SELECT id, email, admin FROM users ORDER BY id", [], {
      use id <- decode.field("id", d1.int_decoder())
      use admin <- decode.field("admin", d1.bool_decoder())
      decode.success(#(id, admin))
    }),
  )
  use bad <- promise.map(d1.all(
    db,
    "SELECT id, email AS admin FROM users ORDER BY id",
    [],
    decode.field("admin", d1.bool_decoder(), decode.success),
  ))
  [
    expect(name <> ": inserted", inserted, Ok(2)),
    expect(name <> ": rows", rows, Ok([#(1, False), #(2, True)])),
    expect(
      name <> ": error without a row index",
      bad,
      Error(DecodeError([decode.DecodeError("Int", "String", ["admin"])])),
    ),
  ]
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn scalar(db, sql, decoder) {
  d1.raw(db, sql, [], decode.field(0, decoder, decode.success))
}

fn count_users(db) {
  d1.all(
    db,
    "SELECT count(*) AS n FROM users",
    [],
    decode.field("n", d1.int_decoder(), decode.success),
  )
}

fn result_is_decode_error(result) {
  case result {
    Error(DecodeError(_)) -> True
    _ -> False
  }
}

fn result_is_query_error(result) {
  case result {
    Error(QueryError(..)) -> True
    _ -> False
  }
}
