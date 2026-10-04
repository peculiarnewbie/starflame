//// Generated CRUD integration checks against local Miniflare D1.

import blog/db
import gleam/dynamic.{type Dynamic}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option
import gleam/string
import gleam/time/timestamp
import starflame/d1
import starflame/server
import starflame_db/runtime

pub type Check {
  Check(name: String, pass: Bool, detail: String)
}

pub fn main(env: Dynamic, execution: Dynamic) -> Promise(List(Check)) {
  let context = server.new_context(env, execution)
  let database = d1.database(context, "DB")
  use defaults <- promise.await(defaulted_user(database))
  use given <- promise.await(given_user(database))
  use post <- promise.await(post_round_trip(database))
  use reads <- promise.await(reads(database))
  use constraints <- promise.await(constraints(database))
  use deletion <- promise.await(deletion(database))
  use cascades <- promise.await(cascades(database))
  promise.resolve(
    list.flatten([defaults, given, post, reads, constraints, deletion, cascades]),
  )
}

fn defaulted_user(database: d1.Database) -> Promise(List(Check)) {
  let before = timestamp.system_time()
  let new =
    db.NewUser(
      email: "default@example.com",
      display_name: "Defaulted",
      admin: runtime.UseDefault,
      created_at: runtime.UseDefault,
      bio: option.None,
    )
  use inserted <- promise.await(db.insert_user(database, new))
  let after = timestamp.system_time()
  promise.resolve(case inserted {
    Ok(user) -> {
      let #(created, _) =
        timestamp.to_unix_seconds_and_nanoseconds(user.created_at)
      let #(earliest, _) = timestamp.to_unix_seconds_and_nanoseconds(before)
      let #(latest, _) = timestamp.to_unix_seconds_and_nanoseconds(after)
      [
        expect("UseDefault applies Bool default", user.admin, False),
        expect("nullable None inserts SQL NULL", user.bio, option.None),
        expect(
          "default_now timestamp is close to now",
          created >= earliest - 1 && created <= latest + 1,
          True,
        ),
      ]
    }
    Error(error) -> [failed("UseDefault insert", d1.describe(error))]
  })
}

fn given_user(database: d1.Database) -> Promise(List(Check)) {
  let created = timestamp.from_unix_seconds(1_725_000_123)
  let new =
    db.NewUser(
      email: "given@example.com",
      display_name: "Given",
      admin: runtime.Given(True),
      created_at: runtime.Given(created),
      bio: option.None,
    )
  use inserted <- promise.await(db.insert_user(database, new))
  promise.resolve(case inserted {
    Ok(user) -> [
      expect("Given Bool round trip", user.admin, True),
      expect(
        "Given Timestamp round trip to the second",
        user.created_at,
        created,
      ),
      expect("nullable text is None", user.bio, option.None),
    ]
    Error(error) -> [failed("Given insert", d1.describe(error))]
  })
}

fn post_round_trip(database: d1.Database) -> Promise(List(Check)) {
  let new =
    db.NewPost(
      user_id: 10,
      title: "Typed D1",
      slug: runtime.Given("typed-d1"),
      body: runtime.Given(option.None),
      type_: runtime.UseDefault,
      rating: option.Some(4.25),
    )
  use inserted <- promise.await(db.insert_post(database, new))
  case inserted {
    Error(error) -> promise.resolve([failed("Post insert", d1.describe(error))])
    Ok(post) -> {
      use fetched <- promise.await(db.get_post(database, post.id))
      promise.resolve([
        expect("reserved type column maps to type_", post.type_, "article"),
        expect("nullable body decodes None", post.body, option.None),
        expect("Float round trip", post.rating, option.Some(4.25)),
        expect("get returns inserted Post", fetched, Ok(option.Some(post))),
      ])
    }
  }
}

fn reads(database: d1.Database) -> Promise(List(Check)) {
  use existing <- promise.await(db.get_user(database, 10))
  use missing <- promise.await(db.get_user(database, 999_999))
  promise.resolve([
    expect(
      "get existing seeded user",
      existing,
      Ok(
        option.Some(db.User(
          id: 10,
          email: "ada@example.com",
          display_name: "Ada",
          admin: True,
          created_at: timestamp.from_unix_seconds(1_725_000_000),
          bio: option.Some("seed bio"),
        )),
      ),
    ),
    expect("get missing user", missing, Ok(option.None)),
  ])
}

fn constraints(database: d1.Database) -> Promise(List(Check)) {
  let duplicate = user("ada@example.com", "Duplicate")
  use unique <- promise.await(db.insert_user(database, duplicate))
  let empty_name = user("empty@example.com", "")
  use named_check <- promise.await(db.insert_user(database, empty_name))
  let foreign =
    db.NewPost(
      user_id: 999_999,
      title: "Orphan",
      slug: runtime.UseDefault,
      body: runtime.UseDefault,
      type_: runtime.UseDefault,
      rating: option.None,
    )
  use foreign_key <- promise.await(db.insert_post(database, foreign))
  promise.resolve([
    expect(
      "UNIQUE violation becomes typed D1 error",
      constraint(unique),
      option.Some(d1.Unique(["users.email"])),
    ),
    expect(
      "named CHECK violation becomes typed D1 error",
      constraint(named_check),
      option.Some(d1.Check("users_display_name_nonempty")),
    ),
    expect(
      "foreign key violation becomes typed D1 error",
      constraint(foreign_key),
      option.Some(d1.ForeignKey),
    ),
  ])
}

