//// Types used by both the client and the server.

pub type Todo {
  Todo(id: Int, title: String, done: Bool)
}

pub type TodoError {
  EmptyTitle
  TitleTooLong(max: Int)
  NotFound(id: Int)
}

pub const max_title_length = 200
