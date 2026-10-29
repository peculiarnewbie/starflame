import { bindings, defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    name: "starflame-photos",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/rpc", "/session", "/photos/*"],
    },
    env: {
      DB: bindings.d1({ name: "starflame-photos" }),
      BUCKET: bindings.r2({ name: "starflame-photos" }),
    },
  },
});
