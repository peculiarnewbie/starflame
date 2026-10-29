import blackjack/engine
import blackjack/shared as s
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// HELPERS ---------------------------------------------------------------------

fn card(suit: s.Suit, rank: Int) -> s.Card {
  s.Card(suit:, rank:)
}

fn spade(rank: Int) -> s.Card {
  card(s.Spade, rank)
}

fn seat(id: String, chips: Int, bet: Int, cards: List(s.Card)) -> s.Player {
  s.Player(
    id: id,
    name: id,
    chips: chips,
    hands: [
      s.Hand(
        cards: cards,
        bet: bet,
        doubled: False,
        stood: False,
        busted: False,
        is_blackjack: engine.is_natural_blackjack(cards),
        from_split: False,
      ),
    ],
    current_hand_index: 0,
    bet: bet,
    insurance_bet: 0,
    insurance_decided: True,
    done: False,
  )
}

fn table(
  players: List(s.Player),
  dealer: List(s.Card),
  shoe: List(s.Card),
  phase: s.Phase,
) -> s.State {
  table_at(players, dealer, shoe, phase, 0)
}

fn table_at(
  players: List(s.Player),
  dealer: List(s.Card),
  shoe: List(s.Card),
  phase: s.Phase,
  current: Int,
) -> s.State {
  s.State(
    players: players,
    shoe: shoe,
    burn_pile: [],
    dealer_hand: dealer,
    dealer_revealed: False,
    current_player_index: current,
    phase: phase,
    round_number: 1,
    deck_count: 6,
    cut_card_position: 78,
    results: None,
    seed: 1,
  )
}

fn chips(state: s.State, id: String) -> Int {
  let assert Ok(player) = state.players |> list_find(fn(player) { player.id == id })
  player.chips
}

fn list_find(items: List(a), predicate: fn(a) -> Bool) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case predicate(first) {
        True -> Ok(first)
        False -> list_find(rest, predicate)
      }
  }
}

fn hands(state: s.State, id: String) -> List(s.Hand) {
  let assert Ok(player) = state.players |> list_find(fn(player) { player.id == id })
  player.hands
}

// HAND VALUES -----------------------------------------------------------------

