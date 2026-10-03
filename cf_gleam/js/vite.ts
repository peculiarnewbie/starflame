// Vite plugin: runs `gleam build` before Vite resolves anything, and again
// whenever Gleam source or FFI files change during dev.
//
// In dev, the browser would otherwise load every compiled Gleam module
// (stdlib, Lustre, ...) as a separate unbundled request: ~100 requests in a
// deep import waterfall, which is slow over a real network. So client imports
// of compiled Gleam code are served as a single bundle instead. Gleam changes
// trigger a full page reload anyway, so nothing is lost. The Worker keeps
// using the individual modules.

import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { relative } from "node:path";
import { pathToFileURL } from "node:url";
import type { Plugin, ViteDevServer } from "vite";

const SOURCE = /\.(gleam|mjs|js|ts)$/;
const BUNDLE = "\0cf-gleam-bundle:";

export function gleam(): Plugin {
  let root = process.cwd();
  let output = "";
  let serving = false;
  let running: Promise<boolean> | null = null;
  let queued = false;

  const build = (): Promise<boolean> => {
    if (running) {
      queued = true;
      return running;
    }
    running = new Promise<boolean>((resolve) => {
      const child = spawn("gleam", ["build"], { cwd: root, stdio: "inherit" });
      child.on("error", () => resolve(false));
      child.on("exit", (code) => resolve(code === 0));
    }).finally(() => {
      running = null;
      if (queued) {
        queued = false;
        void build();
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
    name: "cf-gleam",
    enforce: "pre",

    config() {
      // Build the client bundle at startup rather than on the first visit.
      return { server: { warmup: { clientFiles: ["./main.{ts,js}"] } } };
    },

    configResolved(config) {
      root = config.root;
      output = `${root}/build/dev/javascript/`;
      serving = config.command === "serve";
    },

    async buildStart() {
      if (!(await build())) this.error("gleam build failed");
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
        if (!(await build())) return;
        for (const module of client.moduleGraph.idToModuleMap.values()) {
          if (module.id?.startsWith(BUNDLE))
            client.moduleGraph.invalidateModule(module);
        }
        client.hot.send({ type: "full-reload" });
      });
    },
  };
}
