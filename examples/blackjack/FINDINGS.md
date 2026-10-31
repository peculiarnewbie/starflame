# What building this found

Notes from porting the `party` blackjack engine into a Starflame app. These are
runtime and DX gaps, not bugs in this example.

## What went well

- **The pure engine ported almost mechanically.** Gleam's custom types and
  exhaustive `case` map directly onto the TypeScript union types. `Result` and
  `Option` replaced the `{ type: "..." }` action/result objects without ceremony.
- **Deeply nested wire types worked first time.** A `View` containing
  `Option(List(RoundResult))`, nested hands, and an enum with zero-field
  variants (`Shown`/`Hidden`) generated correct encoders, decoders, and
  fast-decode kinds. This is the part most likely to break and it didn't.
- **Sync RPC methods are fine.** `join`/`act` return plain values (not Promises)
  and Cap'n Web handles them. Only `subscribe` needed a Promise.
- **Typed errors crossed the wire well.** `GameError` variants arrive in the
  client as real constructors, so `WrongPhase`, `NotYourTurn`, and friends are
  matched exhaustively in the UI.

## Gaps

### 1. Codecs are only generated for API-reachable types — fixed

This originally forced a `dump()` RPC method purely to make the kit emit
`state_to_plain` / `state_from_plain`. The kit now has a `codecs` command:

```toml
[starflame]
codecs = ["blackjack/shared:blackjack/codecs"]
```

```sh
gleam run -m starflame_rpc_kit -- codecs        # every configured entry
gleam run -m starflame_rpc_kit -- check
```

It emits `<snake>_to_plain`, `<snake>_decoder`, `<snake>_from_plain` and
`<snake>_kind` for every public type in the module, in dependency order, and
the Vite plugin regenerates it in dev and checks it in a build. The `dump()`
method is gone.

**Remaining caveat:** the bootstrap problem is unchanged. If a stale codecs
file no longer compiles, `gleam run` can fail before it gets a chance to
regenerate. The kit documents this; the fix is a compiler-level concern.

### 2. The API module can't import generated code — resolved by #1

With codecs in `src/blackjack/codecs.gleam` (not under the RPC output
directory), `api.gleam` can import `store.gleam`, and `store` imports the
codecs. Persistence, serialization, and typed view fanout now live in Gleam.
`room.ts` binds identity and serves the generated target directly.

Before: `room.ts` sequenced load → call → save → broadcast and carried a
state handle through `env`. After: the API owns D1 entirely; the Durable Object
is a coordinator. This is the pattern the todo example should have shown.

The handwritten `TableApi` wrapper and its `all_views()` helper are removed.
`blackjack/events.gleam` filters typed views per player, `server.serialise`
orders asynchronous reads and writes, and generated targets own callback
retention and subscription disposal.

### 3. No typed way to carry call scope

`Context` carries `env`, `execution`, and `auth`. With persistence moved into
the API, the Durable Object no longer needs to hand state in — but it does need
to say *which table* and *which player* a call is for. That now travels in
`auth`:

```ts
newApi(this.env, this.ctx, { player, table: this.tableName })
```

and Gleam decodes it:

```gleam
fn identity_decoder() -> decode.Decoder(#(String, String)) {
  use player <- decode.field("player", decode.string)
  use table <- decode.field("table", decode.string)
  decode.success(#(player, table))
}
```

It works and removes the raw `env` stuffing, but `auth` is `Dynamic` and
unnamed: nothing distinguishes "the verified user" from "the table this call is
scoped to". Overloading it is a convention, not a contract.

**Suggestion:** either a documented `server.auth` payload convention, or a small
typed slot (`Context.local`) for non-user scope. The point is to stop
multiplying ad-hoc JSON payloads in `auth`.

### 4. No notion of "who is calling" — worked around here

Originally any connected client could call `act` with another player's id. The
example now issues a session token from `GET /session`, derives a public player
id from its hash, passes it to `newApi` as `auth`, and never accepts a player id
in a call. Actions no longer carry one, so impersonation is structurally
impossible.

That is the pattern a framework should ship, and it now has a helper:
`@starflame/runtime/session.ts` issues tokens, reads them back, and derives the
player id, so apps no longer copy that code. What remains demo-grade is the
token itself: a bearer credential in `localStorage`, no HttpOnly cookie, no
expiry or rotation.

**Suggestion:** a cookie-based mode with rotation and expiry, and a documented
answer for "the socket outlives the token".

### 5. Per-subscriber views are manual

Blackjack needs a different payload per player. The runtime gives you callbacks,
but you keep your own `Map<playerId, Set<listener>>` and fan out yourself. That
was ~25 lines in `room.ts`; a `starflame/server` subscription registry
(subscribe by key, publish by key) would remove a repeated pattern from every
live app.

### 6. Route configuration is duplicated and wildcards are unverified

`worker.ts` matches `"/rpc"` and `cloudflare.config.ts` repeats `runWorkerFirst:
["/rpc"]`. The todo example repeats a three-path list in both places. A wildcard
(`/t/*`) is what you'd want for per-table URLs; I sidestepped it with
`/rpc?table=<id>` because wildcard behaviour in `runWorkerFirst` isn't
documented.

**Suggestion:** derive `runWorkerFirst` from the worker's route table, or support
one declarative route list.

### 7. Lustre: `on_click` vs `on_submit` differ

`event.on_click(msg)` takes a value; `event.on_submit(fn(_) { msg })` takes a
function. Easy to get wrong, and the error message (`Element(fn(b) -> Msg)`)
doesn't point at the mistake. Minor, but it cost a compile cycle.

## Verdict

The engine port was genuinely pleasant, and the codec layer held up under a much
more complex type graph than the existing examples use.

Two of the three real gaps are now closed in the framework:

- **Persisting state** — the `codecs` command made `dump()` unnecessary and let
  the API own D1 end to end.
- **Knowing where server orchestration belongs** — that followed from the same
  fix; the Durable Object is now a coordinator rather than a second backend.

**Identifying the caller** is closed in this example, but not yet in the
framework: the session pattern is sound, yet every app still has to write it,
and the token handling is demo-grade. The subscription registry and generated
callback lifecycle now remove the old `all_views` workaround.
