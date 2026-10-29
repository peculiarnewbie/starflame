// The Worker entrypoint: sessions, RPC, and serving objects straight from R2.

import { fromRequest, issue } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/photos/photos/generated/targets.ts";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);

    if (url.pathname === "/session") return issue();

    if (url.pathname === "/rpc") {
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      const session = await fromRequest(request);
      if (!session) return new Response("Missing session", { status: 401 });
      return newWorkersRpcResponse(request, newApi(env, ctx, session.player));
    }

    // Served from R2 directly, so images stream instead of crossing RPC.
    if (url.pathname.startsWith("/photos/")) {
      const id = decodeURIComponent(url.pathname.slice("/photos/".length));
      const object = await env.BUCKET.get(`photos/${id}`);
      if (!object) return new Response("Not found", { status: 404 });
      return new Response(object.body, {
        headers: {
          "content-type": object.httpMetadata?.contentType ?? "application/octet-stream",
          "cache-control": "public, max-age=31536000, immutable",
          etag: object.httpEtag,
        },
      });
    }

    return new Response("Not found", { status: 404 });
  },
};
