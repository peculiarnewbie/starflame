import { cloudflare } from "@cloudflare/vite-plugin";
import { defineConfig } from "vite";
import { gleam } from "@starflame/vite";

export default defineConfig({
  // Each demo is mounted under its own prefix on the shared domain.
  base: "/app/blackjack/",
  plugins: [gleam(), cloudflare()],
  server: {
    host: "0.0.0.0",
    // Allow hostnames like `my-machine.local`, not just IPs.
    allowedHosts: true,
  },
});
