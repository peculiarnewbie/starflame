//// The blackjack rules: a pure state machine.
////
//// Ported from the TypeScript engine in /home/user/git/party. Every function
//// here is deterministic given the seed, and the shoe is part of the state, so
//// a table can be rebuilt from JSON and tested without mocking.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import blackjack/shared as s

pub fn empty_table(name: String) -> s.State {
  let seed = seed_from(name)
  let #(shoe, seed) = shuffle(deck_cards(s.deck_count), seed)
  s.State(
    players: [],
    shoe: shoe,
    burn_pile: [],
    dealer_hand: [],
    dealer_revealed: False,
    current_player_index: 0,
    phase: s.Betting,
    round_number: 1,
    deck_count: s.deck_count,
    cut_card_position: s.shuffle_threshold,
    results: None,
    seed: seed,
  )
}

/// Adds a player, or renames one already seated. A player who joins after the
/// cards are out sits out until the next round.
pub fn seat(
  state: s.State,
  player_id: String,
  name: String,
) -> Result(s.State, s.GameError) {
  let name = string.trim(name)
  case string.length(name) {
    0 -> Error(s.EmptyName)
    length if length > 24 -> Error(s.NameTooLong(24))
    _ ->
      case player_index(state.players, player_id) {
        Ok(index) -> {
          let player = player_at(state.players, index)
          Ok(set_player(state, index, s.Player(..player, name:)))
        }
        Error(_) ->
          case list.length(state.players) >= s.max_players {
            True -> Error(s.TableFull(s.max_players))
            False ->
              Ok(
                s.State(
                  ..state,
                  players: list.append(state.players, [
                    s.Player(
                      id: player_id,
                      name: name,
                      chips: s.starting_chips,
                      hands: [],
                      current_hand_index: 0,
                      bet: 0,
                      insurance_bet: 0,
                      insurance_decided: False,
                      done: state.phase != s.Betting,
                    ),
                  ]),
                ),
              )
          }
      }
  }
}

// RULES -----------------------------------------------------------------------

/// The value of a hand and whether it is soft (an ace still counts as 11).
pub fn hand_value(cards: List(s.Card)) -> #(Int, Bool) {
  let #(total, aces) =
    list.fold(cards, #(0, 0), fn(acc, card) {
      let #(total, aces) = acc
      case card.rank {
        1 -> #(total + 11, aces + 1)
        rank if rank >= 11 -> #(total + 10, aces)
        rank -> #(total + rank, aces)
      }
    })
  reduce_aces(total, aces)
}

fn reduce_aces(total: Int, aces: Int) -> #(Int, Bool) {
  case total > 21 && aces > 0 {
    True -> reduce_aces(total - 10, aces - 1)
    False -> #(total, aces > 0)
  }
}

pub fn is_natural_blackjack(cards: List(s.Card)) -> Bool {
  list.length(cards) == 2 && hand_value(cards).0 == 21
}

pub fn is_hand_done(hand: s.Hand) -> Bool {
  hand.stood || hand.busted || hand.is_blackjack
}

pub fn can_split(player: s.Player, hand: s.Hand) -> Bool {
  case hand.cards {
    [first, second] ->
      list.length(player.hands) - 1 < s.max_splits
      && split_rank(first) == split_rank(second)
      && player.chips >= hand.bet
    _ -> False
  }
}

fn split_rank(card: s.Card) -> Int {
  case card.rank >= 11 {
    True -> 10
    False -> card.rank
  }
}

pub fn can_double(player: s.Player, hand: s.Hand) -> Bool {
  list.length(hand.cards) == 2 && player.chips >= hand.bet
}

// ACTIONS ---------------------------------------------------------------------

pub fn process(
  state: s.State,
  player_id: String,
  action: s.Action,
) -> Result(s.State, s.GameError) {
  case action {
    s.PlaceBet(amount) -> place_bet(state, player_id, amount)
    s.Hit -> turn_action(state, player_id, hit)
    s.Stand -> turn_action(state, player_id, stand)
    s.DoubleDown -> turn_action(state, player_id, double_down)
    s.Split -> turn_action(state, player_id, split)
    s.TakeInsurance(accept) -> insurance(state, player_id, accept)
    s.NewRound -> new_round(state)
  }
}

