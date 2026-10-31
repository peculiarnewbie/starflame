// The Worker entrypoint: sessions, RPC, and serving objects from R2.
// Mounted at /app/photos; requests are stripped to the app root.

import { fromRequest, issue } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/photos/photos/generated/targets.ts";

const BASE = "/app/photos";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);
    if (url.pathname === BASE) {
      return Response.redirect(`${url.origin}${BASE}/`, 308);
    }
    const path = url.pathname.startsWith(`${BASE}/`)
      ? url.pathname.slice(BASE.length)
      : url.pathname;

    if (path === "/session") return issue();

    if (path === "/rpc") {
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      const session = await fromRequest(request);
      if (!session) return new Response("Missing session", { status: 401 });
      return newWorkersRpcResponse(request, newApi(env, ctx, session.player));
    }

    if (path.startsWith("/photos/")) {
      const id = decodeURIComponent(path.slice("/photos/".length));
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

    const asset = new URL(url);
    asset.pathname = path;
    return env.ASSETS.fetch(asset);
  },
};
