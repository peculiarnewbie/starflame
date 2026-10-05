// The Worker entrypoint, serving the generated Cap'n Web target.

import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/bench/bench/generated/targets.ts";

export default {
  async fetch(request: Request, env: unknown, execution: ExecutionContext) {
    if (new URL(request.url).pathname === "/rpc") {
      return newWorkersRpcResponse(request, newApi(env, execution));
    }
    return new Response("Not found", { status: 404 });
  },
};
