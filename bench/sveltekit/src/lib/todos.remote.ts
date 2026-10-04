// SvelteKit remote functions: the same methods as the other apps, with
// valibot validating arguments as SvelteKit expects.

import { command, query } from "$app/server";
import { env } from "cloudflare:workers";
import * as v from "valibot";
import { addTodo, getTodo, listTodos } from "../../../shared/todos.ts";

const todo = v.object({
  id: v.pipe(v.number(), v.safeInteger()),
  title: v.string(),
  done: v.boolean(),
});

function db(): D1Database {
  return (env as { DB: D1Database }).DB;
}

export const ping = query(v.pipe(v.number(), v.safeInteger()), (n) => n + 1);

// A command, since a query would put 50 todos in the URL.
export const echo_todos = command(v.array(todo), (todos) => todos);

export const list_todos = query(() => listTodos(db()));

export const get_todo = query(v.pipe(v.number(), v.safeInteger()), (id) =>
  getTodo(db(), id),
);

export const add_todo = command(v.string(), (title) => addTodo(db(), title));
