<img src="assets/icon.svg" width="64" height="64" alt="">

# starflame

Gleam full-stack apps on Cloudflare Workers, using Lustre for the browser,
Cap'n Web for typed RPC, and D1 for persistent storage.

Starflame explores how little framework code is needed to connect a typed
functional application across the browser, server, and database. The current
proof of concept is a deployed, shared todo app with three ways to keep the UI
up to date. The reusable runtime and build plugin live alongside those examples.

## Why this exists

A full-stack application often expresses the same domain several times: server
models, API payloads, validation schemas, client types, and UI state. Each boundary
creates another place for those definitions to drift.

The idea here is to describe the domain in Gleam, use it on both sides of the
network, and keep the boundary code small and explicit. Gleam already provides
custom types, pattern matching, and `Result` for modelling data and expected
failures. Starflame adds adapters for RPC, wire values, database access, and the
build pipeline. [Gleam's language tour](https://tour.gleam.run/everything/)
introduces those language features.

The small size comes largely from composition. Gleam supplies the language and
compiler, Lustre supplies the UI model, Cap'n Web supplies the RPC transport,
and Cloudflare supplies the server and storage. Starflame connects those pieces.
Its size measures the integration code; the dependencies still do substantial
work. These are established ideas, and this project makes no claim to have
invented typed full-stack programming or server-driven UI.

## How it fits together

| Piece | Responsibility |
| --- | --- |
| Gleam | Shared domain types, application logic, and explicit success/error values; compiled to JavaScript |
| Lustre | Browser UI updates, or server-side UI updates delivered as DOM patches |
| Cap'n Web | RPC over WebSocket or HTTP batch sessions, with callbacks and returned capabilities |
| Starflame runtime | Encode/decode Gleam values at the RPC boundary, connect calls to Lustre effects, and access D1 |
| Starflame Vite plugin | Compile Gleam and integrate its output into browser and Worker builds |
| Cloudflare Workers, Durable Objects, and D1 | Handle requests, coordinate the demo's live sessions, and persist its data |

Cap'n Web's callbacks and capabilities make a session more expressive than a
collection of request/response endpoints. The RPC example exercises both; the
todo example uses callbacks to deliver typed changes to connected browsers.
See [Cap'n Web's documentation](https://github.com/cloudflare/capnweb) for the
underlying transport and capability model.

A shared type in the todo example looks like this:

```gleam
pub type Todo {
  Todo(id: Int, title: String, done: Bool)
}

pub type TodoError {
  EmptyTitle
  TitleTooLong(max: Int)
  NotFound(id: Int)
}
```

The client call's signature preserves the domain error while also accounting
for failure at the network or decoding boundary:

```gleam
pub fn add_todo(
  api: Api,
  title: String,
) -> Promise(Result(Result(Todo, TodoError), RpcError))
```

`Ok(Ok(todo))` means the todo was created. `Ok(Error(EmptyTitle))` means the
server understood the call and rejected the title. `Error(rpc_error)` means
the call failed or its reply could not be decoded. The UI can handle those
cases explicitly using pattern matching.

Shared static types alone cannot validate network input. Gleam values are
encoded into plain JavaScript values before transmission; decoders reconstruct
and check them on receipt. The current examples hand-write those codecs and
RPC stubs, so keeping them aligned with the domain types is still work.
Generating them from the API and type definitions is the intended next step.
Business rules, such as title length, remain server-side application logic.

## The connection to Effect

There is a familiar appeal for someone who likes Effect: model expected errors
as data, compose functions, and decode untrusted values at the edges. Here, much
of that programming style comes from Gleam's language and standard library.
For a small application, that may feel like a simpler starting point.

The schema analogy applies to the explicit encoders and decoders at the RPC
boundary. Effect Schema provides a much broader schema abstraction for
validation and transformation; Starflame currently has a wire convention and
hand-written codecs. See the [Effect Schema introduction](https://effect.website/docs/v3/schema/introduction).

Effect also provides an execution model with typed requirements, structured
concurrency, resource safety, and observability. Starflame's `Promise(Result(...))`
calls and Lustre effects do not provide that same set of guarantees. The goal
is a small, opinionated full-stack integration. Whether it is simpler for a
particular application depends on which of those capabilities the application
needs. See [Effect's overview](https://effect.website/docs/v4/onboarding).

## Three UI and synchronization approaches

The todo example keeps the same domain and persistence layer while comparing:

| Route | Where the UI runs | How it receives shared-data changes |
| --- | --- | --- |
| `/` | Browser | Fetches the full list again when the tab regains focus |
| `/live` | Browser | Receives an initial snapshot, then typed change callbacks |
| `/server` | Durable Object | Receives DOM patches from a Lustre server component |

This is a place to explore the tradeoffs. The live browser route keeps UI state
local and applies server changes to its model. The server route keeps each
connection's UI model on the server, reducing browser-side synchronization
logic while making interaction latency and connection lifetime more significant.
Drafts and filters stay private to each connection; the todo list is shared.

Server rendering still needs reconnect handling and a protocol to keep the
browser's DOM current. The current server example resets temporary UI state
on reconnect and uses non-hibernating WebSockets plus a vendored Lustre runtime
compatibility patch. The [todo README](examples/todo/README.md) explains those
limitations and the checks covering all three approaches.

## Current scope

The POC demonstrates typed calls and domain errors, runtime decoding, callbacks,
capabilities, persistent storage, live updates, and server-component rendering.
It is an early foundation for a library, with a deliberately narrow deployment
and application model.

Automatic codec/stub generation, a stable public API, and published packages
are still ahead. The public todo demo has no authentication and shares one list
among all visitors. Authentication, authorization, schema evolution, and
production connection management need further work before this example can
serve as a production application template.

## Repository layout

This monorepo separates the reusable libraries from the runnable examples:

| Directory | Purpose |
| --- | --- |
| [packages/starflame](packages/starflame) | Gleam runtime: RPC client/server, wire codecs, and D1 bindings |
| [packages/vite](packages/vite) | `@starflame/vite`: Vite plugin with ESM and TypeScript exports |
| [examples/todo](examples/todo) | Deployed todo POC comparing browser refresh, live RPC, and Lustre server components |
| [examples/rpc](examples/rpc) | RPC integration experiments against a local Worker |

The libraries are local workspace packages; they have not been published to
Hex or npm. RPC codecs and dispatchers are currently hand-written in each
example. Automatic code generation is a next step beyond this POC.

## Getting started

Requires Gleam 1.18.1, Node.js 22+ (the repository pins 24.21.0), and pnpm 12.8.1.
Run these commands from the repository root:

```sh
pnpm install --frozen-lockfile
pnpm build
pnpm typecheck
pnpm test
pnpm dev
```

`pnpm test` runs the RPC integration experiments. With the todo dev server
running on port 5173, use another terminal for its checks:

```sh
pnpm smoke
pnpm --filter @starflame/example-todo exec playwright install chromium
pnpm test:compare
```

`pnpm deploy:todo` builds and deploys the todo example using your authenticated
Cloudflare account. See the [todo README](examples/todo/README.md) for deployment
details, the shared-demo model, and server-component limitations.

Live POC: [starflame-todo.peculiarnewbie.workers.dev](https://starflame-todo.peculiarnewbie.workers.dev).
All three routes share one public todo list: `/`, `/live`, and `/server`.

A single pnpm workspace and lockfile manage JavaScript dependencies. Gleam
examples depend on `../../packages/starflame`; the todo app imports its Vite
plugin through `@starflame/vite`. Root commands build packages in dependency
order, and installation builds the plugin so development works immediately.
See the package READMEs for APIs and plugin usage.

Created in [T3 Code](https://t3.codes).
