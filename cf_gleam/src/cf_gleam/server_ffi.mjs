export function reject(message) {
  return Promise.reject(new TypeError(message));
}

export function isFunction(value) {
  return typeof value === "function";
}

export function callStub(stub, args) {
  // Fire-and-forget: swallow failures so they don't become unhandled rejections.
  Promise.resolve(stub(...args.toArray())).catch(() => {});
}
