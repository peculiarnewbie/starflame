import { DurableObject } from "cloudflare:workers";
import { fromRequest } from "@starflame/runtime/session.ts";
import { newWorkersRpcResponse, RpcTarget, type RpcStub } from "capnweb";
import { newApi } from "./build/dev/javascript/canvas/canvas/generated/targets.ts";

type Reply<T> = { $: "Ok"; 0: T } | { $: "Error"; 0: unknown };
type Identity = { player: string; room: string };
type Listener = RpcStub<(event: unknown) => void>;

// One board per Durable Object. The root target hands out a *capability*: an
// editor gets a BoardApi, a viewer gets a BoardViewApi that has no add/clear
// methods at all, so read-only is enforced by the shape of the object.
export class CanvasBoard extends DurableObject<Env> {
  #queue: Promise<unknown> = Promise.resolve();
  #listeners = new Set<(event: unknown) => void>();

  get roomName(): string {
    return this.ctx.id.name ?? "lobby";
  }

  api(identity: Identity) {
    return newApi(this.env, this.ctx, identity);
  }

  run<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.#queue.then(operation);
    this.#queue = pending.catch(() => undefined);
    return pending;
  }

  listen(listener: (event: unknown) => void): () => void {
    this.#listeners.add(listener);
    this.publishPresence();
    return () => {
      this.#listeners.delete(listener);
      this.publishPresence();
    };
  }

  publish(event: unknown) {
    for (const listener of this.#listeners) {
      try {
        listener(event);
      } catch {
        this.#listeners.delete(listener);
      }
    }
  }

  publishPresence() {
    this.publish({ $: "Presence", online: this.#listeners.size });
  }

  async fetch(request: Request) {
    const session = await fromRequest(request);
    if (!session) return new Response("Missing session", { status: 401 });
    const identity: Identity = { player: session.player, room: this.roomName };
    return newWorkersRpcResponse(request, new RootApi(this, identity));
  }
}

class RootApi extends RpcTarget {
  #room: CanvasBoard;
  #identity: Identity;

  constructor(room: CanvasBoard, identity: Identity) {
    super();
    this.#room = room;
    this.#identity = identity;
  }

  enter(read_only: boolean) {
    return {
      board: read_only
        ? new BoardViewApi(this.#room, this.#identity)
        : new BoardApi(this.#room, this.#identity),
    };
  }
}

class BoardViewApi extends RpcTarget {
  #room: CanvasBoard;
  #identity: Identity;
  #unlisten?: () => void;
  #listener?: Listener;

  constructor(room: CanvasBoard, identity: Identity) {
    super();
    this.#room = room;
    this.#identity = identity;
  }

  snapshot() {
    return this.#room.run(() => this.#room.api(this.#identity).snapshot());
  }

  subscribe(listener: Listener) {
    if (typeof listener !== "function" || typeof listener.dup !== "function") {
      throw new TypeError("Expected an RPC callback");
    }
    this[Symbol.dispose]();
    const retained = listener.dup();
    this.#listener = retained;
    this.#unlisten = this.#room.listen((event) => {
      void Promise.resolve(retained(event)).catch(() => {});
    });
    return Promise.resolve(undefined);
  }

  [Symbol.dispose]() {
    this.#unlisten?.();
    this.#unlisten = undefined;
    this.#listener?.[Symbol.dispose]();
    this.#listener = undefined;
  }
}

// Editing methods exist only on this capability.
class BoardApi extends BoardViewApi {
  #room: CanvasBoard;
  #identity: Identity;

  constructor(room: CanvasBoard, identity: Identity) {
    super(room, identity);
    this.#room = room;
    this.#identity = identity;
  }

  add(draft: unknown) {
    return this.#room.run(async () => {
      const reply = (await this.#room.api(this.#identity).add_stroke(draft)) as Reply<
        Record<string, unknown>
      >;
      if (reply.$ === "Ok") {
        this.#room.publish({ $: "StrokeAdded", stroke: reply[0] });
      }
      return reply;
    });
  }

  clear() {
    return this.#room.run(async () => {
      const reply = (await this.#room.api(this.#identity).clear()) as Reply<null>;
      this.#room.publish({ $: "Cleared" });
      return reply;
    });
  }
}
