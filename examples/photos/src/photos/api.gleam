//// Every public function here is an RPC method.
////
//// Bodies arrive as BitArray, which the wire layer sends as Cap'n Web bytes.
//// R2 holds the bytes; D1 holds the metadata.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import photos/shared.{
  type Photo, Photo, type PhotoError, EmptyFile, EmptyName, NameTooLong, NotFound,
  NotYours, StorageFailed, TooLarge, UnsupportedType, allowed_types,
  max_bytes, max_name_length,
}
import starflame/d1
import starflame/r2
import starflame/server

const schema =
  "CREATE TABLE IF NOT EXISTS photos (
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    content_type TEXT NOT NULL,
    size INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  )"

/// The caller's public id, so the UI can mark their uploads.
pub fn me(context: server.Context) -> String {
  owner_of(context)
}

pub fn upload(
  context: server.Context,
  name name: String,
  content_type content_type: String,
  body body: BitArray,
) -> Promise(Result(Photo, PhotoError)) {
  let owner = owner_of(context)
  case validate(name, content_type, body) {
    Error(error) -> promise.resolve(Error(error))
    Ok(#(name, content_type, size)) -> {
      let id = random_id()
      let bucket = r2.bucket(context, "BUCKET")
      use stored <- promise.await(r2.put(bucket, key(id), body, content_type))
      case stored {
        Error(_) -> promise.resolve(Error(StorageFailed))
        Ok(Nil) -> {
          let created_at = now_ms()
          use db <- with_db(context)
          use _ <-
            or_reject(d1.run(
              db,
              "INSERT INTO photos (id, owner, name, content_type, size, created_at)
               VALUES (?, ?, ?, ?, ?, ?)",
              [
                d1.string(id),
                d1.string(owner),
                d1.string(name),
                d1.string(content_type),
                d1.int(size),
                d1.int(created_at),
              ],
            ))
          promise.resolve(
            Ok(Photo(
              id:,
              owner:,
              name:,
              content_type:,
              size:,
              created_at:,
            )),
          )
        }
      }
    }
  }
}

pub fn list_photos(context: server.Context) -> Promise(List(Photo)) {
  use db <- with_db(context)
  use photos <-
    or_reject(d1.all(
      db,
      "SELECT id, owner, name, content_type, size, created_at
       FROM photos ORDER BY created_at DESC",
      [],
      photo_decoder(),
    ))
  promise.resolve(photos)
}

/// Reads the object back through RPC, which is also how the integration test
/// proves the byte round trip.
pub fn bytes(
  context: server.Context,
  id id: String,
) -> Promise(Result(BitArray, PhotoError)) {
  use db <- with_db(context)
  use exists <-
    or_reject(d1.all(
      db,
      "SELECT id FROM photos WHERE id = ?",
      [d1.string(id)],
      id_decoder(),
    ))
  case exists {
    [] -> promise.resolve(Error(NotFound(id)))
    _ -> {
      let bucket = r2.bucket(context, "BUCKET")
      use object <- promise.await(r2.get(bucket, key(id)))
      case object {
        Ok(Some(r2.Object(body:, ..))) -> promise.resolve(Ok(body))
        Ok(None) -> promise.resolve(Error(NotFound(id)))
        Error(_) -> promise.resolve(Error(StorageFailed))
      }
    }
  }
}

pub fn delete(
  context: server.Context,
  id id: String,
) -> Promise(Result(Nil, PhotoError)) {
  let owner = owner_of(context)
  use db <- with_db(context)
  use found <-
    or_reject(d1.all(
      db,
      "SELECT owner FROM photos WHERE id = ?",
      [d1.string(id)],
      owner_decoder(),
    ))
  case found {
    [] -> promise.resolve(Error(NotFound(id)))
    [photo_owner, ..] ->
      case photo_owner == owner {
        False -> promise.resolve(Error(NotYours(id)))
        True -> {
          let bucket = r2.bucket(context, "BUCKET")
          use _ <- promise.await(r2.delete(bucket, key(id)))
          use _ <-
            or_reject(d1.run(db, "DELETE FROM photos WHERE id = ?", [
              d1.string(id),
            ]))
          promise.resolve(Ok(Nil))
        }
      }
  }
}

// VALIDATION ------------------------------------------------------------------

fn validate(
  name: String,
  content_type: String,
  body: BitArray,
) -> Result(#(String, String, Int), PhotoError) {
  let name = string.trim(name)
  let size = bit_array.byte_size(body)
  case string.length(name) {
    0 -> Error(EmptyName)
    length if length > max_name_length -> Error(NameTooLong(max_name_length))
    _ ->
      case list.contains(allowed_types, content_type) {
        False -> Error(UnsupportedType(content_type))
        True ->
          case size {
            0 -> Error(EmptyFile)
            size if size > max_bytes -> Error(TooLarge(max_bytes))
            _ -> Ok(#(name, content_type, size))
          }
      }
  }
}

fn key(id: String) -> String {
  "photos/" <> id
}

fn owner_of(context: server.Context) -> String {
  case decode.run(server.auth(context), decode.string) {
    Ok(owner) -> owner
    Error(_) -> panic as "The Worker must pass the session's player id as auth."
  }
}

// DATABASE --------------------------------------------------------------------

fn with_db(
  context: server.Context,
  next: fn(d1.Database) -> Promise(a),
) -> Promise(a) {
  let db = d1.database(context, "DB")
  use setup <- promise.await(d1.setup(db, [schema]))
  case setup {
    Ok(Nil) -> next(db)
    Error(error) -> panic as d1.describe(error)
  }
}

fn or_reject(
  query: Promise(Result(a, d1.Error)),
  next: fn(a) -> Promise(b),
) -> Promise(b) {
  use result <- promise.await(query)
  case result {
    Ok(value) -> next(value)
    Error(error) -> panic as d1.describe(error)
  }
}

fn photo_decoder() -> decode.Decoder(Photo) {
  use id <- decode.field("id", decode.string)
  use owner <- decode.field("owner", decode.string)
  use name <- decode.field("name", decode.string)
  use content_type <- decode.field("content_type", decode.string)
  use size <- decode.field("size", d1.int_decoder())
  use created_at <- decode.field("created_at", d1.int_decoder())
  decode.success(Photo(id:, owner:, name:, content_type:, size:, created_at:))
}

fn id_decoder() -> decode.Decoder(String) {
  use id <- decode.field("id", decode.string)
  decode.success(id)
}

fn owner_decoder() -> decode.Decoder(String) {
  use owner <- decode.field("owner", decode.string)
  decode.success(owner)
}

// FFI -------------------------------------------------------------------------

@external(javascript, "./id_ffi.mjs", "random_id")
fn random_id() -> String

@external(javascript, "./id_ffi.mjs", "now_ms")
fn now_ms() -> Int
