//// The browser: upload through RPC, list from D1, view from R2.

import gleam/bit_array
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute.{attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element, none, text}
import lustre/element/html
import lustre/event
import photos/generated/client as api
import photos/shared.{
  type Photo, type PhotoError, EmptyFile, EmptyName, NameTooLong, NotFound,
  NotYours, StorageFailed, TooLarge, UnsupportedType,
}
import starflame/client

// MODEL -----------------------------------------------------------------------

pub opaque type Model {
  Model(
    api: api.Api,
    photos: List(Photo),
    me: String,
    error: Option(String),
    uploading: Bool,
    round_trip: Option(#(String, Int)),
  )
}

pub fn main() -> Nil {
  let model =
    Model(
      api: connect(),
      photos: [],
      me: "",
      error: None,
      uploading: False,
      round_trip: None,
    )
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", model)
  Nil
}

fn connect() -> api.Api {
  api.connect_http(base_path() <> "/rpc?session=" <> session_token())
}

@external(javascript, "./client_ffi.mjs", "session")
fn session_token() -> String

@external(javascript, "./client_ffi.mjs", "basePath")
fn base_path() -> String

fn init(model: Model) -> #(Model, Effect(Msg)) {
  #(model, effect.batch([load_photos(model), load_me(model)]))
}

// UPDATE ----------------------------------------------------------------------

pub type Msg {
  GotPhotos(Result(List(Photo), client.RpcError))
  GotMe(Result(String, client.RpcError))
  PressedUpload
  Picked(String, String, BitArray)
  PickFailed
  Uploaded(Result(Result(Photo, PhotoError), client.RpcError))
  PressedDelete(String)
  Deleted(Result(Result(Nil, PhotoError), client.RpcError))
  PressedVerify(String)
  Verified(String, Result(Result(BitArray, PhotoError), client.RpcError))
  Dismissed
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    GotPhotos(Ok(photos)) -> #(Model(..model, photos:), effect.none())
    GotPhotos(Error(error)) -> failed(model, error)
    GotMe(Ok(me)) -> #(Model(..model, me:), effect.none())
    GotMe(Error(error)) -> failed(model, error)
    PressedUpload -> #(model, pick_file())
    Picked(name, content_type, body) ->
      #(
        Model(..model, uploading: True, error: None),
        client.effect(
          api.upload(model.api, name, content_type, body),
          Uploaded,
        ),
      )
    PickFailed ->
      #(
        Model(..model, error: Some("Choose an image first.")),
        effect.none(),
      )
    Uploaded(Ok(Ok(_))) -> #(
      Model(..model, uploading: False, round_trip: None),
      load_photos(model),
    )
    Uploaded(Ok(Error(error))) ->
      #(
        Model(
          ..model,
          uploading: False,
          error: Some(game_error_text(error)),
        ),
        effect.none(),
      )
    Uploaded(Error(error)) ->
      error_reply(Model(..model, uploading: False), error)
    PressedDelete(id) ->
      #(model, client.effect(api.delete(model.api, id), Deleted))
    Deleted(Ok(Ok(_))) ->
      #(Model(..model, round_trip: None), load_photos(model))
    Deleted(Ok(Error(error))) ->
      #(Model(..model, error: Some(game_error_text(error))), effect.none())
    Deleted(Error(error)) -> error_reply(model, error)
    PressedVerify(id) ->
      #(model, client.effect(api.bytes(model.api, id), Verified(id, _)))
    Verified(id, Ok(Ok(body))) ->
      #(
        Model(
          ..model,
          round_trip: Some(#(id, bit_array.byte_size(body))),
        ),
        effect.none(),
      )
    Verified(_, Ok(Error(error))) ->
      #(Model(..model, error: Some(game_error_text(error))), effect.none())
    Verified(_, Error(error)) -> error_reply(model, error)
    Dismissed -> #(Model(..model, error: None), effect.none())
  }
}

fn failed(model: Model, error: client.RpcError) -> #(Model, Effect(Msg)) {
  #(Model(..model, error: Some(rpc_error_text(error))), effect.none())
}

fn error_reply(model: Model, error: client.RpcError) -> #(Model, Effect(Msg)) {
  failed(model, error)
}

fn load_photos(model: Model) -> Effect(Msg) {
  client.effect(api.list_photos(model.api), GotPhotos)
}

