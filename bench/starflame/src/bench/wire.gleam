//// Hand-written codecs, as Starflame's RPC generator would write them.

import bench/db.{type Todo, Todo}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import starflame/fast_decode
import starflame/plain.{type Plain}

pub fn todo_to_plain(value: Todo) -> Plain {
  plain.object([
    #("id", plain.int(value.id)),
    #("title", plain.string(value.title)),
    #("done", plain.bool(value.done)),
  ])
}

pub fn todo_decoder() -> Decoder(Todo) {
  fast_decode.decoder(todo_fields, todo_from_plain, todo_fallback())
}

const todo_fields = [
  fast_decode.Field("id", fast_decode.IntKind, False),
  fast_decode.Field("title", fast_decode.StringKind, False),
  fast_decode.Field("done", fast_decode.BoolKind, False),
]

fn todo_from_plain(value: Dynamic) -> Todo {
  Todo(
    id: fast_decode.get(value, "id"),
    title: fast_decode.get(value, "title"),
    done: fast_decode.get(value, "done"),
  )
}

fn todo_fallback() -> Decoder(Todo) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use done <- decode.field("done", decode.bool)
  decode.success(Todo(id:, title:, done:))
}
