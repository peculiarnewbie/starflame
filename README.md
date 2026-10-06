<img src="assets/icon.svg" width="64" height="64" alt="">

# starflame

Full-stack functional programming in Gleam, deployed on Cloudflare Workers.
Lustre handles the UI, Cap'n Web handles typed RPC, and D1 stores the data.
Starflame is the small runtime and build integration connecting them.

## Why

Algebraic data types, pattern matching, immutable data, and explicit errors are
ordinary language features in Gleam. Use those same tools and domain types in
the browser and on the server, with runtime decoding at the network boundary.
The aim is less duplicated modelling and less glue between application layers.

The interesting part is how much already exists: a functional language that
compiles to JavaScript, a UI framework, and an RPC system with callbacks and
capabilities. Putting them together gives us a small foundation for typed,
interactive full-stack apps.

The POC supports browser-side UI with live data subscriptions and Lustre server
components that send DOM patches. Both use the same domain logic and persistent
data, so we can explore where application state should live.

## Examples

[Live todo demo](https://starflame-todo.peculiarnewbie.workers.dev) — one shared
public list, three approaches:

| Route | UI | Synchronization |
| --- | --- | --- |
| `/` | Browser | Fetch the list on tab focus |
| `/live` | Browser | Initial snapshot, then typed change callbacks |
| `/server` | Server | DOM patches over WebSocket |

See the [todo example](examples/todo/README.md) for details and limitations.
The [RPC experiments](examples/rpc/README.md) exercise serialization, typed
errors, callbacks, capabilities, and reconnection.

## Packages

| Directory | Purpose |
| --- | --- |
| [packages/starflame](packages/starflame) | Gleam RPC runtime, wire codecs, and D1 bindings |
| [packages/rpc/kit](packages/rpc/kit) | Generates RPC codecs, dispatchers and client functions from an API module |
| [packages/db/core](packages/db/core) | D1 schemas in Gleam |
| [packages/db/kit](packages/db/kit) | D1 migrations and typed CRUD modules from a schema |
| [packages/openauth](packages/openauth) | Sign-in with an OpenAuth issuer in the app's Worker |
| [packages/vite](packages/vite) | `@starflame/vite` build plugin |
| [examples/notes](examples/notes) | Per-user notes: sign-in, HTTP RPC and D1, as a template for apps with users |
| [examples/todo](examples/todo) | Todo POC |
| [examples/rpc](examples/rpc) | RPC integration experiments |

Early POC: packages are unpublished. The todo demo has no authentication;
the notes example shows how to add it. Production connection management for
live WebSocket apps still needs work.

## Using Starflame in another app

Depend on the packages from this repository, pinned to a commit. Gleam
1.18's `path` field selects each package's directory, and all of them need
the same `ref`:

```toml
[dependencies]
starflame = { git = "https://github.com/peculiarnewbie/starflame", ref = "<commit>", path = "packages/starflame" }
starflame_db = { git = "https://github.com/peculiarnewbie/starflame", ref = "<commit>", path = "packages/db/core" }
starflame_openauth = { git = "https://github.com/peculiarnewbie/starflame", ref = "<commit>", path = "packages/openauth" }

[dev-dependencies]
starflame_rpc_kit = { git = "https://github.com/peculiarnewbie/starflame", ref = "<commit>", path = "packages/rpc/kit" }
starflame_db_kit = { git = "https://github.com/peculiarnewbie/starflame", ref = "<commit>", path = "packages/db/kit" }
```

```json
"@starflame/vite": "github:peculiarnewbie/starflame#<commit>&path:/packages/vite"
```

Start from [examples/notes](examples/notes), replacing its `path`
dependencies with these.

## Development

Requires Gleam 1.18.1, Node.js 22+ (pinned to 24.21.0), and pnpm 12.8.1.
From the repository root:

```sh
pnpm install --frozen-lockfile
pnpm build
pnpm typecheck
pnpm test
pnpm dev
```

With the dev server running, use `pnpm smoke` and `pnpm test:compare` for the todo
checks. The browser checks require
`pnpm --filter @starflame/example-todo exec playwright install chromium` once.
Use `pnpm deploy:todo` to deploy with your authenticated Cloudflare account.

Created in [T3 Code](https://t3.codes).
