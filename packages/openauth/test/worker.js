// The Worker test/run.mjs drives: sign-in routes, and /me behind them.

import * as openauth from "../build/dev/javascript/starflame_openauth/starflame_openauth.mjs";
import { auth } from "../build/dev/javascript/starflame_openauth/openauth_test_app.mjs";

export default {
  async fetch(request, env, ctx) {
    const config = auth();
    if (openauth.handles(config, request)) {
      return openauth.route(config, request, env, ctx);
    }
    if (new URL(request.url).pathname === "/me") {
      return openauth.authenticated(config, request, env, ctx, async (user) =>
        Response.json(user),
      );
    }
    return new Response("Not found", { status: 404 });
  },
};
