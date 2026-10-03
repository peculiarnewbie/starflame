import { bindings, defineConfig, exports } from "cf/config";

export default defineConfig({
  worker: {
    name: "starflame-todo",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/rpc", "/live/rpc", "/server/socket"],
    },
    env: {
      DB: bindings.d1({ name: "starflame-todo" }),
      ROOM: bindings.durableObject({ worker: "starflame-todo", exportName: "TodoRoom" }),
    },
    exports: { TodoRoom: exports.durableObject({ storage: "sqlite" }) },
  },
});
