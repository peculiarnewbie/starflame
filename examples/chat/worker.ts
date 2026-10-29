// The Worker entrypoint: sessions, HTTP RPC, and hibernating sockets.

import { fromRequest, issue } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/chat/chat/generated/targets.ts";

export { ChatRoom } from "./room.ts";

export default {
  async fetch(request: Request, env: Env) {
    const url = new URL(request.url);

    if (url.pathname === "/session") return issue();

    if (url.pathname === "/rpc" || url.pathname === "/socket") {
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      const session = await fromRequest(request);
      if (!session) return new Response("Missing session", { status: 401 });
      const room = roomName(url.searchParams.get("room"));
      return env.CHAT.getByName(room).fetch(request);
    }

    return new Response("Not found", { status: 404 });
  },
};

function roomName(raw: string | null) {
  const cleaned = (raw ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}
