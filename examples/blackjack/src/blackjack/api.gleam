//// Every public function here is an RPC method. Events and mutations share
//// the same Gleam types as the generated client.
////
//// Identity and table scope come from `server.auth`, bound by the Durable
//// Object to the caller's session. No method takes a player id or a table
//// name, so a client cannot act as another player or against another table.

import blackjack/engine
import blackjack/events
import blackjack/shared as s
import blackjack/store
import blackjack/view as views
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import starflame/server.{type Context}

/// Takes a seat, or renames the player already seated in this session.
pub fn join(
  context: Context,
  name name: String,
) -> Promise(Result(s.View, s.GameError)) {
  use <- server.serialise(context)
  let #(player, table) = identity(context)
  use state <- promise.await(store.load(context, table))
  case engine.seat(state, player, name) {
    Error(error) -> promise.resolve(Error(error))
    Ok(state) -> {
      use _ <- promise.await(store.save(context, table, state))
      events.publish(context, views.all(state))
      promise.resolve(Ok(views.of(state, player)))
    }
  }
}

pub fn act(
  context: Context,
  action action: s.Action,
) -> Promise(Result(s.View, s.GameError)) {
  use <- server.serialise(context)
  let #(player, table) = identity(context)
  use state <- promise.await(store.load(context, table))
  case engine.process(state, player, action) {
    Error(error) -> promise.resolve(Error(error))
    Ok(state) -> {
      use _ <- promise.await(store.save(context, table, state))
      events.publish(context, views.all(state))
      promise.resolve(Ok(views.of(state, player)))
    }
  }
}

/// The caller's current view of the table.
pub fn refresh(context: Context) -> Promise(s.View) {
  use <- server.serialise(context)
  current_view(context)
}

fn current_view(context: Context) -> Promise(s.View) {
  let #(player, table) = identity(context)
  use state <- promise.await(store.load(context, table))
  promise.resolve(views.of(state, player))
}

/// Sends the initial view, then typed updates for this player only.
pub fn subscribe(
  context: Context,
  on_view on_view: fn(s.View) -> Nil,
) -> Promise(Nil) {
  use <- server.serialise(context)
  use view <- promise.map(current_view(context))
  let #(player, _) = identity(context)
  events.subscribe(context, player, on_view)
  on_view(view)
}

fn identity(context: Context) -> #(String, String) {
  case decode.run(server.auth(context), identity_decoder()) {
    Ok(identity) -> identity
    Error(_) -> panic as "The Worker must pass {player, table} as auth."
  }
}

fn identity_decoder() -> decode.Decoder(#(String, String)) {
  use player <- decode.field("player", decode.string)
  use table <- decode.field("table", decode.string)
  decode.success(#(player, table))
}
