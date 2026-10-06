//// The sign-in configuration that test/run.mjs drives through a Worker.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import starflame/plain
import starflame_openauth.{type Auth, type Identity, Email, Google}

pub type User {
  User(id: String, email: String)
}

pub fn auth() -> Auth(User) {
  starflame_openauth.new(
    client_id: "test",
    title: "Test",
    storage: "AUTH",
    success:,
    to_plain:,
    decoder: decoder(),
  )
  |> starflame_openauth.email_code(send:, database: "DB")
  |> starflame_openauth.token_lifetimes(access: 2, refresh: 3600)
}

fn success(_env: Dynamic, identity: Identity) -> Promise(Result(User, String)) {
  promise.resolve(case identity {
    Email("blocked@example.com") -> Error("This address isn't allowed.")
    Email(address) -> Ok(User("email:" <> address, address))
    Google(subject:, email:, ..) -> Ok(User("google:" <> subject, email))
  })
}

fn to_plain(user: User) -> plain.Plain {
  plain.object([
    #("id", plain.string(user.id)),
    #("email", plain.string(user.email)),
  ])
}

fn decoder() -> decode.Decoder(User) {
  use id <- decode.field("id", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(User(id:, email:))
}

/// Stores the code where the test can read it, instead of emailing it.
fn send(
  env: Dynamic,
  email: String,
  code: String,
) -> Promise(Result(Nil, String)) {
  case email {
    "unreachable@example.com" -> promise.resolve(Error("mailbox unavailable"))
    _ -> store_code(env, email, code)
  }
}

@external(javascript, "./openauth_test_app_ffi.mjs", "storeCode")
fn store_code(
  env: Dynamic,
  email: String,
  code: String,
) -> Promise(Result(Nil, String))
