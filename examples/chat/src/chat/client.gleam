//// The browser: history and sends over HTTP RPC, live updates over a
//// hibernating WebSocket carrying typed envelopes.

import chat/codecs
import chat/generated/client as api
import chat/shared.{
  type ChatError, type Message, type RoomEvent, EmptyMessage, EmptyName,
  MessageTooLong, MessagePosted, NameTooLong, Presence, max_body, max_name,
}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute.{attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element, none, text}
import lustre/element/html
import lustre/event
import starflame/client

// MODEL -----------------------------------------------------------------------

pub opaque type Model {
  Model(
    api: api.Api,
    room: String,
    name: String,
    name_input: String,
    draft: String,
    messages: List(Message),
    online: Int,
    connected: Bool,
    error: Option(String),
  )
}

pub fn main() -> Nil {
  let room = room_name()
  let name = get_item("chat:name")
  let model =
    Model(
      api: api.connect_http("/rpc?room=" <> room <> "&session=" <> session_token()),
      room: room,
      name: name,
      name_input: name,
      draft: "",
      messages: [],
      online: 0,
      connected: False,
      error: None,
    )
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", model)
  Nil
}

fn init(model: Model) -> #(Model, Effect(Msg)) {
  case model.name {
    "" -> #(model, effect.none())
    _ -> #(model, joined_effects(model))
  }
}

fn joined_effects(model: Model) -> Effect(Msg) {
  effect.batch([load_history(model), connect(model)])
}

fn load_history(model: Model) -> Effect(Msg) {
  client.effect(api.history(model.api), GotHistory)
}

fn connect(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  socket(
    socket_url(model.room, model.name),
    fn(text) { dispatch(SocketText(text)) },
    fn(status) { dispatch(SocketStatus(status)) },
  )
  Nil
}

// UPDATE ----------------------------------------------------------------------

pub type Msg {
  NameChanged(String)
  Join
  DraftChanged(String)
  Send
  Sent(Result(Result(Message, ChatError), client.RpcError))
  GotHistory(Result(List(Message), client.RpcError))
  SocketText(String)
  SocketStatus(String)
  Dismissed
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    NameChanged(value) -> #(Model(..model, name_input: value), effect.none())
    Join -> {
      let name = string.trim(model.name_input)
      case string.length(name) {
        0 -> #(
          Model(..model, error: Some("Pick a name first.")),
          effect.none(),
        )
        _ -> {
          let _ = set_item("chat:name", name)
          let model =
            Model(..model, name: name, name_input: name, messages: [])
          #(model, joined_effects(model))
        }
      }
    }
    DraftChanged(value) -> #(Model(..model, draft: value), effect.none())
    Send -> {
      let body = string.trim(model.draft)
      case string.length(body) {
        0 -> #(model, effect.none())
        _ ->
          #(
            model,
            client.effect(api.send(model.api, model.name, body), Sent),
          )
      }
    }
    Sent(Ok(Ok(message))) ->
      #(
        Model(..model, draft: "", messages: add_message(model.messages, message)),
        effect.none(),
      )
    Sent(Ok(Error(error))) ->
      #(Model(..model, error: Some(chat_error_text(error))), effect.none())
    Sent(Error(error)) -> failed(model, error)
    GotHistory(Ok(messages)) ->
      #(Model(..model, messages: messages), effect.none())
    GotHistory(Error(error)) -> failed(model, error)
    SocketText(text) ->
      case decode_event(text) {
        Ok(MessagePosted(message)) ->
          #(
            Model(..model, messages: add_message(model.messages, message)),
            effect.none(),
          )
        Ok(Presence(online)) -> #(Model(..model, online: online), effect.none())
        Error(_) -> #(model, effect.none())
      }
    SocketStatus(status) ->
      #(Model(..model, connected: status == "open"), effect.none())
    Dismissed -> #(Model(..model, error: None), effect.none())
  }
}

fn failed(model: Model, error: client.RpcError) -> #(Model, Effect(Msg)) {
  #(Model(..model, error: Some(rpc_error_text(error))), effect.none())
}

