# starflame

Gleam runtime for full-stack applications on Cloudflare Workers using Cap'n Web.
The package targets JavaScript and exports:

| Module | Purpose |
| --- | --- |
| `starflame/client` | Typed RPC calls, callbacks, connection handling, and Lustre effects |
| `starflame/server` | Request context, argument decoding, and callback forwarding |
| `starflame/plain` | Wire values and codecs for shared Gleam types |
| `starflame/d1` | Cloudflare D1 bindings, setup, queries, and writes |
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
