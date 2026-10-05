import { newWebSocketRpcSession } from "capnweb";
import { Result$Ok, Result$Error } from "../gleam.mjs";

export function connect(url) {
  return newWebSocketRpcSession(url);
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
    return Result$Error(String(error?.message ?? error));
  }
}

// Cap'n Web calls a callback with its arguments spread out.
export function variadic(callback) {
  return (...args) => callback(args);
}
