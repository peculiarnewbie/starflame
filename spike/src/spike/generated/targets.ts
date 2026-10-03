// GENERATED (hand-written for the spike): Cap'n Web RpcTarget classes. Gleam
// can't define JS classes, so these are thin shells that forward to the
// dispatchers in server.gleam.

import { RpcTarget } from "capnweb";
import * as server from "./server.mjs";
import * as runtime from "../../../cf_gleam/cf_gleam/server.mjs";

export class Api extends RpcTarget {
  #context: runtime.Context$;

  constructor(context: runtime.Context$) {
    super();
    this.#context = context;
  }

  get_user(id: unknown) {
    return server.get_user(this.#context, id);
  }

  list_users(role: unknown) {
    return server.list_users(this.#context, role);
  }

  login(name: unknown) {
    return server.login(this.#context, name);
  }

  count_slowly(to: unknown, on_progress: unknown) {
    return server.count_slowly(this.#context, to, on_progress);
  }

  echo_everything(everything: unknown) {
    return server.echo_everything(this.#context, everything);
  }

  crash(reason: unknown) {
    return server.crash(this.#context, reason);
  }
}

class SessionTarget extends RpcTarget {
  #session: unknown;

  constructor(session: unknown) {
    super();
    this.#session = session;
  }

  me() {
    return server.session_me(this.#session as never);
  }

  rename(name: unknown) {
    return server.session_rename(this.#session as never, name);
  }
}

export function newSessionTarget(session: unknown) {
  return new SessionTarget(session);
}

export function newApi(env: unknown, execution: unknown) {
  return new Api(runtime.new_context(env, execution));
}
