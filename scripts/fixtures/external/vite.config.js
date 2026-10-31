import { defineConfig } from "vite";
import { gleam } from "@starflame/vite";

export default defineConfig({
  plugins: [gleam({ rpc: { api: "ext/api", out: "ext/generated" } })],
});
