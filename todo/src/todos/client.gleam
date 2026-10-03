//// The Lustre SPA.

import starflame/client.{type RpcError, Decode, Remote}
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute.{attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import todos/generated/client as api
import todos/shared.{
  type Todo, type TodoError, EmptyTitle, NotFound, TitleTooLong, Todo,
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

// MODEL -----------------------------------------------------------------------

type Model {
  Model(
    api: api.Api,
    connection: Connection,
    todos: List(Todo),
    draft: String,
    filter: Filter,
    error: Option(String),
  )
}

type Connection {
  Connecting
  Online
  Offline(reason: String)
}

type Filter {
  All
  Active
  Completed
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  let api = api.connect(client.same_origin_url("/rpc"))
  let model =
    Model(
      api:,
      connection: Connecting,
      todos: [],
      draft: "",
      filter: All,
      error: None,
    )
  #(model, effect.batch([watch(api), fetch(api), on_focus()]))
}

// UPDATE ----------------------------------------------------------------------

type Msg {
  UserEditedDraft(String)
  UserSubmittedDraft
  UserToggled(id: Int, done: Bool)
  UserDeleted(id: Int)
  UserClearedCompleted
  UserChoseFilter(Filter)
  UserDismissedError
  WindowFocused
  ConnectionBroke(reason: String)
  RetryTimerFired
  ApiReturnedTodos(Result(List(Todo), RpcError))
  ApiAddedTodo(Result(Result(Todo, TodoError), RpcError))
  ApiUpdatedTodo(Result(Result(Todo, TodoError), RpcError))
  ApiDeletedTodo(id: Int, reply: Result(Result(Nil, TodoError), RpcError))
  ApiClearedCompleted(Result(Int, RpcError))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserEditedDraft(draft) -> #(Model(..model, draft:), effect.none())

    UserSubmittedDraft -> #(
      model,
      client.effect(api.add_todo(model.api, model.draft), ApiAddedTodo),
    )

    UserToggled(id:, done:) -> {
      // Optimistic: flip it now, the reply confirms or corrects it.
      let todos =
        list.map(model.todos, fn(item) {
          case item.id == id {
            True -> Todo(..item, done:)
            False -> item
          }
        })
      #(
        Model(..model, todos:),
        client.effect(api.set_done(model.api, id, done), ApiUpdatedTodo),
      )
    }

    UserDeleted(id:) -> #(
      model,
      client.effect(api.delete_todo(model.api, id), ApiDeletedTodo(id, _)),
    )

    UserClearedCompleted -> #(
      model,
      client.effect(api.clear_completed(model.api), ApiClearedCompleted),
    )

    UserChoseFilter(filter) -> #(Model(..model, filter:), effect.none())

    UserDismissedError -> #(Model(..model, error: None), effect.none())

    WindowFocused ->
      case model.connection {
        Online -> #(model, fetch(model.api))
        _ -> #(model, effect.none())
      }

    ConnectionBroke(reason:) ->
      case model.connection {
        Offline(_) -> #(model, effect.none())
        _ -> #(Model(..model, connection: Offline(reason)), retry_later())
      }

    RetryTimerFired -> {
      let api = api.connect(client.same_origin_url("/rpc"))
      #(
        Model(..model, api:, connection: Connecting),
        effect.batch([watch(api), fetch(api)]),
      )
    }

    ApiReturnedTodos(Ok(todos)) -> #(
      Model(..model, todos:, connection: Online),
      effect.none(),
    )

    ApiAddedTodo(Ok(Ok(item))) -> #(
      Model(
        ..model,
        todos: list.append(model.todos, [item]),
        draft: "",
        error: None,
      ),
      effect.none(),
    )

    ApiUpdatedTodo(Ok(Ok(item))) -> #(
      Model(
        ..model,
        todos: list.map(model.todos, fn(existing) {
          case existing.id == item.id {
            True -> item
            False -> existing
          }
        }),
      ),
      effect.none(),
    )

    ApiDeletedTodo(id:, reply: Ok(Ok(Nil))) -> #(
      Model(..model, todos: list.filter(model.todos, fn(item) { item.id != id })),
      effect.none(),
    )

    ApiClearedCompleted(Ok(_)) -> #(
      Model(..model, todos: list.filter(model.todos, fn(item) { !item.done })),
      effect.none(),
    )

    // Something changed elsewhere: show why and resync.
    ApiAddedTodo(Ok(Error(error)))
    | ApiUpdatedTodo(Ok(Error(error)))
    | ApiDeletedTodo(reply: Ok(Error(error)), ..) -> #(
      Model(..model, error: Some(describe_todo_error(error))),
      fetch(model.api),
    )

    // Transport failures. A broken session also fires ConnectionBroke, which
    // handles reconnecting.
    ApiReturnedTodos(Error(error))
    | ApiAddedTodo(Error(error))
    | ApiUpdatedTodo(Error(error))
    | ApiDeletedTodo(reply: Error(error), ..)
    | ApiClearedCompleted(Error(error)) -> #(
      Model(..model, error: Some(describe_rpc_error(error))),
      effect.none(),
    )
  }
}

