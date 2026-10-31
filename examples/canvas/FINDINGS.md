# Typed capability contract

Canvas now serves the generated API directly. The earlier handwritten
capability tree and independently supplied client decoders have been removed.

- `canvas/api.gleam` declares and implements `Board` and `BoardView`.
- `enter` returns an editor; `watch` returns a viewer with no edit methods.
- `starflame/topic` carries typed events inside the Durable Object.
- Generated targets retain callback stubs and release them on disposal.
- `server.with_dispose` ties subscription cleanup to capability ownership.
- UI helpers wrap generated handles; they specify no RPC names or decoders.

The Clear regression is covered at both boundaries: a mismatched implementation
fails Gleam checking, a changed API invalidates generated code, and after
regeneration a caller expecting the previous return type fails checking.
The Miniflare suite also runs Clear through the generated Gleam client.

Returning nested capabilities inside data records remains unsupported. This
example uses two direct capability-returning methods and keeps the read-only
object’s restricted shape. Network failures and older independently deployed
clients remain runtime concerns.
