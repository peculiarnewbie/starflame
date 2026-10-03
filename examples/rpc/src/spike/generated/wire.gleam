//// GENERATED (hand-written for the spike): codecs for data types shared by
//// client and server.

import starflame/plain.{type Plain}
import gleam/dynamic/decode.{type Decoder}
import spike/shared.{
  type ApiError, type Everything, type Point, type Role, type User, Admin,
  Everything, Guest, Invalid, Member, NotFound, Point, Unauthorized, User,
}

// User ------------------------------------------------------------------------

pub fn user_to_plain(value: User) -> Plain {
  plain.object([
    #("id", plain.int(value.id)),
    #("name", plain.string(value.name)),
    #("role", role_to_plain(value.role)),
    #("tags", plain.list(value.tags, plain.string)),
    #("score", plain.float(value.score)),
    #("manager", plain.option(value.manager, plain.int)),
  ])
}

pub fn user_decoder() -> Decoder(User) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use role <- decode.field("role", role_decoder())
  use tags <- decode.field("tags", decode.list(decode.string))
  use score <- decode.field("score", decode.float)
  use manager <- decode.field("manager", decode.optional(decode.int))
  decode.success(User(id:, name:, role:, tags:, score:, manager:))
}

// Role ------------------------------------------------------------------------

pub fn role_to_plain(value: Role) -> Plain {
  case value {
    Admin -> plain.tagged("Admin", [])
    Member(team:) -> plain.tagged("Member", [#("team", plain.string(team))])
    Guest -> plain.tagged("Guest", [])
  }
}

pub fn role_decoder() -> Decoder(Role) {
  use tag <- decode.field("$", decode.string)
  case tag {
    "Admin" -> decode.success(Admin)
    "Member" -> {
      use team <- decode.field("team", decode.string)
      decode.success(Member(team:))
    }
    "Guest" -> decode.success(Guest)
    _ -> decode.failure(Admin, "Role")
  }
}

// ApiError --------------------------------------------------------------------

pub fn api_error_to_plain(value: ApiError) -> Plain {
  case value {
    NotFound(id:) -> plain.tagged("NotFound", [#("id", plain.int(id))])
    Unauthorized -> plain.tagged("Unauthorized", [])
    Invalid(reason:) ->
      plain.tagged("Invalid", [#("reason", plain.string(reason))])
  }
}

pub fn api_error_decoder() -> Decoder(ApiError) {
  use tag <- decode.field("$", decode.string)
  case tag {
    "NotFound" -> {
      use id <- decode.field("id", decode.int)
      decode.success(NotFound(id:))
    }
    "Unauthorized" -> decode.success(Unauthorized)
    "Invalid" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Invalid(reason:))
    }
    _ -> decode.failure(Unauthorized, "ApiError")
  }
}

// Point -----------------------------------------------------------------------

pub fn point_to_plain(value: Point) -> Plain {
  let Point(x, y) = value
  plain.object([#("0", plain.int(x)), #("1", plain.int(y))])
}

pub fn point_decoder() -> Decoder(Point) {
  use x <- decode.field("0", decode.int)
  use y <- decode.field("1", decode.int)
  decode.success(Point(x, y))
}

// Everything ------------------------------------------------------------------

pub fn everything_to_plain(value: Everything) -> Plain {
  plain.object([
    #(
      "pair",
      plain.array([plain.int(value.pair.0), plain.string(value.pair.1)]),
    ),
    #("scores", plain.dict(value.scores, plain.float)),
    #("maybe", plain.option(value.maybe, plain.int)),
    #("nested", plain.list(value.nested, plain.list(_, plain.int))),
    #("unit", plain.nil(value.unit)),
    #("flag", plain.bool(value.flag)),
    #("big", plain.int(value.big)),
    #("whole_float", plain.float(value.whole_float)),
    #("point", point_to_plain(value.point)),
    #("roles", plain.list(value.roles, role_to_plain)),
    #("outcome", plain.result(value.outcome, plain.int, plain.string)),
  ])
}

pub fn everything_decoder() -> Decoder(Everything) {
  use pair <- decode.field("pair", {
    use a <- decode.field(0, decode.int)
    use b <- decode.field(1, decode.string)
    decode.success(#(a, b))
  })
  use scores <- decode.field("scores", decode.dict(decode.string, decode.float))
  use maybe <- decode.field("maybe", decode.optional(decode.int))
  use nested <- decode.field("nested", decode.list(decode.list(decode.int)))
  use unit <- decode.field("unit", decode.success(Nil))
  use flag <- decode.field("flag", decode.bool)
  use big <- decode.field("big", decode.int)
  use whole_float <- decode.field("whole_float", decode.float)
  use point <- decode.field("point", point_decoder())
  use roles <- decode.field("roles", decode.list(role_decoder()))
  use outcome <- decode.field(
    "outcome",
    plain.result_decoder(decode.int, decode.string),
  )
  decode.success(Everything(
    pair:,
    scores:,
    maybe:,
    nested:,
    unit:,
    flag:,
    big:,
    whole_float:,
    point:,
    roles:,
    outcome:,
  ))
}
