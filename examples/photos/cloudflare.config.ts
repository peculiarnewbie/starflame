import { bindings, defineConfig, triggers } from "cf/config";

const BASE = "/app/photos";

export default defineConfig(({ mode }) => ({
  worker: {
    name: "starflame-photos",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst:
        mode === "development"
          ? [`${BASE}/rpc`, `${BASE}/session`, `${BASE}/photos/*`]
          : true,
    },
    triggers: [
      triggers.fetch({
        pattern: "starflame.peculiarnewbie.com/app/photos/*",
        zone: "peculiarnewbie.com",
      }),
    ],
    env: {
      ASSETS: bindings.assets(),
      DB: bindings.d1({ name: "starflame-photos" }),
      BUCKET: bindings.r2({ name: "starflame-photos" }),
    },
  },
}));
