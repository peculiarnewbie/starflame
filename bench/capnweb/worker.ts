// Cap'n Web without Starflame: the same methods written directly in
// TypeScript, to separate Starflame's overhead from Cap'n Web's.

import { newWorkersRpcResponse, RpcTarget } from "capnweb";
import { addTodo, getTodo, isInt, isTodoList, listTodos } from "../shared/todos.ts";

type Env = { DB: D1Database };

class Api extends RpcTarget {
  #env: Env;

  constructor(env: Env) {
    super();
    this.#env = env;
  }

  ping(n: unknown) {
    if (!isInt(n)) throw new TypeError("Invalid RPC argument: n");
    return n + 1;
  }

  echo_todos(todos: unknown) {
    if (!isTodoList(todos)) throw new TypeError("Invalid RPC argument: todos");
    return todos;
  }

  list_todos() {
    return listTodos(this.#env.DB);
  }

  get_todo(id: unknown) {
    if (!isInt(id)) throw new TypeError("Invalid RPC argument: id");
    return getTodo(this.#env.DB, id);
  }

  add_todo(title: unknown) {
    if (typeof title !== "string") throw new TypeError("Invalid RPC argument: title");
    return addTodo(this.#env.DB, title);
  }
}

export default {
  async fetch(request: Request, env: Env) {
    if (new URL(request.url).pathname === "/rpc") {
      return newWorkersRpcResponse(request, new Api(env));
    }
    return new Response("Not found", { status: 404 });
  },
};
