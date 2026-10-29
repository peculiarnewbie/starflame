//// The capability client: the generated client cannot express methods that
//// return stubs, so the board handle and its calls are written by hand against
//// `starflame/client`.

import canvas/codecs
import canvas/shared.{type BoardEvent, type CanvasError, type Stroke, type StrokeDraft}
import gleam/dynamic/decode
import gleam/javascript/promise
import gleam/result
import starflame/client
import starflame/plain

pub type Board {
  Board(stub: client.Stub)
}

/// Enters the room and receives a live board capability. `read_only` returns a
/// board with no editing methods.
pub fn enter(
  root: client.Stub,
  read_only: Bool,
) -> promise.Promise(Result(Board, client.RpcError)) {
  use reply <-
    promise.map(client.call(root, "enter", [plain.bool(read_only)], handles_decoder()))
  result.map(reply, Board)
}

pub fn snapshot(
  board: Board,
) -> promise.Promise(Result(List(Stroke), client.RpcError)) {
  let Board(stub) = board
  client.call(stub, "snapshot", [], decode.list(codecs.stroke_decoder()))
}

pub fn add(
  board: Board,
  draft: StrokeDraft,
) -> promise.Promise(Result(Result(Stroke, CanvasError), client.RpcError)) {
  let Board(stub) = board
  client.call(
    stub,
    "add",
    [codecs.stroke_draft_to_plain(draft)],
    plain.result_decoder(codecs.stroke_decoder(), codecs.canvas_error_decoder()),
  )
}

pub fn clear(
  board: Board,
) -> promise.Promise(Result(Result(Nil, CanvasError), client.RpcError)) {
  let Board(stub) = board
  client.call(
    stub,
    "clear",
    [],
    plain.result_decoder(plain.nil_decoder(), codecs.canvas_error_decoder()),
  )
}

pub fn subscribe(
  board: Board,
  on_event: fn(BoardEvent) -> Nil,
) -> promise.Promise(Result(Nil, client.RpcError)) {
  let Board(stub) = board
  client.call(
    stub,
    "subscribe",
    [client.callback(decode.at([0], codecs.board_event_decoder()), on_event)],
    plain.nil_decoder(),
  )
}

fn handles_decoder() -> decode.Decoder(client.Stub) {
  use board <- decode.field("board", client.stub_decoder())
  decode.success(board)
}

/// Releases the capability. Subscriptions registered by it are disposed with
/// it, which is what keeps presence honest when switching modes.
pub fn dispose(board: Board) -> Nil {
  let Board(stub) = board
  client.dispose(stub)
}
