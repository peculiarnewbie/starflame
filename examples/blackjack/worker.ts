// The Worker entrypoint: sessions, and one Durable Object per table.
//
// The app is mounted at /app/blackjack on the shared domain. Requests are
// stripped to the app's own root, assets are served through the assets binding,
// and the workers.dev URL still works without the prefix.

import { fromRequest, issue } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/blackjack/blackjack/generated/targets.ts";

export { BlackjackTable } from "./room.ts";

const BASE = "/app/blackjack";

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

    if (path === "/rpc") {
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

    const asset = new URL(url);
    asset.pathname = path;
    return env.ASSETS.fetch(asset);
  },
};

function tableName(raw: string | null) {
  const cleaned = (raw ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}