fn place_bet(
  state: s.State,
  player_id: String,
  amount: Int,
) -> Result(s.State, s.GameError) {
  case state.phase {
    s.Betting ->
      case player_index(state.players, player_id) {
        Error(_) -> Error(s.PlayerNotFound(player_id))
        Ok(index) -> {
          let player = player_at(state.players, index)
          case player.done, player.bet > 0 {
            True, _ -> Error(s.SittingOut)
            _, True -> Error(s.AlreadyBet)
            False, False -> {
              let amount =
                int.max(
                  s.min_bet,
                  int.min(s.max_bet, int.min(amount, player.chips)),
                )
              let player =
                s.Player(..player, bet: amount, chips: player.chips - amount)
              let state = set_player(state, index, player)
              case all_active_bet(state.players) {
                True -> deal(state)
                False -> Ok(state)
              }
            }
          }
        }
      }
    _ -> Error(s.WrongPhase(state.phase))
  }
}

fn deal(state: s.State) -> Result(s.State, s.GameError) {
  let #(_, state) = draw(state)
  let #(players, state) =
    list.fold(state.players, #([], state), fn(acc, player) {
      let #(players, state) = acc
      case player.done {
        True -> #([player, ..players], state)
        False -> {
          let #(first, state) = draw(state)
          let #(second, state) = draw(state)
          let hand =
            s.Hand(
              cards: [first, second],
              bet: player.bet,
              doubled: False,
              stood: False,
              busted: False,
              is_blackjack: is_natural_blackjack([first, second]),
              from_split: False,
            )
          #(
            [
              s.Player(..player, hands: [hand], current_hand_index: 0),
              ..players
            ],
            state,
          )
        }
      }
    })
  let #(up, state) = draw(state)
  let #(hole, state) = draw(state)
  let state =
    s.State(
      ..state,
      players: list.reverse(players),
      dealer_hand: [up, hole],
      dealer_revealed: False,
    )
  case up.rank {
    1 -> Ok(s.State(..state, phase: s.Insurance))
    _ -> {
      let up_value = hand_value([up]).0
      case up_value == 10 && is_natural_blackjack(state.dealer_hand) {
        True -> Ok(settle(s.State(..state, dealer_revealed: True)))
        False -> Ok(start_playing(state))
      }
    }
  }
}

fn insurance(
  state: s.State,
  player_id: String,
  accept: Bool,
) -> Result(s.State, s.GameError) {
  case state.phase {
    s.Insurance ->
      case player_index(state.players, player_id) {
        Error(_) -> Error(s.PlayerNotFound(player_id))
        Ok(index) -> {
          let player = player_at(state.players, index)
          case player.done, player.insurance_decided {
            True, _ -> Error(s.SittingOut)
            _, True -> Error(s.AlreadyDecided)
            False, False -> {
              let player = case accept {
                True -> {
                  let amount = player.bet / 2
                  case player.chips >= amount {
                    True ->
                      s.Player(
                        ..player,
                        insurance_bet: amount,
                        chips: player.chips - amount,
                      )
                    False -> player
                  }
                }
                False -> player
              }
              let player = s.Player(..player, insurance_decided: True)
              let state = set_player(state, index, player)
              case all_insurance_decided(state.players) {
                False -> Ok(state)
                True ->
                  case is_natural_blackjack(state.dealer_hand) {
                    True ->
                      Ok(settle(s.State(..state, dealer_revealed: True)))
                    False -> Ok(start_playing(state))
                  }
              }
            }
          }
        }
      }
    _ -> Error(s.WrongPhase(state.phase))
  }
}

fn start_playing(state: s.State) -> s.State {
  let players =
    list.map(state.players, fn(player) {
      case player.hands {
        [hand] ->
          case player.done || hand.is_blackjack {
            True -> s.Player(..player, done: True)
            False -> player
          }
        _ -> player
      }
    })
  let state = s.State(..state, players: players, phase: s.Playing)
  case first_active_index(players, 0) {
    Ok(index) -> s.State(..state, current_player_index: index)
    Error(_) -> settle(dealer_play(state))
  }
}

fn turn_action(
  state: s.State,
  player_id: String,
  apply: fn(s.State, s.Player, s.Hand) -> Result(s.State, s.GameError),
) -> Result(s.State, s.GameError) {
  case state.phase {
    s.Playing ->
      case player_index(state.players, player_id) {
        Error(_) -> Error(s.PlayerNotFound(player_id))
        Ok(index) ->
          case index == state.current_player_index {
            False -> Error(s.NotYourTurn)
            True -> {
              let player = player_at(state.players, index)
              case at(player.hands, player.current_hand_index) {
                Error(_) -> Error(s.HandIsDone)
                Ok(hand) ->
                  case is_hand_done(hand) {
                    True -> Error(s.HandIsDone)
                    False -> apply(state, player, hand)
                  }
              }
            }
          }
      }
    _ -> Error(s.WrongPhase(state.phase))
  }
}

