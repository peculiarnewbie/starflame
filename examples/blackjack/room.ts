import { DurableObject } from "cloudflare:workers";
import { fromRequest } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse } from "capnweb";
import { newApi } from "./build/dev/javascript/blackjack/blackjack/generated/targets.ts";

// Gleam owns serialization, typed player views, and subscription lifetimes.
export class BlackjackTable extends DurableObject<Env> {
  async fetch(request: Request) {
    const session = await fromRequest(request);
    if (!session) return new Response("Missing session", { status: 401 });
    return newWorkersRpcResponse(request, newApi(this.env, this.ctx, {
      player: session.player,
      table: this.ctx.id.name ?? "lobby",
    }));
  }
}
