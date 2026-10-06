import { newHttpBatchRpcSession, newWebSocketRpcSession } from "capnweb";
import { Result$Ok, Result$Error } from "../gleam.mjs";
import { RpcError$Remote, RpcError$Http } from "./client.mjs";

export function connect(url) {
  return newWebSocketRpcSession(url);
}

// An HTTP batch session ends with its request, so every call gets its own.
// Nothing stays open, so there's nothing to break or dispose.
export function connectHttp(url) {
  return new Proxy({}, {
    get(_, key) {
      if (key === "onRpcBroken" || key === Symbol.dispose) return () => {};
      return (...args) => newHttpBatchRpcSession(url)[key](...args);
    },
  });
}

export function sameOriginUrl(path) {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${location.host}${path}`;
}

export function onBroken(stub, callback) {
  stub.onRpcBroken((error) => callback(String(error?.message ?? error)));
}

export function dispose(stub) {
  stub[Symbol.dispose]();
}

export async function call(stub, method, args) {
  try {
    return Result$Ok(await stub[method](...args.toArray()));
  } catch (error) {
    const message = String(error?.message ?? error);
    // How Cap'n Web reports an HTTP batch response that wasn't 2xx.
    const status = /^RPC request failed: (\d{3})\b/.exec(message);
    if (status) return Result$Error(RpcError$Http(Number(status[1])));
    return Result$Error(RpcError$Remote(message));
  }
}

// Cap'n Web calls a callback with its arguments spread out.
export function variadic(callback) {
  return (...args) => callback(args);
}
