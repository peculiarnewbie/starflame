import { bindings, defineConfig, exports } from "cf/config";

export default defineConfig({
  worker: {
    name: "starflame-chat",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/rpc", "/session", "/socket"],
    },
    env: {
      DB: bindings.d1({ name: "starflame-chat" }),
      CHAT: bindings.durableObject({
        worker: "starflame-chat",
        exportName: "ChatRoom",
      }),
    },
    exports: { ChatRoom: exports.durableObject({ storage: "sqlite" }) },
  },
});
