//// Merging for history and live events. A snapshot and the socket can arrive in
//// any order, and a reconnect replays history, so the client merges by id
//// instead of replacing.

import chat/shared.{type Message}
import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/string

pub fn merge(
  existing: List(Message),
  incoming: List(Message),
) -> List(Message) {
  list.fold(
    incoming,
    dict.from_list(list.map(existing, fn(message) { #(message.id, message) })),
    fn(by_id, message) { dict.insert(by_id, message.id, message) },
  )
  |> dict.values
  |> list.sort(compare)
}

fn compare(a: Message, b: Message) -> order.Order {
  case int.compare(a.created_at, b.created_at) {
    order.Eq -> string.compare(a.id, b.id)
    other -> other
  }
}
