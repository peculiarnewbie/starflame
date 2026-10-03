//// Types used by both the client and the server.

import gleam/dict.{type Dict}
import gleam/option.{type Option}

pub type User {
  User(
    id: Int,
    name: String,
    role: Role,
    tags: List(String),
    score: Float,
    manager: Option(Int),
  )
}

pub type Role {
  Admin
  Member(team: String)
  Guest
}

pub type ApiError {
  NotFound(id: Int)
  Unauthorized
  Invalid(reason: String)
}

/// Exercises every kind of value the codecs have to handle.
pub type Everything {
  Everything(
    pair: #(Int, String),
    scores: Dict(String, Float),
    maybe: Option(Int),
    nested: List(List(Int)),
    unit: Nil,
    flag: Bool,
    big: Int,
    whole_float: Float,
    point: Point,
    roles: List(Role),
    outcome: Result(Int, String),
  )
}

pub type Point {
  Point(Int, Int)
}