fn load_me(model: Model) -> Effect(Msg) {
  client.effect(api.me(model.api), GotMe)
}

fn pick_file() -> Effect(Msg) {
  use dispatch <- effect.from
  let _ =
    selected_file("photo-input")
    |> promise.map(fn(result) {
      case result {
        Ok(#(name, content_type, body)) ->
          dispatch(Picked(name, content_type, body))
        Error(_) -> dispatch(PickFailed)
      }
    })
  Nil
}

@external(javascript, "./client_ffi.mjs", "selectedFile")
fn selected_file(
  input_id: String,
) -> promise.Promise(Result(#(String, String, BitArray), Nil))

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  html.main([attribute.class("app")], [
    html.header([], [
      html.div([attribute.class("brand")], [
        html.h1([], [text("photos")]),
        html.span([attribute.class("count")], [
          text(int.to_string(list.length(model.photos)) <> " uploaded"),
        ]),
      ]),
    ]),
    error_banner(model.error),
    html.form(
      [attribute.class("upload"), event.on_submit(fn(_) { PressedUpload })],
      [
        html.input([
          attribute.id("photo-input"),
          attribute.type_("file"),
          attribute.accept(["image/png", "image/jpeg", "image/webp", "image/gif"]),
          attribute.class("file"),
        ]),
        html.button(
          [
            attribute.class("btn primary"),
            attribute.type_("submit"),
            attribute.disabled(model.uploading),
          ],
          [
            text(
              case model.uploading {
                True -> "Uploading…"
                False -> "Upload"
              },
            ),
          ],
        ),
      ],
    ),
    html.p([attribute.class("hint")], [
      text("Bodies cross RPC as Cap'n Web bytes, so the API receives a real BitArray."),
    ]),
    case model.photos {
      [] ->
        html.p([attribute.class("empty")], [
          text("Nothing here yet. Pick an image and upload it."),
        ])
      photos ->
        html.div(
          [attribute.class("grid")],
          list.map(photos, fn(photo) { photo_card(model, photo) }),
        )
    },
  ])
}

fn photo_card(model: Model, photo: Photo) -> Element(Msg) {
  let mine = photo.owner == model.me
  html.figure([attribute.class("card")], [
    html.div([attribute.class("thumb")], [
      html.img([
        attribute.src(base_path() <> "/photos/" <> photo.id),
        attribute.alt(photo.name),
      ]),
    ]),
    html.figcaption([], [
      html.div([attribute.class("meta")], [
        html.span([attribute.class("name")], [text(photo.name)]),
        html.span([attribute.class("size")], [text(size_label(photo.size))]),
      ]),
      html.div([attribute.class("row")], [
        case mine {
          True -> html.span([attribute.class("badge")], [text("yours")])
          False -> none()
        },
        action_button("Verify", PressedVerify(photo.id)),
        case mine {
          True -> action_button("Delete", PressedDelete(photo.id))
          False -> none()
        },
      ]),
      case model.round_trip {
        Some(#(id, bytes)) if id == photo.id ->
          html.span([attribute.class("roundtrip")], [
            text("RPC round trip: " <> int.to_string(bytes) <> " bytes"),
          ])
        _ -> none()
      },
    ]),
  ])
}

fn action_button(label: String, msg: Msg) -> Element(Msg) {
  html.button(
    [attribute.class("btn"), event.on_click(msg)],
    [text(label)],
  )
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

fn size_label(bytes: Int) -> String {
  case bytes < 1000 {
    True -> int.to_string(bytes) <> " B"
    False -> int.to_string(bytes / 1000) <> " kB"
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

fn game_error_text(error: PhotoError) -> String {
  case error {
    EmptyName -> "Give the file a name."
    NameTooLong(limit) ->
      "Keep the name under " <> int.to_string(limit) <> " characters."
    EmptyFile -> "That file is empty."
    UnsupportedType(content_type) ->
      "Can't upload " <> content_type <> ". Use PNG, JPEG, WebP or GIF."
    TooLarge(limit) ->
      "Keep it under " <> int.to_string(limit / 1_000_000) <> " MB."
    NotFound(_) -> "That photo is gone."
    NotYours(_) -> "That photo belongs to another session."
    StorageFailed -> "Storage failed. Try again."
  }
}
