<img src="assets/icon.svg" width="64" height="64" alt="">

# starflame

Gleam full-stack apps on Cloudflare Workers, using Lustre for the browser,
Cap'n Web for typed RPC, and D1 for persistent storage.

The `todo/` proof of concept supports adding, completing, filtering, and
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
cd todo
pnpm install --frozen-lockfile
pnpm dev
```

Run `pnpm smoke` in another terminal while the dev server is running. It checks
the frontend assets, origin rejection, typed validation errors, WebSocket and
HTTP batch RPC, persistence across sessions, updates, and deletion. It creates
and removes only its own todo.

For the multi-tab comparison checks, install Chromium once with
`pnpm exec playwright install chromium`, then run `pnpm test:compare` while
the dev server is running. Pass a deployed URL to check the hosted version.
The checks cover cross-route create/update/delete propagation, private drafts
and filters, baseline focus refresh, reconnects, persistence, and origin checks.
Run `pnpm typecheck` to generate Worker binding types and check the backend.

To deploy using the Cloudflare CLI's authenticated account:

```sh
pnpm exec cf auth login # only if not already authenticated
pnpm build
pnpm exec cf deploy --prebuilt --dry-run
pnpm exec cf deploy --prebuilt
pnpm smoke https://your-worker.workers.dev
```

`pnpm deploy` builds and deploys in one command. The configuration publishes
`starflame-todo`, binds the D1 database of the same name as `DB`, and enables
Worker observability. The application creates its table on first use.

The `starflame/` directory contains the reusable runtime and Vite plugin.
`spike/` contains RPC experiments; run `pnpm install --frozen-lockfile` and
`pnpm exp` there to exercise serialization, capabilities, callbacks, origin
checks, and recovery after a Worker restart.

The RPC codecs and stubs under each app's `generated/` directory are currently
hand-written. Automatic code generation is a next step beyond this POC.

Created in [T3 Code](https://t3.codes).
