import { defineConfig, triggers } from "cf/config";

export default defineConfig({
  worker: {
    name: "starflame-landing",
    compatibilityDate: "2026-09-30",
    entrypoint: "./worker.ts",
    workersDev: true,
    observability: { enabled: true },
    triggers: [
      triggers.fetch({
        pattern: "starflame.peculiarnewbie.com/*",
        zone: "peculiarnewbie.com",
      }),
    ],
  },
});
