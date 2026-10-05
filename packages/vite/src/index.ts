// Vite plugin: runs `gleam build` before Vite resolves anything, and again
// whenever Gleam source or FFI files change during dev.
//
// When the app uses starflame_rpc_kit, dev also regenerates the RPC code
// whenever the API module or a module it imports changes, and a production
// build checks it's up to date instead.
//
// In dev, the browser would otherwise load every compiled Gleam module
// (stdlib, Lustre, ...) as a separate unbundled request: ~100 requests in a
// deep import waterfall, which is slow over a real network. So client imports
// of compiled Gleam code are served as a single bundle instead. Gleam changes
// trigger a full page reload anyway, so nothing is lost. The Worker keeps
// using the individual modules.

import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Plugin, ViteDevServer } from "vite";

const SOURCE = /\.(gleam|mjs|js|ts)$/;
const BUNDLE = "\0starflame-bundle:";

export interface Options {
  /**
   * Generate RPC code with starflame_rpc_kit. By default, on when the app
   * depends on it. Pass `{ api, out }` for the kit's `--api` and `--out`.
   */
  rpc?: boolean | { api?: string; out?: string };
}

export function gleam(options: Options = {}): Plugin {
  let root = process.cwd();
  let output = "";
  let serving = false;
  let rpc = false;
  let running: Promise<boolean> | null = null;
  let queued = false;
  let queuedGenerate = false;
  // Files the kit just wrote, whose change events shouldn't trigger a rebuild.
  const written = new Set<string>();

  const run = (command: string, args: string[], quiet: boolean) =>
    new Promise<{ ok: boolean; output: string }>((resolve) => {
      const child = spawn(command, args, {
        cwd: root,
        stdio: quiet ? ["ignore", "pipe", "pipe"] : "inherit",
      });
      let output = "";
      child.stdout?.on("data", (data) => (output += data));
      child.stderr?.on("data", (data) => (output += data));
      child.on("error", (error) => resolve({ ok: false, output: String(error) }));
      child.on("exit", (code) => resolve({ ok: code === 0, output }));
    });

  const kit = async (command: "generate" | "check"): Promise<boolean> => {
    const flags = typeof options.rpc === "object" ? options.rpc : {};
    const args = ["run", "--no-print-progress", "-m", "starflame_rpc_kit", "--", command];
    if (flags.api) args.push("--api", flags.api);
    if (flags.out) args.push("--out", flags.out);
    const result = await run("gleam", args, true);
    if (!result.ok) {
      console.error(`[starflame] RPC ${command} failed:\n${result.output.trimEnd()}`);
      return false;
    }
    for (const line of result.output.split("\n")) {
      if (!line.startsWith("Wrote ")) continue;
      console.log(`[starflame] ${line}`);
      written.add(resolve(root, line.slice("Wrote ".length)));
    }
    return true;
  };

  /** Whether a change to `file` can change the generated RPC code. */
  const affectsApi = (file: string) => {
    if (!rpc || !file.endsWith(".gleam")) return false;
    const path = resolve(root, "build/starflame_rpc_kit/sources.json");
    if (!existsSync(path)) return true;
    try {
      const { sources } = JSON.parse(readFileSync(path, "utf8")) as { sources: string[] };
      return sources.some((source) => resolve(root, source) === file);
    } catch {
      return true;
    }
  };

  const build = (generate = false): Promise<boolean> => {
    if (running) {
      queued = true;
      queuedGenerate ||= generate;
      return running;
    }
    running = (async () => {
      // A failed generate leaves the old code; the error says what to fix.
      if (generate && !(await kit("generate"))) return false;
      return (await run("gleam", ["build"], false)).ok;
    })().finally(() => {
      running = null;
      if (queued) {
        const generate = queuedGenerate;
        queued = false;
        queuedGenerate = false;
        void build(generate);
      }
    });
    return running;
  };

  const isCompiledGleam = (id: string) => id.startsWith(output);

  // Rolldown ships with Vite 8, so resolve it from Vite's own location.
  const loadRolldown = async () => {
    const vite = createRequire(`${root}/package.json`).resolve("vite");
    const path = createRequire(vite).resolve("rolldown");
    return (await import(pathToFileURL(path).href)) as typeof import("rolldown");
  };

  const bundle = async (entry: string) => {
    const { rolldown } = await loadRolldown();
    const result = await rolldown({
      input: entry,
      platform: "browser",
      cwd: root,
      onLog(level, log, handler) {
        // Lustre's FFI has a misplaced @__PURE__ comment; harmless.
        if (log.code === "INVALID_ANNOTATION") return;
        handler(level, log);
      },
    });
    try {
      const { output } = await result.generate({
        format: "esm",
        sourcemap: "inline",
      });
      return output[0].code;
    } finally {
      await result.close();
    }
  };

  return {
    name: "starflame",
    enforce: "pre",

    config() {
      // Build the client bundle at startup rather than on the first visit.
      return { server: { warmup: { clientFiles: ["./main.{ts,js}"] } } };
    },

    configResolved(config) {
      root = config.root;
      output = `${root}/build/dev/javascript/`;
      serving = config.command === "serve";
      rpc = options.rpc === undefined ? usesRpcKit(root) : options.rpc !== false;
    },

    async buildStart() {
      // Dev keeps the RPC code current; a production build only checks it,
      // rather than changing sources.
      if (rpc && !serving && !(await kit("check"))) {
        this.error("the generated RPC code is out of date: run `gleam run -m starflame_rpc_kit -- generate`");
      }
      if (!(await build(rpc && serving))) this.error("gleam build failed");
    },

    async resolveId(source, importer, options) {
      if (!serving || this.environment.name !== "client") return;
      if (!importer || importer.startsWith(BUNDLE) || isCompiledGleam(importer))
        return;
      const resolved = await this.resolve(source, importer, {
        ...options,
        skipSelf: true,
      });
      if (resolved && isCompiledGleam(resolved.id)) return BUNDLE + resolved.id;
    },

    async load(id) {
      if (!id.startsWith(BUNDLE)) return;
      await running;
      return bundle(id.slice(BUNDLE.length));
    },

    configureServer(server: ViteDevServer) {
      const src = `${root}/src`;
      const client = server.environments.client;

      server.watcher.add(src);
      server.watcher.on("change", async (file) => {
        if (!SOURCE.test(file) || relative(src, file).startsWith("..")) return;
        // The kit's own writes are already part of the build that made them.
        if (written.delete(file)) return;
        if (!(await build(affectsApi(file)))) return;
        for (const module of client.moduleGraph.idToModuleMap.values()) {
          if (module.id?.startsWith(BUNDLE))
            client.moduleGraph.invalidateModule(module);
        }
        client.hot.send({ type: "full-reload" });
      });
    },
  };
}

function usesRpcKit(root: string): boolean {
  const path = `${root}/gleam.toml`;
  return existsSync(path) && /^\s*starflame_rpc_kit\s*=/m.test(readFileSync(path, "utf8"));
}
