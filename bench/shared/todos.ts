// The D1 queries and argument checks the TypeScript apps share, matching
// what the Starflame app's decoders and generated module do.

export type Todo = { id: number; title: string; done: boolean };

type Row = { id: number; title: string; done: number };

const columns = "id, title, done";

function toTodo(row: Row): Todo {
  return { id: row.id, title: row.title, done: row.done === 1 };
}

export async function listTodos(db: D1Database): Promise<Todo[]> {
  const { results } = await db
    .prepare(`SELECT ${columns} FROM todos ORDER BY id LIMIT 50`)
    .all<Row>();
  return results.map(toTodo);
}

export async function getTodo(db: D1Database, id: number): Promise<Todo | null> {
  const row = await db
    .prepare(`SELECT ${columns} FROM todos WHERE id = ?`)
    .bind(id)
    .first<Row>();
  return row === null ? null : toTodo(row);
}

export async function addTodo(db: D1Database, title: string): Promise<Todo> {
  const row = await db
    .prepare(`INSERT INTO todos (title) VALUES (?) RETURNING ${columns}`)
    .bind(title)
    .first<Row>();
  return toTodo(row!);
}

export function isInt(value: unknown): value is number {
  return Number.isSafeInteger(value);
}

export function isTodo(value: unknown): value is Todo {
  if (typeof value !== "object" || value === null) return false;
  const todo = value as Record<string, unknown>;
  return (
    isInt(todo.id) && typeof todo.title === "string" && typeof todo.done === "boolean"
  );
}

export function isTodoList(value: unknown): value is Todo[] {
  return Array.isArray(value) && value.every(isTodo);
}
