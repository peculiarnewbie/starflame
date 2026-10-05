# starflame_db_kit

Generates reviewable D1 migrations from a `starflame_db` schema. Add it as a
dev dependency and pass your schema to it from a module in `dev/`, so the
schema is evaluated rather than parsed:

```gleam
// dev/db_kit.gleam
import app/schema
import starflame_db_kit

pub fn main() {
  starflame_db_kit.main(
    schema.schema(),
    starflame_db_kit.Config(
      ..starflame_db_kit.default_config(),
      module: "src/app/db.gleam",
    ),
  )
}
```

```sh
gleam run -m db_kit -- generate add_posts
gleam run -m db_kit -- generate rename_name --rename users.name=display_name
gleam run -m db_kit -- generate drop_bio --allow-destructive
gleam run -m db_kit -- generate backfill_slugs --custom
gleam run -m db_kit -- codegen
gleam run -m db_kit -- check
```

Migrations are written to `migrations/NNNN_name.sql` for
`wrangler d1 migrations apply`, with a schema snapshot for each in
`db/snapshots/`. The kit never applies migrations to D1 itself.

- **Changes SQLite can't make in place** are table rebuilds. D1 can't disable
  foreign keys, and `DROP TABLE` fires `ON DELETE` actions. So the rebuilt
  table and every table that references it are copied to backups before
  anything is dropped, then restored, with foreign key checks deferred to the
  end of the migration.
- **It doesn't guess.** Renames need `--rename`. Dropping a column or table
  needs `--allow-destructive`. A NOT NULL column without a default is refused,
  with the expand, backfill and contract steps suggested instead.
- **Every migration is checked first.** The kit applies the full history plus
  the new file to a scratch SQLite database, which enforces foreign keys as D1
  does. It writes nothing unless the result matches the snapshot.
- **`check` guards the history.** wrangler tracks applied migrations by file
  name only, so `check` catches edited migrations, gaps and duplicate numbers,
  histories that diverged on two branches, custom migrations that change the
  schema, and schema changes without a migration. A custom migration can be
  edited until the next migration is generated.
- **Generated Gleam CRUD stays tied to the migration history.** Each migration
  writes the row and insert types, decoders, insert/get/delete functions, and
  quoted column list from its snapshot, laid out by the installed
  `gleam format`. `codegen` rewrites the latest module; `check` reports missing
  or edited generated code. A Gleam upgrade that changes formatting makes
  `check` ask for `codegen` once.
- **Generated decoders take a fast path.** `gleam/dynamic/decode` allocates
  an `Ok(Some(value))` per field, which V8 is slow to construct, so a row
  that matches its column types is checked in one pass and read directly.
  Other rows get the full decoder and its errors. Decoding 50 rows takes
  about 11µs instead of 230µs.

Requires Node 22.13 or later for `node:sqlite`, and `gleam` on the `PATH`.
