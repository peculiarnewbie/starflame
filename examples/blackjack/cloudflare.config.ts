import { bindings, defineConfig, exports } from "cf/config";

export default defineConfig({
  worker: {
    name: "starflame-blackjack",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/rpc", "/session"],
    },
    env: {
      DB: bindings.d1({ name: "starflame-blackjack" }),
      TABLE: bindings.durableObject({
        worker: "starflame-blackjack",
        exportName: "BlackjackTable",
      }),
    },
    exports: { BlackjackTable: exports.durableObject({ storage: "sqlite" }) },
  },
});
