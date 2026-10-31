//// The canvas RPC contract and its implementation. Both capability clients
//// and server dispatchers are generated from these checked function types.

import canvas/shared.{
  type BoardEvent, type CanvasError, type Stroke, type StrokeDraft, Cleared,
  Presence, StrokeAdded,
}
import canvas/storage
import gleam/dynamic.{type Dynamic}
import starflame/server
import starflame/topic

pub type Board {
  Board(
    snapshot: fn() -> List(Stroke),
    add: fn(StrokeDraft) -> Result(Stroke, CanvasError),
    clear: fn() -> Result(Nil, CanvasError),
    subscribe: fn(fn(BoardEvent) -> Nil) -> Nil,
  )
}

pub type BoardView {
  BoardView(
    snapshot: fn() -> List(Stroke),
    subscribe: fn(fn(BoardEvent) -> Nil) -> Nil,
  )
}

/// Enters as an editor. Each capability owns its subscription.
pub fn enter(context: server.Context) -> Board {
  let events = events(context)
  let subscription = topic.subscription(events)
  Board(
    snapshot: fn() { storage.snapshot(context) },
    add: fn(draft) {
      case storage.add_stroke(context, draft:) {
        Ok(stroke) -> {
          topic.publish(events, StrokeAdded(stroke))
          Ok(stroke)
        }
        Error(error) -> Error(error)
      }
    },
    clear: fn() {
      case storage.clear(context) {
        Ok(Nil) -> {
          topic.publish(events, Cleared)
          Ok(Nil)
        }
        Error(error) -> Error(error)
      }
    },
    subscribe: fn(callback) { topic.listen(subscription, callback) },
  )
  |> server.with_dispose(fn() { topic.dispose(subscription) })
}

/// Enters as a viewer. There are no editing methods on this capability.
pub fn watch(context: server.Context) -> BoardView {
  let subscription = topic.subscription(events(context))
  BoardView(
    snapshot: fn() { storage.snapshot(context) },
    subscribe: fn(callback) { topic.listen(subscription, callback) },
  )
  |> server.with_dispose(fn() { topic.dispose(subscription) })
}

fn events(context: server.Context) -> topic.Topic(BoardEvent) {
  room_events(server.execution(context), fn() {
    let events = topic.new()
    topic.on_count_change(events, fn(count) {
      topic.publish(events, Presence(count))
    })
    events
  })
}

// Only caches a typed topic per Durable Object state; it neither declares
// RPC methods nor encodes wire values.
@external(javascript, "./events_ffi.mjs", "roomEvents")
fn room_events(
  execution: Dynamic,
  create: fn() -> topic.Topic(BoardEvent),
) -> topic.Topic(BoardEvent)
