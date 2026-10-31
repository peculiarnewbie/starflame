//// Board storage and validation. Called by the typed capabilities in canvas/api.

import canvas/codecs
import canvas/shared.{
  type CanvasError, type Point, type Stroke, type StrokeDraft, BadColor,
  BadWidth, EmptyStroke, Stroke, TooManyPoints, max_points, max_width, palette,
}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import starflame/do_sql as sql
import starflame/plain
import starflame/server

const schema =
  "CREATE TABLE IF NOT EXISTS strokes (
    id TEXT PRIMARY KEY,
    room TEXT NOT NULL,
    author TEXT NOT NULL,
    points TEXT NOT NULL,
    color TEXT NOT NULL,
    width REAL NOT NULL,
    created_at INTEGER NOT NULL
  )"

pub fn add_stroke(
  context: server.Context,
  draft draft: StrokeDraft,
) -> Result(Stroke, CanvasError) {
  let #(author, room) = identity(context)
  case validate(draft) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      let stroke =
        Stroke(
          id: random_id(),
          author: author,
          points: draft.points,
          color: draft.color,
          width: draft.width,
          created_at: now_ms(),
        )
      use db <- with_db(context)
      use _ <- or_reject(
        sql.run(
          db,
          "INSERT INTO strokes (id, room, author, points, color, width, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            sql.string(stroke.id),
            sql.string(room),
            sql.string(stroke.author),
            sql.string(points_json(stroke.points)),
            sql.string(stroke.color),
            sql.float(stroke.width),
            sql.int(stroke.created_at),
          ],
        ),
      )
      Ok(stroke)
    }
  }
}

pub fn snapshot(context: server.Context) -> List(Stroke) {
  let #(_, room) = identity(context)
  use db <- with_db(context)
  use rows <- or_reject(sql.all(
    db,
    "SELECT id, author, points, color, width, created_at
       FROM strokes WHERE room = ? ORDER BY created_at ASC LIMIT 5000",
    [sql.string(room)],
    stroke_row_decoder(),
  ))
  rows
}

pub fn clear(context: server.Context) -> Result(Nil, CanvasError) {
  let #(_, room) = identity(context)
  use db <- with_db(context)
  use _ <- or_reject(
    sql.run(db, "DELETE FROM strokes WHERE room = ?", [
      sql.string(room),
    ]),
  )
  Ok(Nil)
}

// VALIDATION ------------------------------------------------------------------

fn validate(draft: StrokeDraft) -> Result(Nil, CanvasError) {
  case draft.points {
    [] -> Error(EmptyStroke)
    points ->
      case list.length(points) > max_points {
        True -> Error(TooManyPoints(max_points))
        False ->
          case list.contains(palette, draft.color) {
            False -> Error(BadColor(draft.color))
            True ->
              case draft.width >. 0.0 && draft.width <=. max_width {
                True -> Ok(Nil)
                False -> Error(BadWidth)
              }
          }
      }
  }
}

fn identity(context: server.Context) -> #(String, String) {
  case decode.run(server.auth(context), identity_decoder()) {
    Ok(identity) -> identity
    Error(_) -> panic as "The Worker must pass {player, room} as auth."
  }
}

fn identity_decoder() -> decode.Decoder(#(String, String)) {
  use player <- decode.field("player", decode.string)
  use room <- decode.field("room", decode.string)
  decode.success(#(player, room))
}

// STORAGE ---------------------------------------------------------------------

fn points_json(points: List(Point)) -> String {
  stringify(plain.to_dynamic(plain.list(points, codecs.point_to_plain)))
}

fn points_decoder() -> decode.Decoder(List(Point)) {
  decode.new_primitive_decoder("List(Point)", fn(value: Dynamic) {
    case decode.run(parse(value), decode.list(codecs.point_decoder())) {
      Ok(points) -> Ok(points)
      Error(_) -> Error([])
    }
  })
}

fn stroke_row_decoder() -> decode.Decoder(Stroke) {
  use id <- decode.field("id", decode.string)
  use author <- decode.field("author", decode.string)
  use points <- decode.field("points", points_decoder())
  use color <- decode.field("color", decode.string)
  use width <- decode.field("width", decode.float)
  use created_at <- decode.field("created_at", decode.int)
  decode.success(Stroke(id:, author:, points:, color:, width:, created_at:))
}

fn with_db(context: server.Context, next: fn(sql.Database) -> a) -> a {
  let db = sql.database(context)
  case sql.setup(db, [schema]) {
    Ok(Nil) -> next(db)
    Error(error) -> panic as sql.describe(error)
  }
}

fn or_reject(query: Result(a, sql.Error), next: fn(a) -> b) -> b {
  case query {
    Ok(value) -> next(value)
    Error(error) -> panic as sql.describe(error)
  }
}

// FFI -------------------------------------------------------------------------

@external(javascript, "./id_ffi.mjs", "random_id")
fn random_id() -> String

@external(javascript, "./id_ffi.mjs", "now_ms")
fn now_ms() -> Int

@external(javascript, "./storage_ffi.mjs", "stringify")
fn stringify(value: Dynamic) -> String

@external(javascript, "./storage_ffi.mjs", "parse")
fn parse(text: Dynamic) -> Dynamic
