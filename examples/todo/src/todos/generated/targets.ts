// GENERATED (hand-written for now): Cap'n Web RpcTarget classes forwarding to
// the dispatchers in server.gleam.

import { RpcTarget } from "capnweb";
import * as server from "./server.mjs";
import * as runtime from "../../../starflame/starflame/server.mjs";

export class Api extends RpcTarget {
  #context: runtime.Context$;

  constructor(context: runtime.Context$) {
    super();
    this.#context = context;
  }

  list_todos() {
    return server.list_todos(this.#context);
  }

  add_todo(title: unknown) {
    return server.add_todo(this.#context, title);
  }

  set_done(id: unknown, done: unknown) {
    return server.set_done(this.#context, id, done);
  }

  delete_todo(id: unknown) {
    return server.delete_todo(this.#context, id);
  }

  clear_completed() {
    return server.clear_completed(this.#context);
  }
}

export function newApi(env: unknown, execution: unknown) {
  return new Api(runtime.new_context(env, execution));
}
