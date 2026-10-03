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

Run `pnpm build` to produce ESM and TypeScript declarations in `dist/`.
`pnpm pack` builds and packages this library without publishing it.
