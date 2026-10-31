# starflame

Gleam runtime for full-stack applications on Cloudflare Workers using Cap'n Web.
The package targets JavaScript and exports:

| Module | Purpose |
| --- | --- |
| `starflame/client` | Typed RPC calls, callbacks, connection handling, and Lustre effects |
| `starflame/server` | Request context, argument decoding, and callback forwarding |
| `starflame/topic` | Typed events and subscriptions owned by server capabilities |
| `starflame/plain` | Wire values and codecs for shared Gleam types |
| `starflame/d1` | Cloudflare D1 bindings, setup, queries, and writes |
| `starflame/do_sql` | Durable Object SQLite bindings (synchronous) |
| `starflame/r2` | R2 object storage bindings |
| `starflame/fast_decode` | A fast path for decoding wire values and D1 rows, for generated code |

The examples use this package as a local Gleam dependency; other apps can
depend on it from git, as the root README shows.

The client calls the API over a WebSocket with `connect`, or over HTTP with
`connect_http`, one request per call. HTTP suits APIs without callbacks or
capabilities: nothing stays open, and each call carries the page's cookies.
A request the Worker refuses fails with `Http(status)`, such as `Http(401)`.

On the server, `server.auth(context)` returns what the Worker passed as
`auth` to `newApi`, such as the signed-in user, for the API to decode.

Consumers also need the `capnweb` JavaScript dependency (the examples pin
`0.12.0`). Use the companion `@starflame/vite` package to build browser and
Worker output. The package.json here is a private workspace build runner;
`gleam.toml` defines the Gleam library.

[`starflame_rpc_kit`](../rpc/kit) generates the codecs, dispatchers and client
functions that use this runtime.

Application RPC calls use those generated functions. The API's Gleam types
determine both the server encoder and client decoder; the compiler checks the
implementation and every typed caller, and the kit's `check` rejects stale
generation. Raw method names and caller-supplied decoders are available only
through the explicitly unsafe `starflame/unsafe_rpc` module. The old
`client.call`, `client.callback`, and `client.stub_decoder` primitives moved
there; they do not provide the shared API guarantee.

`server.with_dispose(capability, cleanup)` ties resources to a generated
capability's lifetime. Generated targets retain callback stubs after a method
returns and release them on disposal. Use `topic.Subscription(event)` for live
events, and register `topic.dispose(subscription)` as the capability's cleanup.
`server.serialise(context, operation)` orders asynchronous operations sharing
an execution context, such as a Durable Object's state.
