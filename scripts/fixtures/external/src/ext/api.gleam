import ext/shared.{type Note}
import starflame/server
import starflame/topic

pub type Board {
  Board(
    clear: fn() -> Result(Nil, String),
    subscribe: fn(fn(Note) -> Nil) -> Nil,
    publish: fn(Note) -> Nil,
  )
}

pub fn enter(_context: server.Context) -> Board {
  let events = topic.new()
  let subscription = topic.subscription(events)
  Board(
    clear: fn() { Ok(Nil) },
    subscribe: fn(callback) { topic.listen(subscription, callback) },
    publish: fn(note) { topic.publish(events, note) },
  )
  |> server.with_dispose(fn() { topic.dispose(subscription) })
}
