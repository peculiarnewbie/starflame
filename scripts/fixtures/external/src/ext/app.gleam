import ext/codecs
import ext/generated/client as rpc
import ext/shared.{type Note}
import gleam/javascript/promise.{type Promise}
import starflame/client

pub fn encode(note: Note) {
  codecs.note_to_plain(note)
}

pub fn clear(
  board: rpc.Board,
) -> Promise(Result(Result(Nil, String), client.RpcError)) {
  rpc.board_clear(board)
}
