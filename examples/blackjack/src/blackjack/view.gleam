//// Builds one player's view of the table. The dealer's hole card and the
//// legal moves are per-player, so the server sends a different view to each
//// subscriber.

import gleam/list
import gleam/option.{type Option, None, Some}
import blackjack/engine
import blackjack/shared as s

pub fn of(state: s.State, player_id: String) -> s.View {
  let me = player_by_id(state.players, player_id)
  let current_player_id =
    case at(state.players, state.current_player_index) {
      Ok(player) -> player.id
      Error(_) -> ""
    }
  let is_my_turn = state.phase == s.Playing && current_player_id == player_id
  let current_hand = case me, is_my_turn {
    Some(player), True -> at(player.hands, player.current_hand_index)
    _, _ -> Error(Nil)
  }
  let #(can_hit, can_double, can_split) = case me, current_hand {
    Some(player), Ok(hand) ->
      case is_my_turn && !engine.is_hand_done(hand) {
        True ->
          #(
            True,
            engine.can_double(player, hand),
            engine.can_split(player, hand),
          )
        False -> #(False, False, False)
      }
    _, _ -> #(False, False, False)
  }
  let needs_bet = case me {
    Some(player) -> state.phase == s.Betting && player.bet == 0 && !player.done
    None -> False
  }
  let needs_insurance = case me {
    Some(player) ->
      state.phase == s.Insurance && !player.insurance_decided && !player.done
    None -> False
  }
  let #(dealer_value, dealer_busted) = case state.dealer_revealed {
    True -> {
      let value = engine.hand_value(state.dealer_hand).0
      #(Some(value), value > 21)
    }
    False -> #(None, False)
  }
  s.View(
    phase: state.phase,
    round_number: state.round_number,
    my_id: player_id,
    dealer: s.DealerView(
      cards: dealer_cards(state),
      value: dealer_value,
      up_card_value: up_card_value(state.dealer_hand),
      busted: dealer_busted,
    ),
    players: list.map(state.players, player_view),
    current_player_index: state.current_player_index,
    results: state.results,
    shoe_count: list.length(state.shoe),
    can_hit: can_hit,
    can_stand: can_hit,
    can_double: can_double,
    can_split: can_split,
    is_my_turn: is_my_turn,
    needs_bet: needs_bet,
    needs_insurance: needs_insurance,
  )
}

pub fn all(state: s.State) -> List(#(String, s.View)) {
  list.map(state.players, fn(player) { #(player.id, of(state, player.id)) })
}

fn dealer_cards(state: s.State) -> List(s.DealerCard) {
  list.index_map(state.dealer_hand, fn(card, index) {
    case index == 1 && !state.dealer_revealed {
      True -> s.Hidden
      False -> s.Shown(card)
    }
  })
}

fn up_card_value(cards: List(s.Card)) -> Option(Int) {
  case cards {
    [up, ..] -> Some(engine.hand_value([up]).0)
    [] -> None
  }
}

fn player_view(player: s.Player) -> s.PlayerView {
  s.PlayerView(
    id: player.id,
    name: player.name,
    chips: player.chips,
    hands: list.map(player.hands, hand_view),
    current_hand_index: player.current_hand_index,
    done: player.done,
    bet: player.bet,
    insurance_bet: player.insurance_bet,
    insurance_decided: player.insurance_decided,
  )
}

fn hand_view(hand: s.Hand) -> s.HandView {
  let #(value, soft) = engine.hand_value(hand.cards)
  s.HandView(
    cards: hand.cards,
    bet: hand.bet,
    doubled: hand.doubled,
    stood: hand.stood,
    busted: hand.busted,
    is_blackjack: hand.is_blackjack,
    value: value,
    soft: soft,
  )
}

fn player_by_id(players: List(s.Player), player_id: String) -> Option(s.Player) {
  case list.find(players, fn(player) { player.id == player_id }) {
    Ok(player) -> Some(player)
    Error(_) -> None
  }
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
