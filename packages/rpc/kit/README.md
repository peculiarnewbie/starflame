# starflame_rpc_kit

Generates the RPC code between a Gleam API module and its clients: wire
codecs, server dispatchers, Cap'n Web targets and typed client functions. Add
it as a dev dependency and run it from the app's directory:

```toml
[dev-dependencies]
starflame_rpc_kit = { path = "../../packages/rpc/kit" }
```

```sh
gleam run -m starflame_rpc_kit -- generate
gleam run -m starflame_rpc_kit -- check
```

By default the API is `src/<app>/api.gleam` and the code goes to
`src/<app>/generated/`. Use `--api todos/rpc` and `--out todos/rpc_generated`
to change them, and pass the same flags to `check`, which fails when the
generated code is missing or out of date.

With [`@starflame/vite`](../../vite), the dev server runs `generate` when the
API module or a module it imports changes, and production builds run `check`.
The kit lists those modules in `build/starflame_rpc_kit/sources.json` for it.

## Type guarantee

The server API is the single source for method arguments, replies, callbacks,
and capability methods. Generated dispatchers call the checked implementation;
generated client functions expose those same types to application code.
`check` rejects missing or stale generated code, including changed capability
return types. Equivalent Gleam formatting is accepted across compiler versions.
After regeneration, a caller expecting the old type fails Gleam checking.

This guarantee applies to generated calls built against the same API. Handwritten
RPC names, decoders, JavaScript assertions, and custom transport methods cannot
establish that connection. The raw primitives live in `starflame/unsafe_rpc` for
explicit interoperability; application clients should not use them.

Generated capabilities support server-side effects directly in their Gleam
functions. Use `starflame/topic` to publish typed events, and
`server.with_dispose` to close a capability's subscriptions. Its received
callback stubs remain alive until the generated target is disposed. Returning
the same capability value through multiple targets keeps its resources alive
until the last target releases it. Cleanup functions must be synchronous.

Gleam checking concerns one build's types. Network failures and independently
deployed client/server versions still need runtime decoding and error handling.

## Standalone state codecs

Generate codecs for all public types defined in a module, without adding an
RPC method returning them:

```sh
gleam run -m starflame_rpc_kit -- codecs todos/state --out todos/state_codecs
```

This writes `src/todos/state_codecs.gleam`. Each type gets `<snake>_to_plain`,
`<snake>_decoder`, `<snake>_from_plain` and `<snake>_kind`, using the same
writer and representation as RPC `wire.gleam`. Dependencies on the app's
other public types are included transitively, in dependency order. Recursive
types use lazy kind references. Types with the same name in different
modules get a module alias prefix, just as in `wire.gleam`.

For automatic generation, add module/output pairs to the app's `gleam.toml`:

```toml
[starflame]
codecs = ["todos/state:todos/state_codecs", "todos/history:todos/history_codecs"]
```

```sh
gleam run -m starflame_rpc_kit -- codecs # Generate every configured entry.
gleam run -m starflame_rpc_kit -- check  # Check RPC code and configured codecs.
```

Paths are Gleam module paths without `src/` or `.gleam`. Outputs must be
distinct and cannot overwrite their input module. The one-off form ignores
configured entries; only configured outputs participate in `check`. With no
configured entries, `codecs` succeeds without writing anything.

Opaque/external types, types with any type parameters (including phantom
parameters), capabilities and function fields are rejected with an error
naming the type or field. The other wire type restrictions also apply.
Public functions in the types module are ignored. Unlike an RPC API module,
the types module itself can define the data types being encoded.

The Vite plugin runs `generate`, then `codecs`, then `gleam build` during dev,
and watches the dependencies of both RPC and codecs modules, plus
`gleam.toml`. Production `check` reports the command needed for stale files.
Analysis and formatting finish for every configured entry before any output
is written; each file is replaced atomically. Failed generation preserves
previous output. A types module must not import its own generated codecs.
The API may import standalone codecs. `gleam run` compiles the app before
starting the kit, and RPC interface export also compiles the API's imports.
If stale generated code no longer compiles after a type change, run an
already compiled kit directly to regenerate the codecs before restarting
Vite. This compiler bootstrap limitation also applies to RPC generation.

## The API module

Every public function in the API module is an RPC method. Its first argument
is the `starflame/server.Context`, and every other argument is labelled, so
the client's functions are labelled too:

```gleam
pub fn set_done(
  context: Context,
  id id: Int,
  done done: Bool,
) -> Promise(Result(Todo, TodoError)) {
```

Methods can return a value or a `Promise` of one. These can cross the wire:

- `Int`, `Float`, `String`, `Bool`, `Nil`, `List`, `Option`, `Result`,
  tuples, and `Dict` with `String` keys.
- The app's own custom types, including recursive ones, with labelled or
  positional fields. They must live outside the API module, because the
  client imports them and importing the API would bring server code along.
- Callbacks: function arguments returning `Nil`, which the server calls
  fire-and-forget.
- Capabilities: records whose fields are all functions, like
  `Session(me: fn() -> Promise(User))`. They're passed by reference, so the
  client gets an opaque `Session` with `session_me` and `session_dispose`.
  They can only be returned, and their methods' arguments are unlabelled,
  because function types can't have labels.

The kit rejects anything else with an error naming the method and argument:
generic and opaque types, other packages' types, `Option(Option(a))` (both
`None` and `Some(None)` would be `null`), and names that Cap'n Web reserves,
such as `then` and `map`.

## What it generates

| File | Contents |
| --- | --- |
| `wire.gleam` | An encoder and decoder for every data type that crosses the wire, shared by client and server |
| `server.gleam` | A dispatcher per method: decodes the arguments, calls the API, encodes the reply |
| `targets.ts` | `RpcTarget` classes forwarding to the dispatchers, and `newApi(env, execution, auth?)` for the Worker |
| `client.gleam` | `connect`, `connect_http`, `from_stub`, `on_broken`, `dispose` and a typed function per method |

`client.gleam` imports only `wire.gleam` and the data types, so a browser
bundle doesn't pull in server code. The Worker serves `newApi` with Cap'n
Web, and anything app-specific, like the todo example's live room, wraps it.
`auth` is what `server.auth` returns to the API, such as the user the Worker
signed in.

Decoders check a value against its shape in one pass, then build it
directly; only values that don't match go through `gleam/dynamic/decode`,
for its exact errors. See `starflame/fast_decode`.

## How it reads the API

The kit reads the compiler's `gleam export package-interface`, so types are
fully resolved and nothing is parsed by hand. Changing the API often breaks
the generated code, which imports it, so the kit exports the interface from a
copy of the API module and the modules it imports, in
`build/starflame_rpc_kit/`. The API can't import the generated modules.

`@deprecated` and documentation comments on methods are copied to the client.
A deprecated method is still served, so Gleam warns where `server.gleam`
calls it.

Requires `gleam` on the `PATH`; the Gleam modules are laid out with
`gleam format`.
