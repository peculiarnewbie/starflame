//// The browser: a Lustre app that talks to the table over Cap'n Web.

import blackjack/generated/client as api
import blackjack/shared.{
  type Action, type Card, type DealerCard, type GameError, type HandResult,
  type HandView, type PlayerView, type View, AlreadyBet, AlreadyDecided, Betting, Blackjack,
  Bust, CannotDouble, CannotSplit, CannotStartRound, DealerTurn, Diamond,
  DoubleDown, EmptyName, HandIsDone, Heart, Hidden, Hit, Insurance, Lose,
  NameTooLong, NewRound, NotYourTurn, PlaceBet, Playing, PlayerNotFound, Push,
  Settled, Shown, SittingOut, Spade, Split, Stand, TableFull, TakeInsurance, Win,
  WrongPhase, Club, max_bet, min_bet,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute.{attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element, none, text}
import lustre/element/html
import lustre/element/svg
import lustre/event
import starflame/client

type ApiReply =
  Result(Result(View, GameError), client.RpcError)

// MODEL -----------------------------------------------------------------------

pub opaque type Model {
  Model(
    api: api.Api,
    table: String,
    name: String,
    bet_draft: String,
    view: Option(View),
    error: Option(String),
    connection: Connection,
  )
}

type Connection {
  Connecting
  Online
  Offline(reason: String)
}

pub fn main() -> Nil {
  let table = table_name()
  let model =
    Model(
      api: connect(table),
      table: table,
      name: stored("blackjack:name"),
      bet_draft: "50",
      view: None,
      error: None,
      connection: Connecting,
    )
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", model)
  Nil
}

fn connect(table: String) -> api.Api {
  api.connect(
    client.same_origin_url(
      base_path() <> "/rpc?table=" <> table <> "&session=" <> session_token(),
    ),
  )
}

fn init(flags: Model) -> #(Model, Effect(Msg)) {
  let model = Model(..flags, connection: Connecting)
  let effects = [subscribe(model), watch(model)]
  let effects = case string.trim(model.name) {
    "" -> effects
    _ -> [join_effect(model), ..effects]
  }
  #(model, effect.batch(effects))
}

// UPDATE ----------------------------------------------------------------------

pub type Msg {
  NameChanged(String)
  Join
  Joined(ApiReply)
  BetChanged(String)
  BetPreset(Int)
  SubmitBet
  PressedHit
  PressedStand
  PressedDouble
  PressedSplit
  AnswerInsurance(Bool)
  PressedNextRound
  Acted(ApiReply)
  GotView(View)
  ConnectionBroke(String)
  Dismissed
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    NameChanged(name) -> #(Model(..model, name:), effect.none())
    Join -> {
      let name = string.trim(model.name)
      case name {
        "" -> #(Model(..model, error: Some("Enter a name to sit down.")), effect.none())
        _ -> {
          let _ = set_item("blackjack:name", name)
          let model = Model(..model, name:, error: None)
          #(model, join_effect(model))
        }
      }
    }
    Joined(reply) -> handle_reply(model, reply)
    BetChanged(draft) -> #(Model(..model, bet_draft: draft), effect.none())
    BetPreset(amount) ->
      #(Model(..model, bet_draft: int.to_string(amount)), effect.none())
    SubmitBet -> #(model, act(model, PlaceBet(bet_amount(model))))
    PressedHit -> #(model, act(model, Hit))
    PressedStand -> #(model, act(model, Stand))
    PressedDouble -> #(model, act(model, DoubleDown))
    PressedSplit -> #(model, act(model, Split))
    AnswerInsurance(accept) ->
      #(model, act(model, TakeInsurance(accept)))
    PressedNextRound -> #(model, act(model, NewRound))
    Acted(reply) -> handle_reply(model, reply)
    GotView(view) ->
      #(
        Model(..model, view: Some(view), connection: Online, error: None),
        effect.none(),
      )
    ConnectionBroke(reason) -> {
      api.dispose(model.api)
      let model =
        Model(
          ..model,
          api: connect(model.table),
          connection: Offline(reason),
          view: None,
          error: Some("Connection lost. Rejoining…"),
        )
      #(model, effect.batch([subscribe(model), watch(model), join_effect(model)]))
    }
    Dismissed -> #(Model(..model, error: None), effect.none())
  }
}

fn handle_reply(model: Model, reply: ApiReply) -> #(Model, Effect(Msg)) {
  case reply {
    Ok(Ok(view)) ->
      #(
        Model(
          ..model,
          view: Some(view),
          error: None,
          connection: Online,
        ),
        effect.none(),
      )
    Ok(Error(error)) ->
      #(Model(..model, error: Some(game_error_text(error))), effect.none())
    Error(error) ->
      #(
        Model(
          ..model,
          error: Some(rpc_error_text(error)),
          connection: Offline(rpc_error_text(error)),
        ),
        effect.none(),
      )
  }
}

