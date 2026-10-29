import { bindings, defineConfig, exports } from "cf/config";

export default defineConfig({
  worker: {
    name: "starflame-canvas",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/rpc", "/session"],
    },
    env: {
      DB: bindings.d1({ name: "starflame-canvas" }),
      BOARD: bindings.durableObject({
        worker: "starflame-canvas",
        exportName: "CanvasBoard",
      }),
    },
    exports: { CanvasBoard: exports.durableObject({ storage: "sqlite" }) },
  },
});
