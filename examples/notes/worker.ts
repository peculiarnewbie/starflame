// The Worker: sign-in routes, the RPC API for signed-in users, and the
// static app for everything else.

import { newHttpBatchRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/notes/notes/generated/targets.ts";
import * as openauth from "./build/dev/javascript/starflame_openauth/starflame_openauth.mjs";
import { auth } from "./build/dev/javascript/notes/notes/auth.mjs";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);
    const config = auth();

    if (openauth.handles(config, request)) {
      return openauth.route(config, request, env, ctx);
    }

    if (url.pathname === "/rpc") {
      // Calls are POSTs from this site. The auth cookies are SameSite=Lax, so
      // other sites' requests aren't signed in anyway; this refuses them early.
      const origin = request.headers.get("Origin");
      if (request.method !== "POST" || origin !== url.origin) {
        return new Response("Forbidden", { status: 403 });
      }
      return openauth.authenticated(config, request, env, ctx, (user) =>
        newHttpBatchRpcResponse(request, newApi(env, ctx, user)),
      );
    }

    return env.ASSETS.fetch(request);
  },
};