fn join_effect(model: Model) -> Effect(Msg) {
  case string.trim(model.name) {
    "" -> effect.none()
    _ -> client.effect(api.join(model.api, model.name), Joined)
  }
}

fn act(model: Model, action: Action) -> Effect(Msg) {
  client.effect(api.act(model.api, action), Acted)
}

fn subscribe(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  let _ = api.subscribe(model.api, fn(view) { dispatch(GotView(view)) })
  Nil
}

fn watch(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  api.on_broken(model.api, fn(reason) { dispatch(ConnectionBroke(reason)) })
  Nil
}

fn bet_amount(model: Model) -> Int {
  case int.parse(string.trim(model.bet_draft)) {
    Ok(amount) -> amount
    Error(_) -> min_bet
  }
}

fn stored(key: String) -> String {
  get_item(key)
}

@external(javascript, "./client_ffi.mjs", "getItem")
fn get_item(key: String) -> String

@external(javascript, "./client_ffi.mjs", "setItem")
fn set_item(key: String, value: String) -> Nil

@external(javascript, "./client_ffi.mjs", "session")
fn session_token() -> String

@external(javascript, "./client_ffi.mjs", "basePath")
fn base_path() -> String

@external(javascript, "./client_ffi.mjs", "tableName")
fn table_name() -> String

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  html.main([attribute.class("app")], [
    html.header([], [
      html.div([attribute.class("brand")], [
        html.h1([], [text("blackjack")]),
        html.span([attribute.class("table-name")], [text("#" <> model.table)]),
      ]),
      connection_pill(model.connection),
    ]),
    error_banner(model.error),
    case model.view {
      None -> join_screen(model)
      Some(table) ->
        case is_seated(table) {
          False -> join_screen(model)
          True -> table_view(model, table)
        }
    },
  ])
}

fn is_seated(table: View) -> Bool {
  list.any(table.players, fn(player) { player.id == table.my_id })
}

fn join_screen(model: Model) -> Element(Msg) {
  html.section([attribute.class("join")], [
    html.p([attribute.class("tagline")], [
      text(
        "Six-deck table, up to six players. Open this page on another device to play from there.",
      ),
    ]),
    html.form([event.on_submit(fn(_) { Join })], [
      html.input([
        attribute.class("name-input"),
        attribute.placeholder("Your name"),
        attribute.value(model.name),
        attribute.autofocus(True),
        attribute("aria-label", "Your name"),
        event.on_input(NameChanged),
      ]),
      html.button([attribute.class("btn primary"), attribute.type_("submit")], [
        text("Take a seat"),
      ]),
    ]),
  ])
}

fn table_view(model: Model, table: View) -> Element(Msg) {
  html.section([attribute.class("table")], [
    html.div([attribute.class("meta")], [
      html.span([], [text("Round " <> int.to_string(table.round_number))]),
      html.span([], [text("Shoe " <> int.to_string(table.shoe_count))]),
      turn_label(table),
    ]),
    html.div([attribute.class("dealer")], [
      html.div([attribute.class("seat-head")], [
        html.span([attribute.class("who")], [text("Dealer")]),
        html.span([attribute.class("value")], [
          text(
            case table.dealer.value {
              Some(value) -> int.to_string(value)
              None -> "?"
            },
          ),
        ]),
      ]),
      cards(list.map(table.dealer.cards, dealer_card)),
    ]),
    html.div([attribute.class("seats")], list.map(table.players, fn(player) { seat(table, player) })),
    actions(model, table),
    results(table),
  ])
}

fn turn_label(table: View) -> Element(Msg) {
  case table.phase {
    Playing ->
      case nth(table.players, table.current_player_index) {
        Some(player) -> html.span([attribute.class("turn")], [
          text(player.name <> "'s turn"),
        ])
        None -> none()
      }
    Settled -> html.span([attribute.class("turn")], [text("Round over")])
    _ -> none()
  }
}

fn seat(table: View, player: PlayerView) -> Element(Msg) {
  let is_turn =
    table.phase == Playing
    && case nth(table.players, table.current_player_index) {
      Some(current) -> current.id == player.id
      None -> False
    }
  html.div(
    [attribute.class("seat" <> active_class(player.id == table.my_id, is_turn))],
    [
      html.div([attribute.class("seat-head")], [
        html.span([attribute.class("who")], [text(player.name)]),
        html.span([attribute.class("chips")], [
          text(int.to_string(player.chips) <> " chips"),
        ]),
      ]),
      case player.hands {
        [] ->
          html.div([attribute.class("waiting")], [
            text(
              case table.phase, player.bet > 0 {
                Betting, False -> "waiting to bet"
                Betting, True -> "bet " <> int.to_string(player.bet)
                _, _ -> "waiting"
              },
            ),
          ])
        hands ->
          html.div([], list.index_map(hands, fn(hand, index) {
            hand_view(hand, is_turn && index == player.current_hand_index)
          }))
      },
    ],
  )
}