fn hit(
  state: s.State,
  player: s.Player,
  hand: s.Hand,
) -> Result(s.State, s.GameError) {
  let #(card, state) = draw(state)
  let cards = list.append(hand.cards, [card])
  let value = hand_value(cards).0
  let hand = case value > 21, value == 21 {
    True, _ -> s.Hand(..hand, cards:, busted: True)
    _, True -> s.Hand(..hand, cards:, stood: True)
    _, _ -> s.Hand(..hand, cards:)
  }
  let state = replace_hand(state, player, hand)
  case value >= 21 {
    True -> Ok(advance_to_next_hand(state))
    False -> Ok(state)
  }
}

fn stand(
  state: s.State,
  player: s.Player,
  hand: s.Hand,
) -> Result(s.State, s.GameError) {
  let state = replace_hand(state, player, s.Hand(..hand, stood: True))
  Ok(advance_to_next_hand(state))
}

fn double_down(
  state: s.State,
  player: s.Player,
  hand: s.Hand,
) -> Result(s.State, s.GameError) {
  case can_double(player, hand) {
    False -> Error(s.CannotDouble)
    True -> {
      let #(card, state) = draw(state)
      let cards = list.append(hand.cards, [card])
      let value = hand_value(cards).0
      let player = s.Player(..player, chips: player.chips - hand.bet)
      let hand =
        s.Hand(
          ..hand,
          cards: cards,
          bet: hand.bet * 2,
          doubled: True,
          stood: True,
          busted: value > 21,
        )
      let state = replace_hand(state, player, hand)
      Ok(advance_to_next_hand(state))
    }
  }
}

fn split(
  state: s.State,
  player: s.Player,
  hand: s.Hand,
) -> Result(s.State, s.GameError) {
  case can_split(player, hand), hand.cards {
    False, _ -> Error(s.CannotSplit)
    True, [first, second] -> {
      let splitting_aces = first.rank == 1
      let #(first_card, state) = draw(state)
      let #(second_card, state) = draw(state)
      let first_hand =
        s.Hand(
          cards: [first, first_card],
          bet: hand.bet,
          doubled: False,
          stood: splitting_aces,
          busted: False,
          is_blackjack: False,
          from_split: True,
        )
      let second_hand =
        s.Hand(
          cards: [second, second_card],
          bet: hand.bet,
          doubled: False,
          stood: splitting_aces,
          busted: False,
          is_blackjack: False,
          from_split: True,
        )
      let first_hand = maybe_stand(first_hand)
      let second_hand = maybe_stand(second_hand)
      let hands =
        replace_at(
          player.hands,
          player.current_hand_index,
          [first_hand, second_hand],
        )
      let player =
        s.Player(..player, chips: player.chips - hand.bet, hands: hands)
      let state = set_player(state, state.current_player_index, player)
      case is_hand_done(first_hand) {
        True -> Ok(advance_to_next_hand(state))
        False -> Ok(state)
      }
    }
    True, _ -> Error(s.CannotSplit)
  }
}

fn maybe_stand(hand: s.Hand) -> s.Hand {
  case hand.stood, hand_value(hand.cards).0 == 21 {
    True, _ -> hand
    _, True -> s.Hand(..hand, stood: True)
    _, _ -> hand
  }
}

fn new_round(state: s.State) -> Result(s.State, s.GameError) {
  case state.phase {
    s.Settled -> {
      let #(state, shoe) =
        case list.length(state.shoe) < state.cut_card_position {
          True -> {
            let #(shoe, seed) =
              shuffle(deck_cards(state.deck_count), next_seed(state.seed))
            #(s.State(..state, seed: seed), shoe)
          }
          False -> #(state, state.shoe)
        }
      let players =
        list.map(state.players, fn(player) {
          s.Player(
            ..player,
            hands: [],
            current_hand_index: 0,
            bet: 0,
            insurance_bet: 0,
            insurance_decided: False,
            done: player.chips < s.min_bet,
          )
        })
      Ok(
        s.State(
          ..state,
          players: players,
          shoe: shoe,
          burn_pile: [],
          dealer_hand: [],
          dealer_revealed: False,
          current_player_index: 0,
          phase: s.Betting,
          round_number: state.round_number + 1,
          results: None,
        ),
      )
    }
    _ -> Error(s.CannotStartRound)
  }
}

// TURN ORDER ------------------------------------------------------------------

