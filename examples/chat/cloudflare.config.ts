import { bindings, defineConfig, exports, triggers } from "cf/config";

const BASE = "/app/chat";

export default defineConfig(({ mode }) => ({
  worker: {
    name: "starflame-chat",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst:
        mode === "development"
          ? [`${BASE}/rpc`, `${BASE}/socket`, `${BASE}/session`]
          : true,
    },
    triggers: [
      triggers.fetch({
        pattern: "starflame.peculiarnewbie.com/app/chat/*",
        zone: "peculiarnewbie.com",
      }),
    ],
    env: {
      ASSETS: bindings.assets(),
      CHAT: bindings.durableObject({
        worker: "starflame-chat",
        exportName: "ChatRoom",
      }),
    },
    exports: { ChatRoom: exports.durableObject({ storage: "sqlite" }) },
  },
}));
