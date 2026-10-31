import { DurableObject } from "cloudflare:workers";
import { newWorkersRpcResponse } from "capnweb";
import { Api } from "./build/dev/javascript/todos/todos/generated/targets.ts";
import * as ui from "./build/dev/javascript/todos/todos/server_ui.mjs";
import * as live from "./build/dev/javascript/todos/todos/live.mjs";
import { new_context } from "./build/dev/javascript/starflame/starflame/server.mjs";

// One coordinator per shared list. D1 remains the source of persistent data.
// Standard WebSockets keep Lustre runtimes and Cap'n Web sessions alive.
export class TodoRoom extends DurableObject<Env> {
  async fetch(request: Request) {
    const context = new_context(this.env, this.ctx);
    const api = new Api(context);
    if (new URL(request.url).pathname !== "/server/socket") {
      return newWorkersRpcResponse(request, api);
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket required", { status: 426 });
    }

    const pair = new WebSocketPair();
    const [client, socket] = Object.values(pair);
    socket.accept();
    const runtime = ui.start(api, (patch) => { socket.send(patch); });
    const unlisten = live.listen(context, (change) => { ui.change(runtime, change); });
    let closed = false;
    const close = () => {
      if (closed) return;
      closed = true;
      unlisten();
      ui.stop(runtime);
      api[Symbol.dispose]();
    };
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string" || !ui.receive(runtime, event.data)) {
        socket.close(1008, "Invalid Lustre message");
        close();
      }
    });
    socket.addEventListener("close", close);
    socket.addEventListener("error", close);
    return new Response(null, { status: 101, webSocket: client });
  }
}
