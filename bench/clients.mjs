// How each transport calls the five methods, as that framework's own client
// would. Every client returns the decoded result.

import { newHttpBatchRpcSession, newWebSocketRpcSession } from "capnweb";
import * as devalue from "devalue";

export const todos = Array.from({ length: 50 }, (_, index) => ({
  id: index + 1,
  title: `Todo number ${index + 1} with a realistic title`,
  done: index % 3 === 0,
}));

/// The calls, with arguments; `id` varies per call.
export const operations = {
  ping: () => ["ping", 1],
  echo: () => ["echo_todos", todos],
  list: () => ["list_todos"],
  get: () => ["get_todo", 1 + Math.floor(Math.random() * 1000)],
  add: () => ["add_todo", "A todo added during the benchmark"],
};

export function client(transport, base, details) {
  switch (transport) {
    case "capnweb-ws":
      return {
        // One WebSocket session per virtual user, one call in flight.
        open: () => newWebSocketRpcSession(`${base.replace("http", "ws")}/rpc`),
        call: (session, method, ...args) => session[method](...args),
        close: (session) => session[Symbol.dispose](),
      };
    case "capnweb-http":
      return {
        // Cap'n Web's HTTP batch: a session per call, one POST per batch.
        open: () => null,
        call: (_, method, ...args) => newHttpBatchRpcSession(`${base}/rpc`)[method](...args),
        close: () => {},
      };
    case "http-json":
      return { open: () => null, call: (_, ...call) => httpJson(base, ...call), close: () => {} };
    case "sveltekit":
      return {
        open: () => null,
        call: (_, ...call) => sveltekit(`${base}/_app/remote/${details.remote}`, ...call),
        close: () => {},
      };
    default:
      throw new Error(`Unknown transport ${transport}`);
  }
}

async function json(response) {
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  return response.json();
}

function post(url, body) {
  return fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function httpJson(base, method, arg) {
  switch (method) {
    case "ping":
      return post(`${base}/api/ping`, arg).then(json);
    case "echo_todos":
      return post(`${base}/api/echo`, arg).then(json);
    case "list_todos":
      return fetch(`${base}/api/todos`).then(json);
    case "get_todo":
      return fetch(`${base}/api/todos/${arg}`).then(json);
    case "add_todo":
      return post(`${base}/api/todos`, arg).then(json);
  }
}

// What SvelteKit's generated client does: queries are GETs with a base64url
// devalue payload, commands are POSTs. Both reply with devalue inside JSON,
// the value under `_`.
const commands = new Set(["echo_todos", "add_todo"]);

async function sveltekit(base, method, arg) {
  const payload = arg === undefined ? "" : base64url(devalue.stringify(arg));
  // A browser sends Origin; SvelteKit refuses cross-site commands without it.
  const headers = {
    origin: new URL(base).origin,
    "x-sveltekit-pathname": "/",
    "x-sveltekit-search": "",
  };
  const response = commands.has(method)
    ? await fetch(`${base}/${method}`, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({ payload, refreshes: [] }),
      })
    : await fetch(`${base}/${method}${payload ? `?payload=${payload}` : ""}`, { headers });
  const reply = await json(response);
  if (reply.type !== "result") throw new Error(JSON.stringify(reply));
  return devalue.parse(reply.data)._;
}

function base64url(text) {
  return Buffer.from(text).toString("base64url");
}
