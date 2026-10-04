// Hand-written for now: the Worker entrypoint and Cap'n Web target.

import { newWorkersRpcResponse, RpcTarget } from "capnweb";
import * as server from "./build/dev/javascript/bench/bench/server.mjs";
import * as runtime from "./build/dev/javascript/starflame/starflame/server.mjs";

class Api extends RpcTarget {
  #context: runtime.Context$;

  constructor(context: runtime.Context$) {
    super();
    this.#context = context;
  }

  ping(n: unknown) {
    return server.ping(this.#context, n);
  }

  echo_todos(todos: unknown) {
    return server.echo_todos(this.#context, todos);
  }

  list_todos() {
    return server.list_todos(this.#context);
  }

  get_todo(id: unknown) {
    return server.get_todo(this.#context, id);
  }

  add_todo(title: unknown) {
    return server.add_todo(this.#context, title);
  }
}

export default {
  async fetch(request: Request, env: unknown, execution: ExecutionContext) {
    if (new URL(request.url).pathname === "/rpc") {
      return newWorkersRpcResponse(
        request,
        new Api(runtime.new_context(env, execution)),
      );
    }
    return new Response("Not found", { status: 404 });
  },
};
