// The Worker entrypoint: sessions, HTTP RPC, and hibernating sockets.
// Mounted at /app/chat; requests are stripped to the app root.

import { fromRequest, issue } from "@starflame/runtime/session.ts";

export { ChatRoom } from "./room.ts";

const BASE = "/app/chat";

export default {
  async fetch(request: Request, env: Env) {
    const url = new URL(request.url);
    if (url.pathname === BASE) {
      return Response.redirect(`${url.origin}${BASE}/`, 308);
    }
    const path = url.pathname.startsWith(`${BASE}/`)
      ? url.pathname.slice(BASE.length)
      : url.pathname;

    if (path === "/session") return issue();

    if (path === "/rpc" || path === "/socket") {
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      const session = await fromRequest(request);
      if (!session) return new Response("Missing session", { status: 401 });
      return env.CHAT.getByName(roomName(url.searchParams.get("room"))).fetch(
        request,
      );
    }

    const asset = new URL(url);
    asset.pathname = path;
    return env.ASSETS.fetch(asset);
  },
};

function roomName(raw: string | null) {
  const cleaned = (raw ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}
