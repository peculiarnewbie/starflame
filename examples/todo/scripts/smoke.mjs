import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { newHttpBatchRpcSession } from "capnweb";
import * as client from "../build/dev/javascript/todos/todos/generated/client.mjs";
import * as app from "../build/dev/javascript/todos/todos/client.mjs";
import { Result$Ok } from "../build/dev/javascript/todos/gleam.mjs";

// Usage: pnpm smoke [https://your-worker.workers.dev]
// Creates and removes only its own todo, so it can also check a shared demo.
const base = new URL(process.argv[2] ?? "http://localhost:5173");
const rpc = new URL("/rpc", base);
const websocket = new URL(rpc);
websocket.protocol = base.protocol === "https:" ? "wss:" : "ws:";
const title = `Starflame smoke ${randomUUID()}`;
let session = client.connect(websocket.href);
let id;

const unwrap = (reply) => {
  assert.ok(reply.isOk(), `Unexpected error: ${JSON.stringify(reply)}`);
  return reply[0];
};

try {
  const page = await fetch(base);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /todos · starflame/);
  const forbidden = await fetch(rpc, { headers: { Origin: "https://other.example" } });
  assert.equal(forbidden.status, 403);

  const empty = unwrap(await client.add_todo(session, "   "));
  assert.ok(!empty.isOk());
  assert.equal(empty[0].constructor.name, "EmptyTitle");
  const long = unwrap(await client.add_todo(session, "x".repeat(201)));
  assert.ok(!long.isOk());
  assert.equal(long[0].max, 200);

  const before = unwrap(await client.list_todos(session));
  const [initial] = app.init_with_api(session, app.Mode$Server$const);
  const added = await client.add_todo(session, `  ${title}  `);
  const todo = unwrap(unwrap(added));
  id = todo.id;
  assert.equal(todo.title, title);
  assert.equal(todo.done, false);
  console.log("PASS assets, origin check, typed validation, and create over WebSocket");

  // Deliver real replies out of order: a pre-mutation snapshot must not erase
  // the successful add response. The client schedules a fresh snapshot instead.
  const [after] = app.update(initial, app.Msg$ApiAddedTodo(added));
  const [afterStaleSnapshot] = app.update(after, app.Msg$ApiReturnedTodos(0, Result$Ok(before)));
  assert.equal(afterStaleSnapshot, after);
  console.log("PASS delayed snapshot cannot overwrite a newer mutation");

  client.dispose(session);
  session = client.connect(websocket.href);
  const todos = unwrap(await client.list_todos(session)).toArray();
  assert.ok(todos.some((item) => item.id === id && item.title === title));
  const updated = unwrap(unwrap(await client.set_done(session, id, true)));
  assert.equal(updated.done, true);
  const httpTodos = await newHttpBatchRpcSession(rpc.href).list_todos();
  assert.ok(httpTodos.some((item) => item.id === id && item.done === true));
  console.log("PASS persistence across sessions, update, and HTTP batch RPC");

  unwrap(unwrap(await client.delete_todo(session, id)));
  const missing = unwrap(await client.set_done(session, id, false));
  assert.ok(!missing.isOk());
  assert.equal(missing[0].id, id);
  assert.ok(!unwrap(await client.list_todos(session)).toArray().some((item) => item.id === id));
  id = undefined;
  console.log("PASS delete and typed not-found error");
} finally {
  try {
    if (id !== undefined) unwrap(unwrap(await client.delete_todo(session, id)));
  } finally {
    client.dispose(session);
  }
}
