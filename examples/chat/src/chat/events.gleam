//// Both socket producers and consumers use chat/shared and generated codecs.

import chat/codecs
import chat/shared.{type RoomEvent, Presence}
import gleam/dynamic.{type Dynamic}
import starflame/plain
import starflame/server

pub fn publish(context: server.Context, event: RoomEvent) -> Nil {
  broadcast(server.execution(context), encode(event))
}

pub fn presence(online: Int) -> String {
  encode(Presence(online))
}

fn encode(event: RoomEvent) -> String {
  event |> codecs.room_event_to_plain |> plain.to_dynamic |> stringify
}

@external(javascript, "./events_ffi.mjs", "stringify")
fn stringify(value: Dynamic) -> String

@external(javascript, "./events_ffi.mjs", "broadcast")
fn broadcast(execution: Dynamic, payload: String) -> Nil
