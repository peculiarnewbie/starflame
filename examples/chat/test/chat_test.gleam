import chat/messages
import chat/shared.{type Message, Message}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn message(id: String, created_at: Int) -> Message {
  Message(
    id: id,
    room: "room",
    author: "author",
    name: "Ada",
    body: id,
    created_at: created_at,
  )
}

pub fn merge_keeps_both_sides_test() {
  messages.merge([message("a", 1)], [message("b", 2)])
  |> should.equal([message("a", 1), message("b", 2)])
}

pub fn merge_dedupes_by_id_test() {
  messages.merge([message("a", 1)], [message("a", 1)])
  |> should.equal([message("a", 1)])
}

pub fn merge_orders_by_time_test() {
  messages.merge([message("b", 2)], [message("a", 1), message("c", 3)])
  |> should.equal([message("a", 1), message("b", 2), message("c", 3)])
}

pub fn a_live_event_survives_a_late_history_test() {
  // The event arrived while history was in flight; history is older.
  let received = messages.merge([], [message("live", 5)])
  messages.merge(received, [message("old", 1), message("older", 0)])
  |> should.equal([message("older", 0), message("old", 1), message("live", 5)])
}