fn advance_to_next_hand(state: s.State) -> s.State {
  case at(state.players, state.current_player_index) {
    Error(_) -> state
    Ok(player) -> {
      let next = player.current_hand_index + 1
      case next < list.length(player.hands) {
        True -> {
          let state =
            set_player(
              state,
              state.current_player_index,
              s.Player(..player, current_hand_index: next),
            )
          case at(player.hands, next) {
            Ok(hand) ->
              case is_hand_done(hand) {
                True -> advance_to_next_hand(state)
                False -> state
              }
            Error(_) -> state
          }
        }
        False -> {
          let state =
            set_player(
              state,
              state.current_player_index,
              s.Player(..player, done: True),
            )
          advance_to_next_player(state)
        }
      }
    }
  }
}

fn advance_to_next_player(state: s.State) -> s.State {
  case first_active_index(state.players, state.current_player_index + 1) {
    Ok(index) -> s.State(..state, current_player_index: index)
    Error(_) -> settle(dealer_play(state))
  }
}

fn dealer_play(state: s.State) -> s.State {
  let state = s.State(..state, dealer_revealed: True, phase: s.DealerTurn)
  case
    list.any(state.players, fn(player) {
      list.any(player.hands, fn(hand) { !hand.busted })
    })
  {
    False -> state
    True -> dealer_draw(state)
  }
}

fn dealer_draw(state: s.State) -> s.State {
  let #(value, soft) = hand_value(state.dealer_hand)
  case value > 21 || value > 17 || value == 17 && !soft {
    True -> state
    False -> {
      let #(card, state) = draw(state)
      dealer_draw(
        s.State(..state, dealer_hand: list.append(state.dealer_hand, [card])),
      )
    }
  }
}

// SETTLEMENT ------------------------------------------------------------------

fn settle(state: s.State) -> s.State {
  let dealer_value = hand_value(state.dealer_hand).0
  let dealer_busted = dealer_value > 21
  let dealer_blackjack = is_natural_blackjack(state.dealer_hand)
  let #(players, results) =
    list.fold(state.players, #([], []), fn(acc, player) {
      let #(players, results) = acc
      let #(hand_results, total_payout) =
        settle_hands(
          player.hands,
          0,
          dealer_value,
          dealer_blackjack,
          dealer_busted,
          [],
          0,
        )
      let insurance_payout = case dealer_blackjack {
        True -> player.insurance_bet * 3
        False -> 0
      }
      let total_bet =
        list.fold(player.hands, player.insurance_bet, fn(total, hand) {
          total + hand.bet
        })
      let net = total_payout + insurance_payout - total_bet
      let player =
        s.Player(..player, chips: player.chips + total_payout + insurance_payout)
      #(
        [player, ..players],
        [
          s.RoundResult(
            player_id: player.id,
            player_name: player.name,
            hands: list.reverse(hand_results),
            insurance_payout: insurance_payout,
            net_chips: net,
          ),
          ..results
        ],
      )
    })
  s.State(
    ..state,
    players: list.reverse(players),
    dealer_revealed: True,
    phase: s.Settled,
    results: Some(list.reverse(results)),
  )
}

fn settle_hands(
  hands: List(s.Hand),
  index: Int,
  dealer_value: Int,
  dealer_blackjack: Bool,
  dealer_busted: Bool,
  results: List(s.HandResult),
  payout: Int,
) -> #(List(s.HandResult), Int) {
  case hands {
    [] -> #(results, payout)
    [hand, ..rest] -> {
      let #(outcome, hand_payout) =
        settle_hand(hand, dealer_value, dealer_blackjack, dealer_busted)
      settle_hands(
        rest,
        index + 1,
        dealer_value,
        dealer_blackjack,
        dealer_busted,
        [
          s.HandResult(
            hand_index: index,
            bet: hand.bet,
            payout: hand_payout,
            outcome: outcome,
          ),
          ..results
        ],
        payout + hand_payout,
      )
    }
  }
}

fn settle_hand(
  hand: s.Hand,
  dealer_value: Int,
  dealer_blackjack: Bool,
  dealer_busted: Bool,
) -> #(s.HandOutcome, Int) {
  let value = hand_value(hand.cards).0
  case hand.busted {
    True -> #(s.Bust, 0)
    False ->
      case hand.is_blackjack, dealer_blackjack {
        True, False -> #(s.Blackjack, hand.bet + hand.bet * 3 / 2)
        True, True -> #(s.Push, hand.bet)
        False, True -> #(s.Lose, 0)
        False, False ->
          case dealer_busted {
            True -> #(s.Win, hand.bet * 2)
            False ->
              case value > dealer_value, value == dealer_value {
                True, _ -> #(s.Win, hand.bet * 2)
                _, True -> #(s.Push, hand.bet)
                _, _ -> #(s.Lose, 0)
              }
          }
      }
  }
}

