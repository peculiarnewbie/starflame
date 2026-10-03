import { cloudflare } from "@cloudflare/vite-plugin";
import { defineConfig } from "vite";
import { gleam } from "../starflame/js/vite.ts";

export default defineConfig({
  plugins: [gleam(), cloudflare()],
  server: {
    host: "0.0.0.0",
    // Allow hostnames like `my-machine.local`, not just IPs.
    allowedHosts: true,
  },
});
