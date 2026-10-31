//// Typed events shared by the capabilities in a server isolate. The generated
//// RPC callback encodes each event using its declared Gleam type.

pub type Topic(event)

pub type Subscription(event)

@external(javascript, "./topic_ffi.mjs", "create")
pub fn new() -> Topic(event)

@external(javascript, "./topic_ffi.mjs", "publish")
pub fn publish(topic: Topic(event), event: event) -> Nil

/// Called whenever the number of active subscriptions changes.
@external(javascript, "./topic_ffi.mjs", "onCountChange")
pub fn on_count_change(topic: Topic(event), callback: fn(Int) -> Nil) -> Nil

/// An initially inactive subscription. Its lifetime belongs to a capability:
/// register `dispose(subscription)` with `server.with_dispose`.
@external(javascript, "./topic_ffi.mjs", "subscription")
pub fn subscription(topic: Topic(event)) -> Subscription(event)

/// Starts listening, or replaces this subscription's previous callback.
@external(javascript, "./topic_ffi.mjs", "listen")
pub fn listen(
  subscription: Subscription(event),
  callback: fn(event) -> Nil,
) -> Nil

@external(javascript, "./topic_ffi.mjs", "dispose")
pub fn dispose(subscription: Subscription(event)) -> Nil
