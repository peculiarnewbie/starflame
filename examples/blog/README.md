# Blog database example

This local-only Gleam app exercises `starflame_db` migrations, generated D1
types, and CRUD functions against Miniflare's in-memory D1. It is not deployed.

Run `pnpm db generate <name>` for schema changes, `pnpm db codegen` to refresh
the generated module, `pnpm db check` to verify the migration history, and
`pnpm test` to run the D1 and compile-time checks.
