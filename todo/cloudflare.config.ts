import { bindings, defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    name: "cf-gleam-todo",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/rpc"],
    },
    env: {
      DB: bindings.d1({ name: "cf-gleam-todo" }),
    },
  },
});
