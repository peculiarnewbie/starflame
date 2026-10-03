<img src="assets/icon.svg" width="64" height="64" alt="">

# starflame

Gleam full-stack apps on Cloudflare Workers, using Lustre for the browser,
Cap'n Web for typed RPC, and D1 for persistent storage.

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