fn hand_view(hand: HandView, active: Bool) -> Element(Msg) {
  html.div([attribute.class("hand" <> active_class(False, active))], [
    cards(list.map(hand.cards, plain_card)),
    html.div([attribute.class("hand-meta")], [
      text(int.to_string(hand.value)),
      case hand.soft {
        True -> text(" soft")
        False -> none()
      },
      text(" · bet " <> int.to_string(hand.bet)),
      case hand.doubled {
        True -> text(" · doubled")
        False -> none()
      },
      case hand.busted {
        True -> text(" · bust")
        False -> none()
      },
      case hand.is_blackjack {
        True -> text(" · blackjack")
        False -> none()
      },
      case hand.stood && !hand.busted {
        True -> text(" · stood")
        False -> none()
      },
    ]),
  ])
}

fn actions(model: Model, table: View) -> Element(Msg) {
  html.div([attribute.class("actions")], [
    case table.needs_bet {
      True -> bet_controls(model)
      False -> none()
    },
    case table.needs_insurance {
      True ->
        html.div([attribute.class("row")], [
          html.span([attribute.class("prompt")], [text("Insurance?")]),
          action_button("Yes", AnswerInsurance(True), True),
          action_button("No", AnswerInsurance(False), True),
        ])
      False -> none()
    },
    case table.is_my_turn {
      True ->
        html.div([attribute.class("row")], [
          action_button("Hit", PressedHit, table.can_hit),
          action_button("Stand", PressedStand, table.can_stand),
          action_button("Double", PressedDouble, table.can_double),
          action_button("Split", PressedSplit, table.can_split),
        ])
      False -> none()
    },
    case table.phase {
      Settled ->
        html.div([attribute.class("row")], [
          action_button("Next round", PressedNextRound, True),
        ])
      _ -> none()
    },
  ])
}

fn bet_controls(model: Model) -> Element(Msg) {
  html.div([attribute.class("bet")], [
    html.div([attribute.class("row")], [
      html.input([
        attribute.class("bet-input"),
        attribute.type_("number"),
        attribute.min(int.to_string(min_bet)),
        attribute.max(int.to_string(max_bet)),
        attribute.step("5"),
        attribute.value(model.bet_draft),
        attribute("aria-label", "Bet"),
        event.on_input(BetChanged),
      ]),
      action_button("Deal", SubmitBet, True),
    ]),
    html.div(
      [attribute.class("presets")],
      list.map([10, 25, 50, 100, 500], fn(amount) {
        html.button(
          [
            attribute.class("chip"),
            event.on_click(BetPreset(amount)),
          ],
          [text(int.to_string(amount))],
        )
      }),
    ),
  ])
}

fn results(table: View) -> Element(Msg) {
  case table.results {
    None -> none()
    Some(results) -> {
      let rows =
        list.map(results, fn(result) {
          html.div([attribute.class("result-row")], [
            html.span([attribute.class("who")], [text(result.player_name)]),
            html.span([attribute.class("outcomes")], [
              text(string.join(list.map(result.hands, outcome_text), " · ")),
            ]),
            html.span(
              [
                attribute.class(
                  case result.net_chips {
                    net if net > 0 -> "net up"
                    net if net < 0 -> "net down"
                    _ -> "net flat"
                  },
                ),
              ],
              [text(signed(result.net_chips))],
            ),
          ])
        })
      html.div(
        [attribute.class("results")],
        list.append([html.h2([], [text("Last round")])], rows),
      )
    }
  }
}

fn outcome_text(result: HandResult) -> String {
  case result.outcome {
    Blackjack -> "blackjack"
    Win -> "win"
    Push -> "push"
    Lose -> "lose"
    Bust -> "bust"
  }
}

fn signed(amount: Int) -> String {
  case amount {
    value if value > 0 -> "+" <> int.to_string(value)
    _ -> int.to_string(amount)
  }
}

fn cards(items: List(Element(Msg))) -> Element(Msg) {
  html.div([attribute.class("cards")], items)
}

fn plain_card(card: Card) -> Element(Msg) {
  html.div(
    [
      attribute.class("card " <> suit_class(card.suit)),
      attribute("aria-label", rank_label(card.rank) <> " of " <> suit_name(card.suit)),
    ],
    [
      html.span([attribute.class("rank")], [text(rank_label(card.rank))]),
      html.span([attribute.class("suit")], [suit_icon(card.suit)]),
    ],
  )
}

