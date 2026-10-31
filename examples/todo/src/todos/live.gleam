//// Typed changes shared by RPC subscribers and the Lustre server component.

import gleam/dynamic.{type Dynamic}
import starflame/server
import starflame/topic
import todos/shared.{type Change}

pub fn publish(context: server.Context, change: Change) -> Nil {
  topic.publish(events(context), change)
}

pub fn subscribe(context: server.Context, callback: fn(Change) -> Nil) -> Nil {
  let subscription =
    subscription(context, fn() {
      let subscription = topic.subscription(events(context))
      let _ = server.with_dispose(context, fn() { topic.dispose(subscription) })
      subscription
    })
  topic.listen(subscription, callback)
}

pub fn listen(
  context: server.Context,
  callback: fn(Change) -> Nil,
) -> fn() -> Nil {
  let subscription = topic.subscription(events(context))
  topic.listen(subscription, callback)
  fn() { topic.dispose(subscription) }
}

fn events(context: server.Context) -> topic.Topic(Change) {
  room_events(server.execution(context), topic.new)
}

@external(javascript, "./live_ffi.mjs", "roomEvents")
fn room_events(
  execution: Dynamic,
  create: fn() -> topic.Topic(Change),
) -> topic.Topic(Change)

@external(javascript, "./live_ffi.mjs", "subscription")
fn subscription(
  context: server.Context,
  create: fn() -> topic.Subscription(Change),
) -> topic.Subscription(Change)