fn add_message(messages: List(Message), message: Message) -> List(Message) {
  case list.any(messages, fn(existing) { existing.id == message.id }) {
    True -> messages
    False -> list.append(messages, [message])
  }
}

fn decode_event(text: String) -> Result(RoomEvent, Nil) {
  case decode.run(parse_json(text), codecs.room_event_decoder()) {
    Ok(event) -> Ok(event)
    Error(_) -> Error(Nil)
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  html.main([attribute.class("app")], [
    html.header([], [
      html.div([attribute.class("brand")], [
        html.h1([], [text("#" <> model.room)]),
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
      connection_pill(model),
    ]),
    case model.name {
      "" -> name_form(model)
      _ -> chat_view(model)
    },
  ])
}

fn name_form(model: Model) -> Element(Msg) {
  html.section([attribute.class("join")], [
    html.p([attribute.class("tagline")], [
      text("Pick a name. Messages stay in this room and are kept in D1."),
    ]),
    html.form([event.on_submit(fn(_) { Join })], [
      html.input([
        attribute.class("field"),
        attribute.placeholder("Your name"),
        attribute.value(model.name_input),
        attribute.autofocus(True),
        attribute.maxlength(max_name),
        event.on_input(NameChanged),
      ]),
      html.button([attribute.class("btn primary"), attribute.type_("submit")], [
        text("Enter room"),
      ]),
    ]),
  ])
}

fn chat_view(model: Model) -> Element(Msg) {
  html.section([attribute.class("chat")], [
    error_banner(model.error),
    html.div(
      [attribute.class("messages")],
      case model.messages {
        [] ->
          [
            html.p([attribute.class("empty")], [
              text("No messages yet. Say something."),
            ]),
          ]
        messages -> list.map(messages, message_view)
      },
    ),
    html.form(
      [attribute.class("composer"), event.on_submit(fn(_) { Send })],
      [
        html.input([
          attribute.class("field"),
          attribute.placeholder("Message #" <> model.room),
          attribute.value(model.draft),
          attribute.autofocus(True),
          attribute.maxlength(max_body),
          event.on_input(DraftChanged),
        ]),
        html.button(
          [
            attribute.class("btn primary"),
            attribute.type_("submit"),
            attribute.disabled(!model.connected),
          ],
          [text("Send")],
        ),
      ],
    ),
  ])
}

fn message_view(message: Message) -> Element(Msg) {
  html.article([attribute.class("message")], [
    html.div([attribute.class("message-head")], [
      html.span([attribute.class("author")], [text(message.name)]),
      html.span([attribute.class("time")], [text(time_label(message.created_at))]),
    ]),
    html.p([attribute.class("body")], [text(message.body)]),
  ])
}

fn connection_pill(model: Model) -> Element(Msg) {
  let #(class, label) = case model.connected {
    True -> #("online", "live")
    False -> #("offline", "reconnecting…")
  }
  html.span([attribute.class("connection " <> class)], [text(label)])
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

fn chat_error_text(error: ChatError) -> String {
  case error {
    EmptyMessage -> "Write something first."
    MessageTooLong(limit) ->
      "Keep it under " <> int.to_string(limit) <> " characters."
    EmptyName -> "Pick a name first."
    NameTooLong(limit) ->
      "Keep the name under " <> int.to_string(limit) <> " characters."
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

@external(javascript, "./client_ffi.mjs", "roomName")
fn room_name() -> String

@external(javascript, "./client_ffi.mjs", "getItem")
fn get_item(key: String) -> String

@external(javascript, "./client_ffi.mjs", "setItem")
fn set_item(key: String, value: String) -> Nil

@external(javascript, "./client_ffi.mjs", "socketUrl")
fn socket_url(room: String, name: String) -> String

@external(javascript, "./client_ffi.mjs", "socket")
fn socket(
  url: String,
  on_text: fn(String) -> Nil,
  on_status: fn(String) -> Nil,
) -> Nil

@external(javascript, "./client_ffi.mjs", "parseJson")
fn parse_json(text: String) -> Dynamic

@external(javascript, "./client_ffi.mjs", "timeLabel")
fn time_label(ms: Int) -> String
