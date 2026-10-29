import { DurableObject } from "cloudflare:workers";
import { newWorkersRpcResponse, RpcTarget, type RpcStub } from "capnweb";
import { newApi } from "./build/dev/javascript/blackjack/blackjack/generated/targets.ts";

type View = Record<string, unknown>;
type Reply<T> = { $: "Ok"; 0: T } | { $: "Error"; 0: unknown };
type Listener = RpcStub<(view: View) => void>;

// One Durable Object per table. The table lives in D1 and the API loads and
// saves it, so this object only serializes calls, binds identity, and fans
// views out to subscribers.
export class BlackjackTable extends DurableObject<Env> {
  #queue: Promise<unknown> = Promise.resolve();
  #listeners = new Map<string, Set<(view: View) => void>>();

  // Serialize calls so two players acting at once can't interleave a read and
  // a write.
  run<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.#queue.then(operation);
    this.#queue = pending.catch(() => undefined);
    return pending;
  }

  get tableName(): string {
    return this.ctx.id.name ?? "lobby";
  }

  // Identity and table scope travel as `auth`, so the API never reads either
  // from a caller-supplied argument.
  api(player: string) {
    return newApi(this.env, this.ctx, { player, table: this.tableName });
  }

  listen(playerId: string, listener: (view: View) => void): () => void {
    let listeners = this.#listeners.get(playerId);
    if (!listeners) {
      listeners = new Set();
      this.#listeners.set(playerId, listeners);
    }
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0) this.#listeners.delete(playerId);
    };
  }

  publish(views: Array<[string, View]>) {
    for (const [playerId, view] of views) {
      const listeners = this.#listeners.get(playerId);
      if (!listeners) continue;
      for (const listener of listeners) {
        try {
          listener(view);
        } catch {
          listeners.delete(listener);
        }
      }
    }
  }

  async fetch(request: Request) {
    const session = new URL(request.url).searchParams.get("session") ?? "";
    if (session.length < 8 || session.length > 128) {
      return new Response("Missing session", { status: 401 });
    }
    const player = await playerId(session);
    return newWorkersRpcResponse(request, new TableApi(this, player));
  }
}

class TableApi extends RpcTarget {
  #table: BlackjackTable;
  #player: string;
  #listener?: Listener;
  #unlisten?: () => void;

  constructor(table: BlackjackTable, player: string) {
    super();
    this.#table = table;
    this.#player = player;
  }

  // Only the caller's own view goes back. The DO fans every player's view out
  // through subscribe, so no client receives another player's payload.
  join(name: string) {
    return this.#table.run(async () => {
      const api = this.#table.api(this.#player);
      const reply = (await api.join(name)) as Reply<View>;
      if (reply.$ === "Ok") {
        this.#table.publish((await api.all_views()) as Array<[string, View]>);
      }
      return reply;
    });
  }

  act(action: unknown) {
    return this.#table.run(async () => {
      const api = this.#table.api(this.#player);
      const reply = (await api.act(action)) as Reply<View>;
      if (reply.$ === "Ok") {
        this.#table.publish((await api.all_views()) as Array<[string, View]>);
      }
      return reply;
    });
  }

  refresh() {
    return this.#table.run(() => this.#table.api(this.#player).refresh());
  }

  subscribe(listener: Listener) {
    if (typeof listener !== "function" || typeof listener.dup !== "function") {
      throw new TypeError("Expected an RPC callback");
    }
    this[Symbol.dispose]();
    const retained = listener.dup();
    this.#listener = retained;
    return this.#table.run(async () => {
      const api = this.#table.api(this.#player);
      const notify = (view: View) => {
        void Promise.resolve(retained(view)).catch(() => {
          if (this.#listener === retained) this[Symbol.dispose]();
        });
      };
      this.#unlisten = this.#table.listen(this.#player, notify);
      notify((await api.refresh()) as View);
    });
  }

  [Symbol.dispose]() {
    this.#unlisten?.();
    this.#unlisten = undefined;
    this.#listener?.[Symbol.dispose]();
    this.#listener = undefined;
  }
}

// The session token is a bearer credential, so it never appears in a view. The
// player id is a hash of it: stable across reconnects, useless for forging.
async function playerId(session: string): Promise<string> {
  const encoded = new TextEncoder().encode(session);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest).slice(0, 8))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
