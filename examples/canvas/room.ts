import { DurableObject } from "cloudflare:workers";
import { fromRequest } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/canvas/canvas/generated/targets.ts";

// The transport supplies the authenticated identity and Durable Object state.
// All RPC methods, event payloads, and capability lifetimes live in Gleam.
export class CanvasBoard extends DurableObject<Env> {
  async fetch(request: Request) {
    const session = await fromRequest(request);
    if (!session) return new Response("Missing session", { status: 401 });
    const identity = {
      player: session.player,
      room: this.ctx.id.name ?? "lobby",
    };
    return newWorkersRpcResponse(
      request,
      newApi(this.env, this.ctx, identity),
    );
  }
}
