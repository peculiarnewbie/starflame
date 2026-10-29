// The Worker entrypoint: sessions, RPC, and serving objects straight from R2.

import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/photos/photos/generated/targets.ts";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);

    // The token is the credential: the API derives the owner from its hash.
    if (url.pathname === "/session") {
      return Response.json(
        { session: crypto.randomUUID() },
        { headers: { "cache-control": "no-store" } },
      );
    }

    if (url.pathname === "/rpc") {
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      const session = url.searchParams.get("session") ?? "";
      if (session.length < 8 || session.length > 128) {
        return new Response("Missing session", { status: 401 });
      }
      const player = await playerId(session);
      return newWorkersRpcResponse(request, newApi(env, ctx, player));
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

// The session token is a bearer credential; the owner id is a hash of it, so
// the id can be shown in the UI without leaking the credential.
async function playerId(session: string): Promise<string> {
  const encoded = new TextEncoder().encode(session);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest).slice(0, 8))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