fn deletion(database: d1.Database) -> Promise(List(Check)) {
  use inserted <- promise.await(db.insert_user(
    database,
    user("delete@example.com", "Delete me"),
  ))
  case inserted {
    Error(error) ->
      promise.resolve([failed("Delete setup", d1.describe(error))])
    Ok(user) -> {
      use first <- promise.await(db.delete_user(database, user.id))
      use second <- promise.await(db.delete_user(database, user.id))
      promise.resolve([
        expect("delete returns True when a row is deleted", first, Ok(True)),
        expect("delete returns False for a missing row", second, Ok(False)),
      ])
    }
  }
}

fn cascades(database: d1.Database) -> Promise(List(Check)) {
  use doomed_result <- promise.await(db.insert_user(
    database,
    user("doomed@example.com", "Doomed"),
  ))
  let assert Ok(doomed) = doomed_result
  use owner_result <- promise.await(db.insert_user(
    database,
    user("owner@example.com", "Owner"),
  ))
  let assert Ok(owner) = owner_result
  use doomed_post_result <- promise.await(db.insert_post(
    database,
    post(doomed.id, "Doomed post"),
  ))
  let assert Ok(doomed_post) = doomed_post_result
  use owner_post_result <- promise.await(db.insert_post(
    database,
    post(owner.id, "Owner post"),
  ))
  let assert Ok(owner_post) = owner_post_result
  use doomed_comment_result <- promise.await(db.insert_comment(
    database,
    comment(doomed_post.id, option.Some(owner.id), "Removed with post"),
  ))
  let assert Ok(doomed_comment) = doomed_comment_result
  use owner_comment_result <- promise.await(db.insert_comment(
    database,
    comment(owner_post.id, option.Some(doomed.id), "Editor removed"),
  ))
  let assert Ok(owner_comment) = owner_comment_result
  use deleted <- promise.await(db.delete_user(database, doomed.id))
  use missing_post <- promise.await(db.get_post(database, doomed_post.id))
  use missing_comment <- promise.await(db.get_comment(
    database,
    doomed_comment.id,
  ))
  use surviving_post <- promise.await(db.get_post(database, owner_post.id))
  use surviving_comment <- promise.await(db.get_comment(
    database,
    owner_comment.id,
  ))
  promise.resolve([
    expect("delete doomed user", deleted, Ok(True)),
    expect(
      "UseDefault on nullable column applies its default",
      doomed_post.body,
      option.Some(""),
    ),
    expect("user deletion cascades to posts", missing_post, Ok(option.None)),
    expect(
      "post deletion cascades to comments",
      missing_comment,
      Ok(option.None),
    ),
    expect("other user's post survives", has_row(surviving_post), True),
    expect(
      "SET NULL clears deleted editor on another user's comment",
      surviving_comment |> editor_id,
      option.Some(option.None),
    ),
  ])
}

fn user(email: String, display_name: String) -> db.NewUser {
  db.NewUser(
    email:,
    display_name:,
    admin: runtime.UseDefault,
    created_at: runtime.UseDefault,
    bio: option.None,
  )
}

fn post(user_id: Int, title: String) -> db.NewPost {
  db.NewPost(
    user_id:,
    title:,
    slug: runtime.UseDefault,
    body: runtime.UseDefault,
    type_: runtime.UseDefault,
    rating: option.None,
  )
}

fn comment(
  post_id: Int,
  editor_id: option.Option(Int),
  body: String,
) -> db.NewComment {
  db.NewComment(post_id:, editor_id:, body:)
}

fn editor_id(
  result: Result(option.Option(db.Comment), d1.Error),
) -> option.Option(option.Option(Int)) {
  case result {
    Ok(option.Some(comment)) -> option.Some(comment.editor_id)
    _ -> option.None
  }
}

fn has_row(result: Result(option.Option(a), d1.Error)) -> Bool {
  case result {
    Ok(option.Some(_)) -> True
    _ -> False
  }
}

fn constraint(result: Result(a, d1.Error)) -> option.Option(d1.Constraint) {
  case result {
    Error(d1.ConstraintError(constraint:, ..)) -> option.Some(constraint)
    _ -> option.None
  }
}

fn expect(name: String, actual: a, expected: a) -> Check {
  let pass = actual == expected
  Check(name:, pass:, detail: case pass {
    True -> ""
    False ->
      "expected "
      <> string.inspect(expected)
      <> ", got "
      <> string.inspect(actual)
  })
}

fn failed(name: String, detail: String) -> Check {
  Check(name:, pass: False, detail:)
}
