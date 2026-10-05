# Todo example

The todo proof of concept supports adding, completing, filtering, and
deleting todos, with server-side validation and automatic WebSocket reconnects.
Live POC: [starflame-todo.peculiarnewbie.workers.dev](https://starflame-todo.peculiarnewbie.workers.dev).
It is a shared demo: everyone uses the same todo list, with no authentication.

Compare three approaches using the navigation links or separate tabs:

| Route | UI runs in | Updates from other clients |
| --- | --- | --- |
| `/` | Browser | Full list fetch when the tab regains focus |
| `/live` | Browser | Initial snapshot, then typed Cap'n Web change callbacks |
| `/server` | Durable Object | Lustre sends DOM patches over WebSocket |

All three share the same D1 data. A Durable Object coordinates writes and
broadcasts successful changes, including edits from the original route. Live
subscriptions apply upserts, removals, and clear-completed events without
refetching the list. Reconnecting obtains a fresh snapshot. Server components
use a separate Lustre runtime per connection so drafts and filters stay private;
these temporary UI settings reset on reconnect, while todos persist in D1.

This experiment uses standard, non-hibernating WebSockets. Connected clients
keep the Durable Object active. Production work should address connection
limits and idle costs. The server experiment uses a vendored, MIT-licensed
compatibility patch for JavaScript runtime bugs in Lustre 5.7.1 (startup arity,
shadowed message variables, a property handler typo, and batched events).
Remove that patch when an upstream release resolves these issues.

Requires Gleam, Node.js 22 or newer, and pnpm.

```sh
pnpm install --frozen-lockfile # from the repository root
pnpm dev
```

Run `pnpm smoke` in another terminal while the dev server is running. It checks
the frontend assets, origin rejection, typed validation errors, WebSocket and
HTTP batch RPC, persistence across sessions, updates, and deletion. It creates
and removes only its own todo.

For the multi-tab comparison checks, install Chromium once with
`pnpm --filter @starflame/example-todo exec playwright install chromium`, then run `pnpm test:compare` while
the dev server is running. Pass a deployed URL to check the hosted version.
The checks cover cross-route create/update/delete propagation, private drafts
and filters, baseline focus refresh, reconnects, persistence, and origin checks.
Run `pnpm typecheck` to generate Worker binding types and check the backend.

Run the deployment commands below from `examples/todo`.

To deploy using the Cloudflare CLI's authenticated account:

```sh
pnpm exec cf auth login # only if not already authenticated
pnpm build
pnpm exec cf deploy --prebuilt --dry-run
pnpm exec cf deploy --prebuilt
pnpm smoke https://your-worker.workers.dev
```

`pnpm run deploy` builds and deploys in one command. The configuration publishes
`starflame-todo`, binds the D1 database of the same name as `DB`, and enables
Worker observability. The application creates its table on first use.

`src/todos/generated/` comes from `src/todos/api.gleam`. `pnpm dev` regenerates
it as the API changes, `pnpm build` fails if it's out of date, and `pnpm rpc`
regenerates it by hand. `TodoRoom` in `room.ts` wraps the generated target to order
writes and broadcast changes, and serves `subscribe` itself.
