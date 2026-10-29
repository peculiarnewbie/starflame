// The Worker entrypoint: sessions, and one Durable Object per table.

import { fromRequest, issue } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/blackjack/blackjack/generated/targets.ts";

export { BlackjackTable } from "./room.ts";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);

    if (url.pathname === "/session") return issue();

    if (url.pathname === "/rpc") {
      // Cap'n Web doesn't check Origin, and browsers allow cross-site
      // WebSockets, so reject other sites here.
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      const session = await fromRequest(request);
      if (!session) return new Response("Missing session", { status: 401 });
      return env.TABLE.getByName(tableName(url.searchParams.get("table"))).fetch(
        request,
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

function tableName(raw: string | null) {
  const cleaned = (raw ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}
