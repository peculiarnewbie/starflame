import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/starflame_external_check/ext/generated/targets.ts";

export default {
  fetch(request: Request) {
    return newWorkersRpcResponse(request, newApi({}, {}));
  },
};