pub fn soft_aces_test() {
  engine.hand_value([spade(1), spade(1), spade(9)])
  |> should.equal(#(21, True))
}

pub fn hard_aces_test() {
  engine.hand_value([spade(1), spade(10), spade(10)])
  |> should.equal(#(21, False))
}

pub fn face_cards_count_ten_test() {
  engine.hand_value([spade(11), spade(13), spade(12)])
  |> should.equal(#(30, False))
}

pub fn natural_blackjack_is_two_cards_test() {
  engine.is_natural_blackjack([spade(1), spade(12)]) |> should.be_true
  engine.is_natural_blackjack([spade(7), spade(7), spade(7)]) |> should.be_false
}

// SETTLEMENT ------------------------------------------------------------------

pub fn stand_on_a_push_returns_the_bet_test() {
  let player = seat("ada", 900, 100, [spade(10), spade(13)])
  let state = table([player], [spade(13), spade(10)], [], s.Playing)
  let assert Ok(state) = engine.process(state, "ada", s.Stand)
  state.phase |> should.equal(s.Settled)
  chips(state, "ada") |> should.equal(1000)
}

pub fn blackjack_pays_three_to_two_test() {
  let ada =
    s.Player(
      ..seat("ada", 900, 100, [spade(1), spade(13)]),
      done: True,
    )
  let bob = seat("bob", 900, 100, [spade(10), spade(10)])
  let state =
    table_at([ada, bob], [spade(10), spade(10)], [], s.Playing, 1)
  let assert Ok(state) = engine.process(state, "bob", s.Stand)
  // 100 stake back plus 150 profit.
  chips(state, "ada") |> should.equal(1150)
}

pub fn busted_hand_loses_the_bet_test() {
  let ada =
    s.Player(
      ..seat("ada", 900, 100, [spade(10), spade(10), spade(5)]),
      done: True,
      hands: [
        s.Hand(
          cards: [spade(10), spade(10), spade(5)],
          bet: 100,
          doubled: False,
          stood: False,
          busted: True,
          is_blackjack: False,
          from_split: False,
        ),
      ],
    )
  let bob = seat("bob", 900, 100, [spade(10), spade(9)])
  let state = table_at([ada, bob], [spade(9), spade(10)], [], s.Playing, 1)
  let assert Ok(state) = engine.process(state, "bob", s.Stand)
  chips(state, "ada") |> should.equal(900)
}

pub fn dealer_bust_pays_the_player_test() {
  let player = seat("ada", 900, 100, [spade(10), spade(9)])
  let state = table([player], [spade(10), spade(6)], [spade(10)], s.Playing)
  let assert Ok(state) = engine.process(state, "ada", s.Stand)
  chips(state, "ada") |> should.equal(1100)
}

// ACTIONS ---------------------------------------------------------------------

pub fn hit_busts_and_advances_test() {
  let player = seat("ada", 900, 100, [spade(10), spade(6)])
  let state = table([player], [spade(9), spade(10)], [spade(10)], s.Playing)
  let assert Ok(state) = engine.process(state, "ada", s.Hit)
  let assert [hand] = hands(state, "ada")
  hand.busted |> should.be_true
  state.phase |> should.equal(s.Settled)
}

pub fn double_doubles_the_bet_and_takes_one_card_test() {
  let player = seat("ada", 900, 100, [spade(5), spade(6)])
  let state = table([player], [spade(9), spade(10)], [spade(10)], s.Playing)
  let assert Ok(state) = engine.process(state, "ada", s.DoubleDown)
  let assert [hand] = hands(state, "ada")
  hand.bet |> should.equal(200)
  hand.stood |> should.be_true
  // 800 left after doubling; the 21 wins another 400.
  chips(state, "ada") |> should.equal(1200)
}

pub fn split_makes_two_hands_and_charges_the_bet_test() {
  let player = seat("ada", 900, 100, [spade(10), spade(10)])
  let state = table([player], [spade(9), spade(10)], [spade(5), spade(6)], s.Playing)
  let assert Ok(state) = engine.process(state, "ada", s.Split)
  let hands = hands(state, "ada")
  list.length(hands) |> should.equal(2)
  chips(state, "ada") |> should.equal(800)
}

pub fn split_aces_stand_automatically_test() {
  let player = seat("ada", 900, 100, [spade(1), spade(1)])
  let state = table([player], [spade(9), spade(10)], [spade(5), spade(6)], s.Playing)
  let assert Ok(state) = engine.process(state, "ada", s.Split)
  let assert [first, second] = hands(state, "ada")
  first.stood |> should.be_true
  second.stood |> should.be_true
}

pub fn you_cannot_hit_out_of_turn_test() {
  let ada = seat("ada", 900, 100, [spade(10), spade(6)])
  let bob = seat("bob", 900, 100, [spade(10), spade(6)])
  let state = table([ada, bob], [spade(9), spade(10)], [spade(2)], s.Playing)
  engine.process(state, "bob", s.Hit)
  |> should.equal(Error(s.NotYourTurn))
}

pub fn you_cannot_split_after_hitting_test() {
  let player = seat("ada", 900, 100, [spade(10), spade(10), spade(2)])
  let state = table([player], [spade(9), spade(10)], [spade(5)], s.Playing)
  engine.process(state, "ada", s.Split)
  |> should.equal(Error(s.CannotSplit))
}

// INSURANCE -------------------------------------------------------------------

pub fn insurance_pays_two_to_one_on_dealer_blackjack_test() {
  let player = s.Player(
    ..seat("ada", 900, 100, [spade(10), spade(9)]),
    insurance_decided: False,
  )
  let state = table([player], [spade(1), spade(13)], [], s.Insurance)
  let assert Ok(state) = engine.process(state, "ada", s.TakeInsurance(True))
  state.phase |> should.equal(s.Settled)
  // The 19 loses to the dealer's blackjack, but 3x the 50 insurance stake
  // makes the round a wash.
  chips(state, "ada") |> should.equal(1000)
}

pub fn insurance_loses_on_a_dealer_without_blackjack_test() {
  let player = s.Player(
    ..seat("ada", 900, 100, [spade(10), spade(10)]),
    insurance_decided: False,
  )
  let state = table([player], [spade(1), spade(8)], [spade(2)], s.Insurance)
  let assert Ok(state) = engine.process(state, "ada", s.TakeInsurance(True))
  let assert Ok(state) = engine.process(state, "ada", s.Stand)
  // 20 beats the dealer's 19: 2x100 back, and the 50 insurance bet is lost.
  chips(state, "ada") |> should.equal(1050)
}