// SHOE ------------------------------------------------------------------------

fn draw(state: s.State) -> #(s.Card, s.State) {
  case state.shoe {
    [card, ..rest] -> #(card, s.State(..state, shoe: rest))
    [] -> {
      let #(shoe, seed) =
        shuffle(deck_cards(state.deck_count), next_seed(state.seed))
      case shoe {
        [card, ..rest] -> #(card, s.State(..state, shoe: rest, seed: seed))
        [] -> panic as "shoe is empty"
      }
    }
  }
}

fn deck_cards(count: Int) -> List(s.Card) {
  let suits = [s.Spade, s.Heart, s.Diamond, s.Club]
  let deck =
    list.flat_map(suits, fn(suit) {
      list.map(range(1, 13), fn(rank) { s.Card(suit:, rank:) })
    })
  list.flat_map(range(1, count), fn(_) { deck })
}

/// A deterministic Fisher-Yates substitute: give every card a pseudo-random
/// key and sort. Ties are vanishingly unlikely with a 31-bit key.
fn shuffle(cards: List(s.Card), seed: Int) -> #(List(s.Card), Int) {
  let #(keyed, seed) =
    list.fold(cards, #([], seed), fn(acc, card) {
      let #(items, seed) = acc
      let seed = next_seed(seed)
      #([#(seed, card), ..items], seed)
    })
  let sorted = list.sort(keyed, fn(a, b) { int.compare(a.0, b.0) })
  #(list.map(sorted, fn(pair) { pair.1 }), seed)
}

/// A 31-bit linear congruential generator, small enough to keep the whole shoe
/// in state and replay a table exactly.
fn next_seed(seed: Int) -> Int {
  int.max(1, { seed * 48271 } % 2_147_483_647)
}

fn seed_from(name: String) -> Int {
  let seed =
    list.fold(string.to_utf_codepoints(name), 7, fn(acc, codepoint) {
      { acc * 31 + string.utf_codepoint_to_int(codepoint) } % 2_147_483_647
    })
  int.max(1, seed)
}

// COLLECTION HELPERS ----------------------------------------------------------

fn player_index(players: List(s.Player), player_id: String) -> Result(Int, Nil) {
  players
  |> list.index_map(fn(player, index) { #(player.id, index) })
  |> list.find(fn(pair) { pair.0 == player_id })
  |> result.map(fn(pair) { pair.1 })
}

fn player_at(players: List(s.Player), index: Int) -> s.Player {
  case at(players, index) {
    Ok(player) -> player
    Error(_) -> panic as "player index out of bounds"
  }
}

fn set_player(state: s.State, index: Int, player: s.Player) -> s.State {
  s.State(
    ..state,
    players: list.index_map(state.players, fn(existing, i) {
      case i == index {
        True -> player
        False -> existing
      }
    }),
  )
}

fn replace_hand(state: s.State, player: s.Player, hand: s.Hand) -> s.State {
  let hands = replace_at(player.hands, player.current_hand_index, [hand])
  set_player(
    state,
    state.current_player_index,
    s.Player(..player, hands: hands),
  )
}

fn replace_at(items: List(a), index: Int, replacements: List(a)) -> List(a) {
  items
  |> list.index_map(fn(item, i) { #(item, i) })
  |> list.flat_map(fn(pair) {
    case pair.1 == index {
      True -> replacements
      False -> [pair.0]
    }
  })
}

fn first_active_index(players: List(s.Player), from: Int) -> Result(Int, Nil) {
  players
  |> list.index_map(fn(player, index) { #(player, index) })
  |> list.find(fn(pair) { pair.1 >= from && !pair.0.done })
  |> result.map(fn(pair) { pair.1 })
}

fn all_active_bet(players: List(s.Player)) -> Bool {
  list.all(players, fn(player) { player.done || player.bet > 0 })
}

fn all_insurance_decided(players: List(s.Player)) -> Bool {
  list.all(players, fn(player) { player.done || player.insurance_decided })
}

fn at(items: List(a), index: Int) -> Result(a, Nil) {
  case index < 0, items {
    True, _ -> Error(Nil)
    _, [] -> Error(Nil)
    _, [first, ..rest] ->
      case index {
        0 -> Ok(first)
        _ -> at(rest, index - 1)
      }
  }
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
