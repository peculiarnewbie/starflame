// The Worker entrypoint, serving the generated Cap'n Web target.

import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/spike/spike/generated/targets.ts";

export default {
  async fetch(request: Request, env: unknown, execution: ExecutionContext) {
    const url = new URL(request.url);

    if (url.pathname === "/rpc" || url.pathname === "/private") {
      // Cap'n Web doesn't check Origin, and browsers allow cross-site
      // WebSockets, so reject other sites here.
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      // Stands in for real authentication: `?as=<name>` signs in.
      const name = url.searchParams.get("as");
      if (url.pathname === "/private" && name === null) {
        return new Response("Unauthorized", { status: 401 });
      }
      const auth = name === null ? undefined : { name };
      return newWorkersRpcResponse(request, newApi(env, execution, auth));
    }

    return new Response("Not found", { status: 404 });
  },
};
