import { cloudflare } from "@cloudflare/vite-plugin";
import { defineConfig } from "vite";
import { gleam } from "@starflame/vite";

export default defineConfig({
  base: "/app/photos/",
  plugins: [gleam(), cloudflare()],
  server: {
    host: "0.0.0.0",
    allowedHosts: true,
  },
});
