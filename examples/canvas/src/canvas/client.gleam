//// The browser: a canvas plus a live board capability.

import canvas/board_client
import canvas/generated/client as rpc
import canvas/shared.{
  type BoardEvent, type CanvasError, type Stroke, type StrokeDraft, BadColor,
  BadWidth, Cleared, EmptyStroke, Presence, StrokeAdded, TooManyPoints,
}
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, none, text}
import lustre/element/html
import lustre/event
import starflame/client

// MODEL -----------------------------------------------------------------------

pub opaque type Model {
  Model(
    root: rpc.Api,
    board: Option(board_client.Board),
    read_only: Bool,
    strokes: List(Stroke),
    online: Int,
    connected: Bool,
    error: Option(String),
  )
}

pub fn main() -> Nil {
  let model =
    Model(
      root: rpc.connect(
        client.same_origin_url(
          base_path() <> "/rpc?room=" <> room_name() <> "&session=" <> session_token(),
        ),
      ),
      board: None,
      read_only: False,
      strokes: [],
      online: 0,
      connected: False,
      error: None,
    )
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", model)
  Nil
}

fn init(model: Model) -> #(Model, Effect(Msg)) {
  #(model, effect.batch([watch(model), enter(model, False), attach()]))
}

fn watch(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  rpc.on_broken(model.root, fn(reason) { dispatch(Broke(reason)) })
  Nil
}

fn enter(model: Model, read_only: Bool) -> Effect(Msg) {
  client.effect(board_client.enter(model.root, read_only), Entered(read_only, _))
}

fn subscribe_effect(board: board_client.Board) -> Effect(Msg) {
  use dispatch <- effect.from
  let _ =
    board_client.subscribe(board, fn(event) { dispatch(Received(event)) })
    |> promise.map(fn(reply) { dispatch(Subscribed(reply)) })
  Nil
}

fn attach() -> Effect(Msg) {
  use dispatch <- effect.from
  attach_canvas("board", fn(draft) { dispatch(GotDraft(draft)) })
  Nil
}

fn redraw(model: Model) -> Effect(Msg) {
  use _dispatch <- effect.from
  draw_board("board", model.strokes, model.read_only)
  Nil
}

// UPDATE ----------------------------------------------------------------------

pub type Msg {
  Entered(Bool, Result(board_client.Board, client.RpcError))
  GotSnapshot(Result(List(Stroke), client.RpcError))
  Subscribed(Result(Nil, client.RpcError))
  GotDraft(StrokeDraft)
  Added(Result(Result(Stroke, CanvasError), client.RpcError))
  PressedClear
  ClearedBoard(Result(Result(Nil, CanvasError), client.RpcError))
  ToggleMode
  Received(BoardEvent)
  Broke(String)
  Dismissed
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Entered(read_only, Ok(board)) -> {
      let model =
        Model(
          ..model,
          board: Some(board),
          read_only: read_only,
          strokes: [],
          error: None,
        )
      #(
        model,
        effect.batch([
          client.effect(board_client.snapshot(board), GotSnapshot),
          subscribe_effect(board),
          redraw(model),
        ]),
      )
    }
    Entered(_, Error(error)) -> failed(model, error)
    GotSnapshot(Ok(strokes)) -> {
      let model = Model(..model, strokes: strokes)
      #(model, redraw(model))
    }
    GotSnapshot(Error(error)) -> failed(model, error)
    Subscribed(Ok(_)) -> #(Model(..model, connected: True), effect.none())
    Subscribed(Error(error)) -> failed(model, error)
    GotDraft(draft) ->
      case model.read_only, model.board {
        True, _ -> #(model, effect.none())
        False, None -> #(model, effect.none())
        False, Some(board) ->
          #(model, client.effect(board_client.add(board, draft), Added))
      }
    Added(Ok(Ok(stroke))) -> {
      let model = Model(..model, strokes: add_stroke(model.strokes, stroke))
      #(model, redraw(model))
    }
    Added(Ok(Error(error))) ->
      #(Model(..model, error: Some(canvas_error_text(error))), effect.none())
    Added(Error(error)) -> failed(model, error)
    PressedClear ->
      case model.board, model.read_only {
        Some(board), False ->
          #(model, client.effect(board_client.clear(board), ClearedBoard))
        _, _ -> #(model, effect.none())
      }
    ClearedBoard(Ok(Ok(_))) -> {
      let model = Model(..model, strokes: [])
      #(model, redraw(model))
    }
    ClearedBoard(Ok(Error(error))) ->
      #(Model(..model, error: Some(canvas_error_text(error))), effect.none())
    ClearedBoard(Error(error)) -> failed(model, error)
    ToggleMode -> {
      case model.board {
        Some(board) -> board_client.dispose(board)
        None -> Nil
      }
      let read_only = !model.read_only
      let model = Model(..model, read_only: read_only, strokes: [])
      #(model, effect.batch([enter(model, read_only), redraw(model)]))
    }
    Received(StrokeAdded(stroke)) -> {
      let model = Model(..model, strokes: add_stroke(model.strokes, stroke))
      #(model, redraw(model))
    }
    Received(Cleared) -> {
      let model = Model(..model, strokes: [])
      #(model, redraw(model))
    }
    Received(Presence(online)) -> #(Model(..model, online: online), effect.none())
    Broke(reason) ->
      #(
        Model(..model, connected: False, error: Some(reason)),
        effect.none(),
      )
    Dismissed -> #(Model(..model, error: None), effect.none())
  }
}

