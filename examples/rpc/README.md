# RPC experiments

A small Gleam/Cloudflare Worker harness for testing Starflame and Cap'n Web.
It covers serialization, capabilities, callbacks, origin checks, and recovery
after a Worker restart using Miniflare.

From the repository root:

```sh
pnpm install --frozen-lockfile
pnpm test
```

Or run `pnpm exp` from this directory. The Gleam package retains the internal
name `spike`; it consumes the runtime from `../../packages/starflame`.
`src/spike/generated/` comes from `src/spike/api.gleam`; run `pnpm rpc` after
changing the API. `pnpm exp` fails if the generated code is out of date.
