//// Every public function here is an RPC method. Types with function fields
//// (like `Session`) are capabilities: they're passed by reference.

import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import spike/shared.{
  type ApiError, type Everything, type Role, type User, Admin, Guest, Invalid,
  Member, NotFound, User,
}
import starflame/server.{type Context}

pub type Session {
  Session(
    me: fn() -> Promise(User),
    rename: fn(String) -> Promise(Result(User, ApiError)),
  )
}

const users = [
  User(1, "ada", Admin, ["founder"], 9.5, None),
  User(2, "grace", Member("compilers"), ["navy", "cobol"], 8.0, Some(1)),
  User(3, "alan", Guest, [], 7.25, Some(1)),
]

pub fn get_user(
  _context: Context,
  id id: Int,
) -> Promise(Result(User, ApiError)) {
  promise.resolve(find(id))
}

pub fn list_users(
  _context: Context,
  role role: Option(Role),
) -> Promise(List(User)) {
  case role {
    None -> users
    Some(role) -> list.filter(users, fn(user) { user.role == role })
  }
  |> promise.resolve
}

pub fn login(
  _context: Context,
  name name: String,
) -> Promise(Result(Session, ApiError)) {
  case list.find(users, fn(user) { user.name == name }) {
    Ok(user) -> Ok(session(user))
    Error(Nil) -> Error(shared.Unauthorized)
  }
  |> promise.resolve
}

fn session(user: User) -> Session {
  Session(me: fn() { promise.resolve(user) }, rename: fn(name) {
    case name {
      "" -> promise.resolve(Error(Invalid("name can't be empty")))
      _ -> promise.resolve(Ok(User(..user, name:)))
    }
  })
}

/// Counts to `to`, reporting each step through a callback.
pub fn count_slowly(
  _context: Context,
  to to: Int,
  on_progress on_progress: fn(Int) -> Nil,
) -> Promise(Int) {
  count_from(1, to, on_progress)
}

fn count_from(n: Int, to: Int, on_progress: fn(Int) -> Nil) -> Promise(Int) {
  case n > to {
    True -> promise.resolve(to)
    False -> {
      use _ <- promise.await(promise.wait(20))
      on_progress(n)
      count_from(n + 1, to, on_progress)
    }
  }
}

pub fn echo_everything(
  _context: Context,
  everything everything: Everything,
) -> Promise(Everything) {
  promise.resolve(everything)
}

pub fn crash(_context: Context, reason reason: String) -> Promise(Int) {
  panic as reason
}

fn find(id: Int) -> Result(User, ApiError) {
  case list.find(users, fn(user) { user.id == id }) {
    Ok(user) -> Ok(user)
    Error(Nil) -> Error(NotFound(id))
  }
}
