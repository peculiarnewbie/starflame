import { DurableObject } from "cloudflare:workers";
import { fromRequest } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse, RpcTarget } from "capnweb";
import { newApi } from "./build/dev/javascript/chat/chat/generated/targets.ts";

type Reply<T> = { $: "Ok"; 0: T } | { $: "Error"; 0: unknown };
type Identity = { player: string; room: string };

// One chat room per Durable Object. Sockets are hibernating: the object keeps
// no per-connection state in memory, only the attachment on each socket, so an
// eviction between messages costs nothing.
export class ChatRoom extends DurableObject<Env> {
  #queue: Promise<unknown> = Promise.resolve();

  get roomName(): string {
    return this.ctx.id.name ?? "lobby";
  }

  run<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.#queue.then(operation);
    this.#queue = pending.catch(() => undefined);
    return pending;
  }

  api(identity: Identity) {
    return newApi(this.env, this.ctx, identity);
  }

  async fetch(request: Request) {
    const session = await fromRequest(request);
    if (!session) return new Response("Missing session", { status: 401 });
    const identity: Identity = { player: session.player, room: this.roomName };

    if (new URL(request.url).pathname === "/socket") {
      return this.open(request, identity);
    }
    return newWorkersRpcResponse(request, new RoomApi(this, identity));
  }

  // Hibernation API: the socket lives in the runtime, not in this object.
  open(request: Request, identity: Identity) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket required", { status: 426 });
    }
    const name = (new URL(request.url).searchParams.get("name") ?? "")
      .trim()
      .slice(0, 24);
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [identity.player]);
    server.serializeAttachment({ player: identity.player, name });
    this.broadcast({ $: "Presence", online: this.online() });
    return new Response(null, { status: 101, webSocket: client });
  }

  broadcast(event: unknown) {
    const payload = JSON.stringify(event);
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.send(payload);
      } catch {
        // A closed socket is removed by the runtime.
      }
    }
  }

  online(): number {
    let online = 0;
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.readyState === WebSocket.OPEN) online++;
    }
    return online;
  }

  webSocketMessage(_socket: WebSocket, _message: string | ArrayBuffer) {
    // Clients don't send anything: actions go over HTTP RPC.
  }

  webSocketClose(_socket: WebSocket) {
    this.broadcast({ $: "Presence", online: this.online() });
  }

  webSocketError(_socket: WebSocket) {
    this.broadcast({ $: "Presence", online: this.online() });
  }
}

class RoomApi extends RpcTarget {
  #room: ChatRoom;
  #identity: Identity;

  constructor(room: ChatRoom, identity: Identity) {
    super();
    this.#room = room;
    this.#identity = identity;
  }

  send(name: string, body: string) {
    return this.#room.run(async () => {
      const api = this.#room.api(this.#identity);
      const reply = (await api.send(name, body)) as Reply<Record<string, unknown>>;
      if (reply.$ === "Ok") {
        // The reply is already in wire form; wrapping it keeps the push
        // channel on the same codecs the client decodes.
        this.#room.broadcast({ $: "MessagePosted", message: reply[0] });
      }
      return reply;
    });
  }

  history() {
    return this.#room.run(async () => {
      const api = this.#room.api(this.#identity);
      return api.history();
    });
  }
}
