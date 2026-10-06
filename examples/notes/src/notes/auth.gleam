//// Sign-in: Google or a code by email, with the issuer in this Worker.
//// worker.ts routes to it.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option, None, Some}
import gleam/result
import notes/db
import notes/session
import notes/shared.{type Me, Me}
import starflame/d1
import starflame/server
import starflame_db/runtime
import starflame_openauth.{type Auth, type Identity, Email, Google}

pub fn auth() -> Auth(Me) {
  starflame_openauth.new(
    client_id: "notes",
    title: "Notes",
    storage: "AUTH",
    success: sign_in,
    to_plain: session.to_plain,
    decoder: session.decoder(),
  )
  |> starflame_openauth.google(client_id: "GOOGLE_CLIENT_ID")
  |> starflame_openauth.email_code(send: send_code, database: "DB")
}

/// Emails the code. In local dev, the `send_email` binding prints the
/// message instead.
fn send_code(
  env: Dynamic,
  email: String,
  code: String,
) -> Promise(Result(Nil, String)) {
  let from = text(env, "EMAIL_FROM") |> result.unwrap("")
  starflame_openauth.email_service(binding: "EMAIL", from:, name: "Notes")(
    env,
    email,
    code,
  )
}

/// Finds or creates the user for a sign-in.
fn sign_in(env: Dynamic, identity: Identity) -> Promise(Result(Me, String)) {
  let database = d1.database(server.new_context(env, dynamic.nil()), "DB")
  let found = case identity {
    Email(address) -> find_or_create(database, address, None)
    Google(subject:, email:, email_verified:, ..) -> {
      use by_subject <- promise.await(find(database, "google_subject", subject))
      case by_subject, email_verified {
        Ok(Some(user)), _ -> promise.resolve(Ok(user))
        Ok(None), True -> find_or_create(database, email, Some(subject))
        Ok(None), False ->
          promise.resolve(Error(
            "Verify your Google account's email address, then try again.",
          ))
        Error(error), _ -> promise.resolve(Error(log(error)))
      }
    }
  }
  use user <- promise.map(found)
  result.map(user, fn(user) { Me(id: user.id, email: user.email) })
}

/// The user with `email`, creating it if there's none. A Google sign-in
/// links its subject to the account with the same verified address.
fn find_or_create(
  database: d1.Database,
  email: String,
  google_subject: Option(String),
) -> Promise(Result(db.User, String)) {
  use existing <- promise.await(find(database, "email", email))
  case existing {
    Error(error) -> promise.resolve(Error(log(error)))
    Ok(Some(user)) ->
      case google_subject {
        Some(subject) if user.google_subject == None ->
          link_google(database, user, subject)
        _ -> promise.resolve(Ok(user))
      }
    Ok(None) -> {
      let new =
        db.NewUser(email:, google_subject:, created_at: runtime.UseDefault)
      use inserted <- promise.await(db.insert_user(database, new))
      case inserted {
        Ok(user) -> promise.resolve(Ok(user))
        // Two first sign-ins at once: the other one created it.
        Error(_) -> {
          use again <- promise.map(find(database, "email", email))
          case again {
            Ok(Some(user)) -> Ok(user)
            Ok(None) -> Error("Couldn't create your account. Try again.")
            Error(error) -> Error(log(error))
          }
        }
      }
    }
  }
}

fn link_google(
  database: d1.Database,
  user: db.User,
  subject: String,
) -> Promise(Result(db.User, String)) {
  use linked <- promise.map(
    d1.run(database, "UPDATE users SET google_subject = ? WHERE id = ?", [
      d1.string(subject),
      d1.int(user.id),
    ]),
  )
  case linked {
    Ok(_) -> Ok(db.User(..user, google_subject: Some(subject)))
    Error(error) -> Error(log(error))
  }
}

fn find(
  database: d1.Database,
  column: String,
  value: String,
) -> Promise(Result(Option(db.User), d1.Error)) {
  let sql =
    "SELECT " <> db.user_columns <> " FROM users WHERE " <> column <> " = ?"
  use rows <- promise.map(d1.all(
    database,
    sql,
    [d1.string(value)],
    db.user_decoder(),
  ))
  use rows <- result.map(rows)
  case rows {
    [user, ..] -> Some(user)
    [] -> None
  }
}

fn log(error: d1.Error) -> String {
  io.println_error("Sign-in failed: " <> d1.describe(error))
  "Something went wrong signing in. Try again."
}

fn text(env: Dynamic, name: String) -> Result(String, Nil) {
  decode.run(env, decode.at([name], decode.string)) |> result.replace_error(Nil)
}
