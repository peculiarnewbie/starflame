import assert from "node:assert/strict";
import test from "node:test";
import * as server from "../build/dev/javascript/starflame/starflame/server.mjs";
import * as topic from "../build/dev/javascript/starflame/starflame/topic.mjs";
import { toList } from "../build/dev/javascript/starflame/gleam.mjs";

test("serialization orders asynchronous operations and recovers from a rejection", async () => {
  const context = server.new_context({}, {});
  const order = [];
  const first = server.serialise(context, async () => {
    order.push("first starts");
    await new Promise((resolve) => setTimeout(resolve, 10));
    order.push("first ends");
    throw new Error("failed operation");
  });
  const second = server.serialise(context, async () => {
    order.push("second");
    return "recovered";
  });
  await assert.rejects(first, /failed operation/);
  assert.equal(await second, "recovered");
  assert.deepEqual(order, ["first starts", "first ends", "second"]);
});

test("a capability shared by two targets stays alive until both are released", () => {
  let closed = 0;
  const capability = server.with_dispose({}, () => closed++);
  server.retain_capability(capability);
  server.retain_capability(capability);
  server.release_capability(capability);
  assert.equal(closed, 0);
  server.release_capability(capability);
  server.release_capability(capability);
  assert.equal(closed, 1);
});

test("a stored RPC callback is retained past its call and released with its owner", async () => {
  const owner = {};
  const events = [];
  let released = 0;
  let retained;
  const stub = () => { throw new Error("The original call's stub was released"); };
  stub.dup = () => {
    const copy = (event) => events.push(event);
    copy[Symbol.dispose] = () => released++;
    return copy;
  };
  server.retain_capability(owner);
  await server.callback_for(owner, stub, async (callback) => {
    retained = callback;
  });
  retained(toList(["later"]));
  assert.deepEqual(events, ["later"]);
  assert.equal(released, 0);
  server.release_capability(owner);
  assert.equal(released, 1);
});

test("a synchronously broken callback cannot fail a committed event publisher", async () => {
  const owner = {};
  server.retain_capability(owner);
  await server.callback_for(owner, () => { throw new Error("closed peer"); }, async (callback) => {
    assert.doesNotThrow(() => callback(toList(["committed"])));
  });
  server.release_capability(owner);
});

test("one failed cleanup does not leave other capability resources alive", () => {
  const closed = [];
  const capability = server.with_dispose({}, () => closed.push("first"));
  server.with_dispose(capability, () => { throw new Error("cleanup failed"); });
  server.with_dispose(capability, () => closed.push("last"));
  server.retain_capability(capability);
  assert.throws(() => server.release_capability(capability), /cleanup failed/);
  assert.deepEqual(closed, ["last", "first"]);
});

test("resources created after an in-flight capability is disposed are closed immediately", () => {
  const owner = {};
  let closed = false;
  server.retain_capability(owner);
  server.release_capability(owner);
  server.with_dispose(owner, () => { closed = true; });
  assert.equal(closed, true);
  assert.throws(() => server.retain_capability(owner), /disposed/);
});

test("replacing a subscription keeps one listener and disposal updates presence once", () => {
  const events = topic.new$();
  const counts = [];
  const received = [];
  topic.on_count_change(events, (count) => counts.push(count));
  const subscription = topic.subscription(events);
  topic.listen(subscription, (event) => received.push(["old", event]));
  topic.publish(events, 1);
  topic.listen(subscription, (event) => received.push(["new", event]));
  topic.publish(events, 2);
  topic.dispose(subscription);
  topic.dispose(subscription);
  topic.publish(events, 3);
  assert.deepEqual(counts, [1, 0]);
  assert.deepEqual(received, [["old", 1], ["new", 2]]);
});

test("disposing a capability removes its subscription from the shared topic", () => {
  const events = topic.new$();
  const subscription = topic.subscription(events);
  const received = [];
  const capability = server.with_dispose({}, () => topic.dispose(subscription));
  server.retain_capability(capability);
  topic.listen(subscription, (event) => received.push(event));
  topic.publish(events, "before");
  server.release_capability(capability);
  topic.publish(events, "after");
  assert.deepEqual(received, ["before"]);
});
