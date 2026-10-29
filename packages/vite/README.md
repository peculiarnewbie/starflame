# @starflame/vite

Vite integration for Starflame applications targeting Gleam's JavaScript backend.
Requires Node.js 22+, Vite 8, and the `gleam` executable on your PATH.

```ts
import { defineConfig } from "vite";
import { gleam } from "@starflame/vite";

export default defineConfig({ plugins: [gleam()] });
```

The plugin builds Gleam before Vite resolves compiled modules, rebuilds app
sources and FFI files during development, and bundles browser imports of Gleam
output to avoid a deep module-request waterfall. Worker imports keep using the
individual compiled modules.

When `gleam.toml` lists `starflame_rpc_kit`, the dev server also regenerates
the RPC code whenever the API module or a module it imports changes. If the
API is invalid, it prints the kit's error and keeps the previous code. A
production build checks the generated code instead, and fails if it's out of
date rather than changing sources. Pass `gleam({ rpc: false })` to turn this
off, or `gleam({ rpc: { api: "todos/rpc", out: "todos/rpc_generated" } })`
for the kit's `--api` and `--out`.

Standalone state codecs can be configured in the app's `gleam.toml`:

```toml
[starflame]
codecs = ["todos/state:todos/state_codecs"]
```

Dev runs `gleam run -m starflame_rpc_kit -- codecs` after RPC generation and
before building, and watches the codecs modules and their dependencies too.
A generation error reports the cause and preserves the previous files.
Production `check` also verifies configured codecs and reports the command
to run if they are stale. To regenerate manually, run RPC `generate`, then
`codecs`.

The plugin is plain JavaScript with type annotations in comments, plus a
hand-written `index.d.ts`, so it runs without a build step. That lets an
app install it straight from git:

```json
"@starflame/vite": "github:peculiarnewbie/starflame#<commit>&path:/packages/vite"
```

`pnpm typecheck` checks the source against the declarations.
