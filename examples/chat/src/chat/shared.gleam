//// Types shared by the API, the socket protocol and the browser.

pub const max_body = 500
pub const max_name = 24

pub type Message {
  Message(
    id: String,
    room: String,
    author: String,
    name: String,
    body: String,
    created_at: Int,
  )
}

/// What the hibernating socket carries. It is encoded with the generated
/// codecs, so the push channel is typed even though it is not Cap'n Web.
pub type RoomEvent {
  MessagePosted(message: Message)
  Presence(online: Int)
}

pub type ChatError {
  EmptyMessage
  MessageTooLong(limit: Int)
  EmptyName
  NameTooLong(limit: Int)
}
