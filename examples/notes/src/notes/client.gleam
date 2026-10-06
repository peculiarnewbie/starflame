//// The browser app: sign in, then add and delete notes.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import notes/generated/client as api
import notes/shared.{
  type Me, type Note, type NotesError, EmptyNote, NoteNotFound, NoteTooLong,
  ServerError, SignedOut,
}
import starflame/client.{type RpcError, Decode, Http, Remote}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

// MODEL -----------------------------------------------------------------------

pub opaque type Model {
  Loading(api: api.Api)
  SignedOutPage(api: api.Api)
  Notes(
    api: api.Api,
    me: Me,
    notes: List(Note),
    draft: String,
    error: Option(String),
  )
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  let api = api.connect_http("/rpc")
  #(Loading(api), client.effect(api.me(api), ApiReturnedMe))
}

// UPDATE ----------------------------------------------------------------------

pub opaque type Msg {
  ApiReturnedMe(Result(Result(Me, NotesError), RpcError))
  ApiReturnedNotes(Result(Result(List(Note), NotesError), RpcError))
  ApiAddedNote(Result(Result(Note, NotesError), RpcError))
  ApiDeletedNote(id: Int, reply: Result(Result(Nil, NotesError), RpcError))
  UserEditedDraft(String)
  UserAddedNote
  UserDeletedNote(id: Int)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case model, msg {
    _, ApiReturnedMe(Ok(Ok(me))) -> #(
      Notes(api: model.api, me:, notes: [], draft: "", error: None),
      client.effect(api.list_notes(model.api), ApiReturnedNotes),
    )
    _, ApiReturnedMe(reply) -> failed(model, reply)

    Notes(..), ApiReturnedNotes(Ok(Ok(notes))) -> #(
      Notes(..model, notes:),
      effect.none(),
    )

    Notes(..), UserEditedDraft(draft) -> #(
      Notes(..model, draft:),
      effect.none(),
    )
    Notes(..), UserAddedNote -> #(
      model,
      client.effect(api.add_note(model.api, model.draft), ApiAddedNote),
    )
    Notes(..), ApiAddedNote(Ok(Ok(note))) -> #(
      Notes(..model, notes: [note, ..model.notes], draft: "", error: None),
      effect.none(),
    )

    Notes(..), UserDeletedNote(id) -> #(
      model,
      client.effect(api.delete_note(model.api, id), ApiDeletedNote(id, _)),
    )
    Notes(..), ApiDeletedNote(id, Ok(Ok(Nil))) -> #(
      Notes(
        ..model,
        notes: list.filter(model.notes, fn(note) { note.id != id }),
        error: None,
      ),
      effect.none(),
    )

    _, ApiReturnedNotes(reply) -> failed(model, reply)
    _, ApiAddedNote(reply) -> failed(model, reply)
    _, ApiDeletedNote(_, reply) -> failed(model, reply)
    _, _ -> #(model, effect.none())
  }
}

/// A reply that wasn't a success. A 401 means the session ended, such as
/// after signing out in another tab.
fn failed(
  model: Model,
  reply: Result(Result(a, NotesError), RpcError),
) -> #(Model, Effect(Msg)) {
  let message = case reply {
    Ok(Ok(_)) -> None
    Error(Http(401)) | Ok(Error(SignedOut)) -> None
    Ok(Error(EmptyNote)) -> Some("Write something first.")
    Ok(Error(NoteTooLong(max))) ->
      Some("Notes can be up to " <> int.to_string(max) <> " characters.")
    Ok(Error(NoteNotFound)) -> Some("That note was already deleted.")
    Ok(Error(ServerError)) -> Some("Something went wrong. Try again.")
    Error(Http(status)) ->
      Some("The request failed with HTTP " <> int.to_string(status) <> ".")
    Error(Remote(message)) -> Some(message)
    Error(Decode(_)) -> Some("The server sent something unexpected.")
  }
  case reply, model {
    Error(Http(401)), _ | Ok(Error(SignedOut)), _ -> #(
      SignedOutPage(model.api),
      effect.none(),
    )
    _, Notes(..) -> #(Notes(..model, error: message), effect.none())
    _, _ -> #(SignedOutPage(model.api), effect.none())
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.main([attribute.class("app")], case model {
    Loading(..) -> []
    SignedOutPage(..) -> view_signed_out()
    Notes(me:, notes:, draft:, error:, ..) ->
      view_notes(me, notes, draft, error)
  })
}

fn view_signed_out() -> List(Element(Msg)) {
  [
    html.h1([], [text("Notes")]),
    html.p([attribute.class("muted")], [text("Sign in to see your notes.")]),
    html.div([attribute.class("sign-in")], [
      html.a([attribute.href("/auth/login?provider=google")], [
        text("Sign in with Google"),
      ]),
      html.a([attribute.href("/auth/login?provider=code")], [
        text("Sign in with email"),
      ]),
    ]),
  ]
}

fn view_notes(
  me: Me,
  notes: List(Note),
  draft: String,
  error: Option(String),
) -> List(Element(Msg)) {
  [
    html.header([], [
      html.h1([], [text("Notes")]),
      html.form([attribute.method("post"), attribute.action("/auth/logout")], [
        html.span([attribute.class("muted")], [text(me.email)]),
        html.button([attribute.class("link")], [text("Sign out")]),
      ]),
    ]),
    case error {
      Some(message) -> html.p([attribute.class("error")], [text(message)])
      None -> element.none()
    },
    html.form([event.on_submit(fn(_) { UserAddedNote })], [
      html.textarea(
        [
          attribute.placeholder("Write a note"),
          attribute.aria_label("New note"),
          event.on_input(UserEditedDraft),
        ],
        draft,
      ),
      html.button([attribute.type_("submit")], [text("Add")]),
    ]),
    keyed.ul([attribute.class("notes")], {
      use note <- list.map(notes)
      #(
        int.to_string(note.id),
        html.li([], [
          html.p([], [text(note.body)]),
          html.button(
            [
              attribute.class("link"),
              attribute.aria_label("Delete note"),
              event.on_click(UserDeletedNote(note.id)),
            ],
            [text("Delete")],
          ),
        ]),
      )
    }),
  ]
}
