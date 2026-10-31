export function reject(message) {
  return Promise.reject(new TypeError(message));
}

export function isFunction(value) {
  return typeof value === "function";
}

export function callStub(stub, args) {
  // Fire-and-forget: swallow failures so they don't become unhandled rejections.
  try {
    Promise.resolve(stub(...args.toArray())).catch(() => {});
  } catch {
    // A disposed callback may reject synchronously. It must not fail a write
    // that already committed, or prevent the remaining subscribers receiving it.
  }
}

// The Gleam value, rather than an individual target, owns these resources:
// serializing the same capability twice must not close it on the first release.
const lifetimes = new WeakMap();
const queues = new WeakMap();

export function serialise(execution, operation) {
  const pending = (queues.get(execution) ?? Promise.resolve()).then(operation);
  queues.set(execution, pending.then(() => {}, () => {}));
  return pending;
}

function lifetime(value) {
  let state = lifetimes.get(value);
  if (!state) {
    state = { references: 0, cleanup: [], disposed: false };
    lifetimes.set(value, state);
  }
  return state;
}

export function withDispose(value, cleanup) {
  const state = lifetime(value);
  if (state.disposed) cleanup();
  else state.cleanup.push(cleanup);
  return value;
}

export function retainCapability(value) {
  const state = lifetime(value);
  if (state.disposed) throw new Error("The capability is disposed");
  state.references++;
}

export function releaseCapability(value) {
  const state = lifetimes.get(value);
  if (!state || state.references === 0 || --state.references !== 0) return;
  state.disposed = true;
  // Finish every cleanup even if an application cleanup throws.
  let failure;
  let failed = false;
  for (const cleanup of state.cleanup.splice(0).reverse()) {
    try {
      cleanup();
    } catch (error) {
      if (!failed) failure = error;
      failed = true;
    }
  }
  if (failed) throw failure;
}

export function retainCallback(owner, stub) {
  const retained = typeof stub.dup === "function" ? stub.dup() : stub;
  if (retained !== stub || typeof stub.dup === "function") {
    withDispose(owner, () => retained[Symbol.dispose]());
  }
  return retained;
}
