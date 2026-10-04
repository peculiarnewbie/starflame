//// Hand-written codecs, as Starflame's RPC generator would write them.

import bench/db.{type Todo, Todo}
import gleam/dynamic/decode.{type Decoder}
import starflame/plain.{type Plain}

pub fn todo_to_plain(value: Todo) -> Plain {
  plain.object([
    #("id", plain.int(value.id)),
    #("title", plain.string(value.title)),
    #("done", plain.bool(value.done)),
  ])
}

pub fn todo_decoder() -> Decoder(Todo) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use done <- decode.field("done", decode.bool)
  decode.success(Todo(id:, title:, done:))
}
