//// Every public function here is an RPC method, except `all_views`, which the
//// Durable Object uses to fan out one view per player.
////
//// Identity and table scope come from `server.auth`, bound by the Durable
//// Object to the caller's session. No method takes a player id or a table
//// name, so a client cannot act as another player or against another table.

import blackjack/engine
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
  let #(player, table) = identity(context)
  use state <- promise.await(store.load(context, table))
  case engine.seat(state, player, name) {
    Error(error) -> promise.resolve(Error(error))
    Ok(state) -> {
      use _ <- promise.await(store.save(context, table, state))
      promise.resolve(Ok(views.of(state, player)))
    }
  }
}

pub fn act(
  context: Context,
  action action: s.Action,
) -> Promise(Result(s.View, s.GameError)) {
  let #(player, table) = identity(context)
  use state <- promise.await(store.load(context, table))
  case engine.process(state, player, action) {
    Error(error) -> promise.resolve(Error(error))
    Ok(state) -> {
      use _ <- promise.await(store.save(context, table, state))
      promise.resolve(Ok(views.of(state, player)))
    }
  }
}

/// The caller's current view of the table.
pub fn refresh(context: Context) -> Promise(s.View) {
  let #(player, table) = identity(context)
  use state <- promise.await(store.load(context, table))
  promise.resolve(views.of(state, player))
}

/// Sends the initial view. The Durable Object serves this method itself so it
/// can follow it with every later view.
pub fn subscribe(
  context: Context,
  on_view on_view: fn(s.View) -> Nil,
) -> Promise(Nil) {
  use view <- promise.map(refresh(context))
  on_view(view)
}

/// Every player's view, for the Durable Object to fan out. The browser's RPC
/// target doesn't expose this.
pub fn all_views(context: Context) -> Promise(List(#(String, s.View))) {
  let #(_, table) = identity(context)
  use state <- promise.await(store.load(context, table))
  promise.resolve(views.all(state))
}

fn identity(context: Context) -> #(String, String) {
  case decode.run(server.auth(context), identity_decoder()) {
    Ok(identity) -> identity
    Error(_) ->
      panic as "The Worker must pass {player, table} as auth."
  }
}

fn identity_decoder() -> decode.Decoder(#(String, String)) {
  use player <- decode.field("player", decode.string)
  use table <- decode.field("table", decode.string)
  decode.success(#(player, table))
}
