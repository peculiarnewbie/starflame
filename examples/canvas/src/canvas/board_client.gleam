//// UI helpers over the generated, typed capability clients. No method names,
//// return decoders, or independent wire contract are declared here.

import canvas/generated/client as rpc
import gleam/javascript/promise
import gleam/result
import starflame/client

pub opaque type Board {
  Editor(board: rpc.Board)
  Viewer(board: rpc.BoardView)
}

pub fn enter(root: rpc.Api, read_only: Bool) {
  case read_only {
    True -> promise.map(rpc.watch(root), result.map(_, Viewer))
    False -> promise.map(rpc.enter(root), result.map(_, Editor))
  }
}

pub fn snapshot(board: Board) {
  case board {
    Editor(board) -> rpc.board_snapshot(board)
    Viewer(board) -> rpc.board_view_snapshot(board)
  }
}

pub fn add(board: Board, draft) {
  case board {
    Editor(board) -> rpc.board_add(board, draft)
    Viewer(_) ->
      promise.resolve(Error(client.Remote("This board is read-only")))
  }
}

pub fn clear(board: Board) {
  case board {
    Editor(board) -> rpc.board_clear(board)
    Viewer(_) ->
      promise.resolve(Error(client.Remote("This board is read-only")))
  }
}

pub fn subscribe(board: Board, on_event) {
  case board {
    Editor(board) -> rpc.board_subscribe(board, on_event)
    Viewer(board) -> rpc.board_view_subscribe(board, on_event)
  }
}

pub fn dispose(board: Board) -> Nil {
  case board {
    Editor(board) -> rpc.board_dispose(board)
    Viewer(board) -> rpc.board_view_dispose(board)
  }
}
