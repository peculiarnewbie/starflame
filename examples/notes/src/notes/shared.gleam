//// Types shared by the browser and the Worker.

/// The signed-in user. It's carried in the access token, so it's only what
/// every request needs.
pub type Me {
  Me(id: Int, email: String)
}

pub type Note {
  Note(id: Int, body: String)
}

pub type NotesError {
  SignedOut
  EmptyNote
  NoteTooLong(max: Int)
  NoteNotFound
  /// Details are logged on the server, not sent.
  ServerError
}
