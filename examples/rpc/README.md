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
The codecs and dispatchers in `src/spike/generated/` are hand-written.
