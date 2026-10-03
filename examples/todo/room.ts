import { DurableObject } from "cloudflare:workers";
import { newWorkersRpcResponse, RpcTarget, type RpcStub } from "capnweb";
import { newApi } from "./build/dev/javascript/todos/todos/generated/targets.ts";
import * as ui from "./build/dev/javascript/todos/todos/server_ui.mjs";
import type { Todo$ } from "./build/dev/javascript/todos/todos/shared.mjs";

type Todo = Pick<Todo$, "id" | "title" | "done">;
type Change =
  | { $: "Snapshot"; todos: Todo[] }
  | { $: "Upsert"; todo: Todo }
  | { $: "Removed"; id: number }
  | { $: "CompletedCleared" };
type Reply<T> = { $: "Ok"; 0: T } | { $: "Error"; 0: unknown };
type Listener = RpcStub<(change: Change) => void>;

// One coordinator per shared list. D1 remains the source of persistent data.
// Standard WebSockets keep Lustre runtimes and Cap'n Web sessions alive.
export class TodoRoom extends DurableObject<Env> {
  #listeners = new Set<(change: Change) => void>();
  #queue: Promise<unknown> = Promise.resolve();

  // Serialize snapshots and writes so subscribers see events in commit order.
  run<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.#queue.then(operation);
    this.#queue = pending.catch(() => undefined);
    return pending;
  }

  listen(listener: (change: Change) => void) {
    this.#listeners.add(listener);
    return () => { this.#listeners.delete(listener); };
  }

  publish(change: Change) {
    for (const listener of this.#listeners) {
      try { listener(change); }
      catch { this.#listeners.delete(listener); }
    }
  }

  async fetch(request: Request) {
    const api = new RoomApi(this, newApi(this.env, this.ctx));
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
    const unlisten = this.listen((change) => { ui.change(runtime, change); });
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

class RoomApi extends RpcTarget {
  #room: TodoRoom;
  #api: ReturnType<typeof newApi>;
  #listener?: Listener;
  #unlisten?: () => void;

  constructor(room: TodoRoom, api: ReturnType<typeof newApi>) {
    super();
    this.#room = room;
    this.#api = api;
  }

  list_todos(): Promise<Todo[]> {
    return this.#room.run(() => this.#api.list_todos());
  }

  subscribe(listener: Listener) {
    if (typeof listener !== "function" || typeof listener.dup !== "function") {
      throw new TypeError("Expected an RPC callback");
    }
    this[Symbol.dispose]();
    const retained = listener.dup();
    this.#listener = retained;
    return this.#room.run(async () => {
      if (this.#listener !== retained) return;
      const notify = (change: Change) => {
        void Promise.resolve(retained(change)).catch(() => {
          if (this.#listener === retained) this[Symbol.dispose]();
        });
      };
      this.#unlisten = this.#room.listen(notify);
      const todos: Todo[] = await this.#api.list_todos();
      notify({ $: "Snapshot", todos });
    });
  }

  add_todo(title: unknown) {
    return this.#room.run(async () => {
      const reply: Reply<Todo> = await this.#api.add_todo(title);
      if (reply.$ === "Ok") this.#room.publish({ $: "Upsert", todo: reply[0] });
      return reply;
    });
  }

  set_done(id: unknown, done: unknown) {
    return this.#room.run(async () => {
      const reply: Reply<Todo> = await this.#api.set_done(id, done);
      if (reply.$ === "Ok") this.#room.publish({ $: "Upsert", todo: reply[0] });
      return reply;
    });
  }

  delete_todo(id: unknown) {
    return this.#room.run(async () => {
      const reply: Reply<null> = await this.#api.delete_todo(id);
      if (reply.$ === "Ok" && typeof id === "number") {
        this.#room.publish({ $: "Removed", id });
      }
      return reply;
    });
  }

  clear_completed() {
    return this.#room.run(async () => {
      const count: number = await this.#api.clear_completed();
      this.#room.publish({ $: "CompletedCleared" });
      return count;
    });
  }

  [Symbol.dispose]() {
    this.#unlisten?.();
    this.#unlisten = undefined;
    this.#listener?.[Symbol.dispose]();
    this.#listener = undefined;
  }
}
