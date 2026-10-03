//// GENERATED (hand-written for now): codecs for shared data types.

import starflame/plain.{type Plain}
import gleam/dynamic/decode.{type Decoder}
import todos/shared.{
  type Todo, type TodoError, EmptyTitle, NotFound, TitleTooLong, Todo,
}

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

pub fn todo_error_to_plain(value: TodoError) -> Plain {
  case value {
    EmptyTitle -> plain.tagged("EmptyTitle", [])
    TitleTooLong(max:) ->
      plain.tagged("TitleTooLong", [#("max", plain.int(max))])
    NotFound(id:) -> plain.tagged("NotFound", [#("id", plain.int(id))])
  }
}

pub fn todo_error_decoder() -> Decoder(TodoError) {
  use tag <- decode.field("$", decode.string)
  case tag {
    "EmptyTitle" -> decode.success(EmptyTitle)
    "TitleTooLong" -> {
      use max <- decode.field("max", decode.int)
      decode.success(TitleTooLong(max:))
    }
    "NotFound" -> {
      use id <- decode.field("id", decode.int)
      decode.success(NotFound(id:))
    }
    _ -> decode.failure(EmptyTitle, "TodoError")
  }
}
