import { bindings, defineConfig, exports, triggers } from "cf/config";

const BASE = "/app/blackjack";

export default defineConfig(({ mode }) => ({
  worker: {
    name: "starflame-blackjack",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      // In dev Vite serves the app's modules under the base path; only the API
      // needs the Worker. A deployed Worker serves the assets itself, because
      // the route prefix is not stripped by the asset layer.
      runWorkerFirst:
        mode === "development" ? [`${BASE}/rpc`, `${BASE}/session`] : true,
    },
    triggers: [
      triggers.fetch({
        pattern: "starflame.peculiarnewbie.com/app/blackjack/*",
        zone: "peculiarnewbie.com",
      }),
    ],
    env: {
      ASSETS: bindings.assets(),
      DB: bindings.d1({ name: "starflame-blackjack" }),
      TABLE: bindings.durableObject({
        worker: "starflame-blackjack",
        exportName: "BlackjackTable",
      }),
    },
    exports: { BlackjackTable: exports.durableObject({ storage: "sqlite" }) },
  },
}));
