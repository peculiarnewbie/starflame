import { bindings, defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    name: "starflame-notes",
    compatibilityDate: "2026-09-30",
    // OpenAuth reads process.env.
    compatibilityFlags: ["nodejs_compat"],
    entrypoint: "./worker.ts",
    // workers.dev is a second origin, whose tokens wouldn't work here.
    workersDev: false,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: [
        "/rpc",
        "/auth/*",
        "/authorize",
        "/token",
        "/.well-known/*",
        "/google/*",
        "/code/*",
      ],
    },
    env: {
      DB: bindings.d1({ name: "starflame-notes" }),
      AUTH: bindings.kv(),
      EMAIL: bindings.sendEmail(),
      GOOGLE_CLIENT_ID: bindings.text(""),
      EMAIL_FROM: bindings.text("login@notes.example"),
    },
  },
});
