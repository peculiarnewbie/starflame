//// GENERATED (hand-written for now): codecs for shared data types.

import gleam/dynamic/decode.{type Decoder}
import starflame/plain.{type Plain}
import todos/shared.{
  type Change, type Todo, type TodoError, CompletedCleared, EmptyTitle, NotFound,
  Removed, Snapshot, TitleTooLong, Todo, Upsert,
}

pub fn change_decoder() -> Decoder(Change) {
  use tag <- decode.field("$", decode.string)
  case tag {
    "Snapshot" -> {
      use todos <- decode.field("todos", decode.list(todo_decoder()))
      decode.success(Snapshot(todos))
    }
    "Upsert" -> {
      use item <- decode.field("todo", todo_decoder())
      decode.success(Upsert(item))
    }
    "Removed" -> {
      use id <- decode.field("id", decode.int)
      decode.success(Removed(id))
    }
    "CompletedCleared" -> decode.success(CompletedCleared)
    _ -> decode.failure(CompletedCleared, "Change")
  }
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
