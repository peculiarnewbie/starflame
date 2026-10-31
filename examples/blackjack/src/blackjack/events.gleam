//// Player-specific events stay typed until the generated callback encodes them.

import blackjack/shared.{type View}
import gleam/dynamic.{type Dynamic}
import gleam/list
import starflame/server
import starflame/topic

pub fn publish(context: server.Context, views: List(#(String, View))) -> Nil {
  let events = events(context)
  list.each(views, topic.publish(events, _))
}

pub fn subscribe(
  context: server.Context,
  player: String,
  callback: fn(View) -> Nil,
) -> Nil {
  let subscription =
    subscription(context, fn() {
      let subscription = topic.subscription(events(context))
      let _ = server.with_dispose(context, fn() { topic.dispose(subscription) })
      subscription
    })
  topic.listen(subscription, fn(event) {
    case event.0 == player {
      True -> callback(event.1)
      False -> Nil
    }
  })
}

fn events(context: server.Context) -> topic.Topic(#(String, View)) {
  room_events(server.execution(context), topic.new)
}

@external(javascript, "./events_ffi.mjs", "roomEvents")
fn room_events(
  execution: Dynamic,
  create: fn() -> topic.Topic(#(String, View)),
) -> topic.Topic(#(String, View))

@external(javascript, "./events_ffi.mjs", "subscription")
fn subscription(
  context: server.Context,
  create: fn() -> topic.Subscription(#(String, View)),
) -> topic.Subscription(#(String, View))
