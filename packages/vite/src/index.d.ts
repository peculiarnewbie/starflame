import type { Plugin } from "vite";

export interface Options {
  /**
   * Generate RPC code with starflame_rpc_kit. By default, on when the app
   * depends on it. Pass `{ api, out }` for the kit's `--api` and `--out`.
   */
  rpc?: boolean | { api?: string; out?: string };
}

/**
 * Runs `gleam build` before Vite resolves anything and whenever Gleam source
 * changes in dev, and serves the browser's compiled Gleam as one bundle.
 */
export function gleam(options?: Options): Plugin;
