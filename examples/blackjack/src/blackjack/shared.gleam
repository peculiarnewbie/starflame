//// Types shared by the engine, the RPC API, and the browser.

import gleam/option.{type Option}

pub const starting_chips = 1000
pub const min_bet = 10
pub const max_bet = 500
pub const deck_count = 6
pub const max_splits = 3
pub const max_players = 6

/// Below this many cards, a new round reshuffles the shoe.
pub const shuffle_threshold = 78

pub type Suit {
  Spade
  Heart
  Diamond
  Club
}

pub type Card {
  Card(suit: Suit, rank: Int)
}

pub type Phase {
  Betting
  Insurance
  Playing
  DealerTurn
  Settled
}

pub type Hand {
  Hand(
    cards: List(Card),
    bet: Int,
    doubled: Bool,
    stood: Bool,
    busted: Bool,
    is_blackjack: Bool,
    from_split: Bool,
  )
}

pub type Player {
  Player(
    id: String,
    name: String,
    chips: Int,
    hands: List(Hand),
    current_hand_index: Int,
    bet: Int,
    insurance_bet: Int,
    insurance_decided: Bool,
    done: Bool,
  )
}

pub type State {
  State(
    players: List(Player),
    shoe: List(Card),
    burn_pile: List(Card),
    dealer_hand: List(Card),
    dealer_revealed: Bool,
    current_player_index: Int,
    phase: Phase,
    round_number: Int,
    deck_count: Int,
    cut_card_position: Int,
    results: Option(List(RoundResult)),
    seed: Int,
  )
}

pub type Action {
  PlaceBet(amount: Int)
  Hit
  Stand
  DoubleDown
  Split
  TakeInsurance(accept: Bool)
  NewRound
}

pub type GameError {
  PlayerNotFound(player_id: String)
  TableFull(limit: Int)
  NotYourTurn
  WrongPhase(phase: Phase)
  AlreadyBet
  SittingOut
  AlreadyDecided
  HandIsDone
  CannotSplit
  CannotDouble
  CannotStartRound
  EmptyName
  NameTooLong(limit: Int)
}

pub type HandOutcome {
  Blackjack
  Win
  Push
  Lose
  Bust
}

pub type HandResult {
  HandResult(hand_index: Int, bet: Int, payout: Int, outcome: HandOutcome)
}

pub type RoundResult {
  RoundResult(
    player_id: String,
    player_name: String,
    hands: List(HandResult),
    insurance_payout: Int,
    net_chips: Int,
  )
}

// VIEWS -----------------------------------------------------------------------

/// The dealer's hole card stays hidden until the dealer reveals.
pub type DealerCard {
  Shown(card: Card)
  Hidden
}

pub type HandView {
  HandView(
    cards: List(Card),
    bet: Int,
    doubled: Bool,
    stood: Bool,
    busted: Bool,
    is_blackjack: Bool,
    value: Int,
    soft: Bool,
  )
}

pub type PlayerView {
  PlayerView(
    id: String,
    name: String,
    chips: Int,
    hands: List(HandView),
    current_hand_index: Int,
    done: Bool,
    bet: Int,
    insurance_bet: Int,
    insurance_decided: Bool,
  )
}

pub type DealerView {
  DealerView(
    cards: List(DealerCard),
    value: Option(Int),
    up_card_value: Option(Int),
    busted: Bool,
  )
}

/// One player's view of the table. The server builds a separate view for each
/// player, so nobody sees the hole card or another player's legal moves.
pub type View {
  View(
    phase: Phase,
    round_number: Int,
    my_id: String,
    dealer: DealerView,
    players: List(PlayerView),
    current_player_index: Int,
    results: Option(List(RoundResult)),
    shoe_count: Int,
    can_hit: Bool,
    can_stand: Bool,
    can_double: Bool,
    can_split: Bool,
    is_my_turn: Bool,
    needs_bet: Bool,
    needs_insurance: Bool,
  )
}
