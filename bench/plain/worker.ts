// A bare fetch handler with the same routes as the Hono app: the floor for
// an HTTP request in this runtime.

import { addTodo, getTodo, isInt, isTodoList, listTodos } from "../shared/todos.ts";

type Env = { DB: D1Database };

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });

export default {
  async fetch(request: Request, env: Env) {
    const { pathname } = new URL(request.url);
    const post = request.method === "POST";
    if (post && pathname === "/api/ping") {
      const n = await request.json();
      return isInt(n) ? json(n + 1) : json({ error: "n" }, 400);
    }
    if (post && pathname === "/api/echo") {
      const todos = await request.json();
      return isTodoList(todos) ? json(todos) : json({ error: "todos" }, 400);
    }
    if (pathname === "/api/todos") {
      if (!post) return json(await listTodos(env.DB));
      const title = await request.json();
      if (typeof title !== "string") return json({ error: "title" }, 400);
      return json(await addTodo(env.DB, title));
    }
    if (pathname.startsWith("/api/todos/")) {
      const id = Number(pathname.slice("/api/todos/".length));
      return isInt(id) ? json(await getTodo(env.DB, id)) : json({ error: "id" }, 400);
    }
    return new Response("Not found", { status: 404 });
  },
};