fn failed(model: Model, error: client.RpcError) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, connected: False, error: Some(rpc_error_text(error))),
    effect.none(),
  )
}

fn add_stroke(strokes: List(Stroke), stroke: Stroke) -> List(Stroke) {
  case list.any(strokes, fn(existing) { existing.id == stroke.id }) {
    True -> strokes
    False -> list.append(strokes, [stroke])
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  html.main([attribute.class("app")], [
    html.header([], [
      html.div([attribute.class("brand")], [
        html.h1([], [text("#" <> room_name())]),
        html.span([attribute.class("online")], [
          text(
            int.to_string(model.online)
            <> case model.online {
              1 -> " person"
              _ -> " people"
            },
          ),
        ]),
      ]),
      html.div([attribute.class("tools")], [
        html.button(
          [
            attribute.class("btn"),
            event.on_click(ToggleMode),
          ],
          [
            text(
              case model.read_only {
                True -> "Edit"
                False -> "Watch only"
              },
            ),
          ],
        ),
        case model.read_only {
          True -> none()
          False ->
            html.button(
              [attribute.class("btn"), event.on_click(PressedClear)],
              [text("Clear")],
            )
        },
      ]),
    ]),
    error_banner(model.error),
    html.div([attribute.class("board-wrap")], [
      html.canvas([attribute.id("board"), attribute.class("board")]),
      case model.read_only {
        True -> html.div([attribute.class("badge")], [text("view only")])
        False -> none()
      },
      case model.board {
        None -> html.div([attribute.class("badge")], [text("connecting…")])
        Some(_) -> none()
      },
    ]),
    html.p([attribute.class("hint")], [
      text(
        "The editor holds a Board capability; view-only enters a BoardView that has no add or clear at all.",
      ),
    ]),
  ])
}

fn error_banner(error: Option(String)) -> Element(Msg) {
  case error {
    None -> none()
    Some(message) ->
      html.div([attribute.class("error")], [
        html.span([], [text(message)]),
        html.button(
          [attribute.class("link"), event.on_click(Dismissed)],
          [text("Dismiss")],
        ),
      ])
  }
}

fn canvas_error_text(error: CanvasError) -> String {
  case error {
    EmptyStroke -> "That stroke had no points."
    TooManyPoints(limit) ->
      "Keep strokes under " <> int.to_string(limit) <> " points."
    BadColor(color) -> "That colour isn't in the palette (" <> color <> ")."
    BadWidth -> "That width isn't allowed."
  }
}

fn rpc_error_text(error: client.RpcError) -> String {
  case error {
    client.Remote(message) -> message
    client.Http(status) ->
      "The server answered HTTP " <> int.to_string(status) <> "."
    client.Decode(_) -> "Could not decode the server's reply."
  }
}

// FFI -------------------------------------------------------------------------

@external(javascript, "./client_ffi.mjs", "session")
fn session_token() -> String

@external(javascript, "./client_ffi.mjs", "basePath")
fn base_path() -> String

@external(javascript, "./client_ffi.mjs", "roomName")
fn room_name() -> String

@external(javascript, "./client_ffi.mjs", "attach")
fn attach_canvas(id: String, on_draft: fn(StrokeDraft) -> Nil) -> Nil

@external(javascript, "./client_ffi.mjs", "draw")
fn draw_board(id: String, strokes: List(Stroke), read_only: Bool) -> Nil