fn describe_todo_error(error: TodoError) -> String {
  case error {
    EmptyTitle -> "Write something first."
    TitleTooLong(max:) ->
      "That's too long, keep it under " <> int.to_string(max) <> " characters."
    NotFound(_) -> "That todo was already removed, maybe from another device."
  }
}

fn describe_rpc_error(error: RpcError) -> String {
  case error {
    Remote(message) -> message
    Decode(_) -> "The server sent something unexpected."
  }
}

// EFFECTS ---------------------------------------------------------------------

fn fetch(api: api.Api) -> Effect(Msg) {
  client.effect(api.list_todos(api), ApiReturnedTodos)
}

fn watch(api: api.Api) -> Effect(Msg) {
  use dispatch <- effect.from
  api.on_broken(api, fn(reason) { dispatch(ConnectionBroke(reason)) })
}

fn retry_later() -> Effect(Msg) {
  use dispatch <- effect.from
  promise.wait(1500)
  |> promise.map(fn(_) { dispatch(RetryTimerFired) })
  Nil
}

fn on_focus() -> Effect(Msg) {
  use dispatch <- effect.from
  do_on_focus(fn() { dispatch(WindowFocused) })
}

@external(javascript, "./client_ffi.mjs", "onFocus")
fn do_on_focus(callback: fn() -> Nil) -> Nil

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let remaining = list.count(model.todos, fn(item) { !item.done })
  let visible =
    list.filter(model.todos, fn(item) {
      case model.filter {
        All -> True
        Active -> !item.done
        Completed -> item.done
      }
    })

  html.main([attribute.class("app")], [
    html.header([], [
      html.h1([], [text("todos")]),
      view_connection(model.connection),
    ]),
    html.p([attribute.class("tagline")], [
      text("Gleam + Lustre, talking to a Gleam Worker over Cap'n Web"),
    ]),
    view_error(model.error),
    html.form([event.on_submit(fn(_) { UserSubmittedDraft })], [
      html.input([
        attribute.class("new-todo"),
        attribute.placeholder("What needs doing?"),
        attribute.value(model.draft),
        attribute.autofocus(True),
        attribute("aria-label", "New todo"),
        event.on_input(UserEditedDraft),
      ]),
    ]),
    keyed.ul(
      [attribute.class("todos")],
      list.map(visible, fn(item) { #(int.to_string(item.id), view_todo(item)) }),
    ),
    case model.todos {
      [] -> html.p([attribute.class("empty")], [text("Nothing to do. Nice.")])
      _ ->
        html.footer([], [
          html.span([], [
            text(int.to_string(remaining) <> " left"),
          ]),
          html.div([attribute.class("filters")], [
            view_filter(model.filter, All, "All"),
            view_filter(model.filter, Active, "Active"),
            view_filter(model.filter, Completed, "Done"),
          ]),
          html.button(
            [
              attribute.class("link"),
              attribute.disabled(remaining == list.length(model.todos)),
              event.on_click(UserClearedCompleted),
            ],
            [text("Clear done")],
          ),
        ])
    },
  ])
}

fn view_connection(connection: Connection) -> Element(Msg) {
  let #(class, label) = case connection {
    Connecting -> #("connecting", "connecting…")
    Online -> #("online", "live")
    Offline(_) -> #("offline", "reconnecting…")
  }
  html.span([attribute.class("connection " <> class)], [text(label)])
}

fn view_error(error: Option(String)) -> Element(Msg) {
  case error {
    None -> element.none()
    Some(message) ->
      html.div([attribute.class("error")], [
        html.span([], [text(message)]),
        html.button(
          [
            attribute.class("link"),
            attribute("aria-label", "Dismiss"),
            event.on_click(UserDismissedError),
          ],
          [text("×")],
        ),
      ])
  }
}

fn view_todo(item: Todo) -> Element(Msg) {
  html.li([attribute.classes([#("done", item.done)])], [
    html.label([], [
      html.input([
        attribute.type_("checkbox"),
        attribute.checked(item.done),
        event.on_check(UserToggled(item.id, _)),
      ]),
      html.span([], [text(item.title)]),
    ]),
    html.button(
      [
        attribute.class("delete"),
        attribute("aria-label", "Delete " <> item.title),
        event.on_click(UserDeleted(item.id)),
      ],
      [text("×")],
    ),
  ])
}

fn view_filter(current: Filter, filter: Filter, label: String) -> Element(Msg) {
  html.button(
    [
      attribute.classes([#("link", True), #("selected", current == filter)]),
      event.on_click(UserChoseFilter(filter)),
    ],
    [text(label)],
  )
}
