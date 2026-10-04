//// The one table every benchmark app uses. Its migration is the schema for
//// the Hono, SvelteKit and Cap'n Web apps too.

import starflame_db/schema as s

pub fn schema() -> s.Schema {
  s.schema([
    s.table("todos", row: "Todo")
    |> s.int("id", [s.primary_key()])
    |> s.text("title", [])
    |> s.bool("done", [s.default(False)]),
  ])
}