// The seats are drawn rather than typed so they don't depend on the system's
// symbol fonts.
fn suit_icon(suit) -> Element(Msg) {
  svg.svg(
    [
      attribute("viewBox", "0 0 24 24"),
      attribute("width", "16"),
      attribute("height", "16"),
      attribute("fill", "currentColor"),
      attribute("aria-hidden", "true"),
    ],
    case suit {
      Spade -> [
        svg.path([
          attribute(
            "d",
            "M12 2C9.5 6.5 3 9 3 13.5A4.5 4.5 0 0 0 10 18c-.3 1.8-1 3-2 4h8c-1-1-1.7-2.2-2-4a4.5 4.5 0 0 0 7-4.5C21 9 14.5 6.5 12 2Z",
          ),
        ]),
      ]
      Heart -> [
        svg.path([
          attribute(
            "d",
            "M12 21C12 21 3 15.5 3 9.5A5 5 0 0 1 12 6a5 5 0 0 1 9 3.5C21 15.5 12 21 12 21Z",
          ),
        ]),
      ]
      Diamond -> [
        svg.path([attribute("d", "M12 2 20 12 12 22 4 12Z")]),
      ]
      Club -> [
        svg.circle([attribute("cx", "12"), attribute("cy", "7"), attribute("r", "4.2")]),
        svg.circle([attribute("cx", "6.4"), attribute("cy", "14"), attribute("r", "4.2")]),
        svg.circle([attribute("cx", "17.6"), attribute("cy", "14"), attribute("r", "4.2")]),
        svg.path([attribute("d", "M10 15c.6 3 0 5-2 7h8c-2-2-2.6-4-2-7z")]),
      ]
    },
  )
}

fn suit_name(suit) -> String {
  case suit {
    Spade -> "spades"
    Club -> "clubs"
    Heart -> "hearts"
    Diamond -> "diamonds"
  }
}

fn dealer_card(card: DealerCard) -> Element(Msg) {
  case card {
    Shown(card) -> plain_card(card)
    Hidden -> html.div([attribute.class("card back")], [])
  }
}

fn suit_class(suit) -> String {
  case suit {
    Spade -> "spade"
    Club -> "club"
    Heart -> "heart"
    Diamond -> "diamond"
  }
}

fn rank_label(rank: Int) -> String {
  case rank {
    1 -> "A"
    11 -> "J"
    12 -> "Q"
    13 -> "K"
    _ -> int.to_string(rank)
  }
}

fn action_button(label: String, msg: Msg, enabled: Bool) -> Element(Msg) {
  html.button(
    [
      attribute.class("btn"),
      attribute.disabled(!enabled),
      event.on_click(msg),
    ],
    [text(label)],
  )
}

fn connection_pill(connection: Connection) -> Element(Msg) {
  let #(class, label) = case connection {
    Connecting -> #("connecting", "connecting…")
    Online -> #("online", "live")
    Offline(_) -> #("offline", "reconnecting…")
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

fn active_class(mine: Bool, turn: Bool) -> String {
  case mine, turn {
    True, True -> " mine turn"
    True, False -> " mine"
    False, True -> " turn"
    False, False -> ""
  }
}

fn nth(items: List(a), index: Int) -> Option(a) {
  case index < 0, items {
    True, _ -> None
    _, [] -> None
    _, [first, ..rest] ->
      case index {
        0 -> Some(first)
        _ -> nth(rest, index - 1)
      }
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

fn game_error_text(error: GameError) -> String {
  case error {
    PlayerNotFound(_) -> "You're not seated at this table."
    TableFull(limit) ->
      "This table is full (" <> int.to_string(limit) <> " players)."
    NotYourTurn -> "Not your turn yet."
    WrongPhase(phase) -> "Not now: the table is in " <> phase_text(phase) <> "."
    AlreadyBet -> "You already placed a bet."
    SittingOut -> "You're sitting this round out."
    AlreadyDecided -> "You already answered the insurance offer."
    HandIsDone -> "That hand is finished."
    CannotSplit -> "This hand can't be split."
    CannotDouble -> "This hand can't be doubled."
    CannotStartRound -> "Finish this round first."
    EmptyName -> "Enter a name."
    NameTooLong(limit) ->
      "Keep the name under " <> int.to_string(limit) <> " characters."
  }
}

fn phase_text(phase) -> String {
  case phase {
    Betting -> "the betting phase"
    Insurance -> "insurance"
    Playing -> "play"
    DealerTurn -> "the dealer's turn"
    Settled -> "settling"
  }
}
