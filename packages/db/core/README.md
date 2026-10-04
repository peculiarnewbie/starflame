# starflame_db

Gleam schemas for Cloudflare D1. A schema is a plain Gleam value built with
`starflame_db/schema`; `starflame_db_kit` turns changes to it into SQL
migrations.

```gleam
import starflame_db/schema as s

pub fn schema() -> s.Schema {
  s.schema([
    s.table("users", row: "User")
    |> s.int("id", [s.primary_key()])
    |> s.text("email", [s.unique()])
    |> s.bool("admin", [s.default(False)])
    |> s.timestamp("created_at", [s.default_now()]),
  ])
}
```

Columns are NOT NULL unless marked `nullable()`, and every table is STRICT.
Bool is stored as INTEGER constrained to 0 or 1, and timestamps as INTEGER
Unix seconds (`gleam_time`'s `Timestamp` in Gleam).

Not supported yet: composite keys, AUTOINCREMENT, table renames, views,
triggers, generated columns, and partial or expression indexes. Generated row
types, decoders and typed queries are planned.
