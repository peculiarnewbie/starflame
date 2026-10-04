// Hono with JSON routes: the plain-Worker floor.

import { Hono } from "hono";
import { addTodo, getTodo, isInt, isTodoList, listTodos } from "../shared/todos.ts";

const app = new Hono<{ Bindings: { DB: D1Database } }>();

app.post("/api/ping", async (c) => {
  const n = await c.req.json();
  if (!isInt(n)) return c.json({ error: "n" }, 400);
  return c.json(n + 1);
});

app.post("/api/echo", async (c) => {
  const todos = await c.req.json();
  if (!isTodoList(todos)) return c.json({ error: "todos" }, 400);
  return c.json(todos);
});

app.get("/api/todos", async (c) => c.json(await listTodos(c.env.DB)));

app.get("/api/todos/:id", async (c) => {
  const id = Number(c.req.param("id"));
  if (!isInt(id)) return c.json({ error: "id" }, 400);
  return c.json(await getTodo(c.env.DB, id));
});

app.post("/api/todos", async (c) => {
  const title = await c.req.json();
  if (typeof title !== "string") return c.json({ error: "title" }, 400);
  return c.json(await addTodo(c.env.DB, title));
});

export default app;
