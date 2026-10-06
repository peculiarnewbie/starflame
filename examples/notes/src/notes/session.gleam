//// How `Me` is stored in the access token. The API module can't use the
//// generated codecs, because they're generated from it.

import gleam/dynamic/decode.{type Decoder}
import notes/shared.{type Me, Me}
import starflame/plain.{type Plain}

pub fn to_plain(me: Me) -> Plain {
  plain.object([#("id", plain.int(me.id)), #("email", plain.string(me.email))])
}

pub fn decoder() -> Decoder(Me) {
  use id <- decode.field("id", decode.int)
  use email <- decode.field("email", decode.string)
  decode.success(Me(id:, email:))
}
