import { bindings, defineConfig, exports, triggers } from "cf/config";

const BASE = "/app/canvas";

export default defineConfig(({ mode }) => ({
  worker: {
    name: "starflame-canvas",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst:
        mode === "development"
          ? [`${BASE}/rpc`, `${BASE}/session`]
          : true,
    },
    triggers: [
      triggers.fetch({
        pattern: "starflame.peculiarnewbie.com/app/canvas/*",
        zone: "peculiarnewbie.com",
      }),
    ],
    env: {
      ASSETS: bindings.assets(),
      BOARD: bindings.durableObject({
        worker: "starflame-canvas",
        exportName: "CanvasBoard",
      }),
    },
    exports: { CanvasBoard: exports.durableObject({ storage: "sqlite" }) },
  },
}));
