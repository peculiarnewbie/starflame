# Notes example

Private notes per user. It's the template for an app with users:

- sign-in with Google or an email code, through
  [`starflame_openauth`](../../packages/openauth);
- a typed RPC API over HTTP;
- a D1 schema in Gleam, with generated migrations.

| File | Contents |
| --- | --- |
| `src/notes/schema.gleam` | The D1 schema; `pnpm db generate <name>` writes a migration |
| `src/notes/api.gleam` | The RPC API; each method reads the user with `server.auth` |
| `src/notes/auth.gleam` | Sign-in, finding or creating the user in D1 |
| `src/notes/client.gleam` | The Lustre app, calling the API with `connect_http` |
| `worker.ts` | Routes sign-in, serves `/rpc` to signed-in users, and serves the static app |

A Google sign-in links to an existing account that has the same verified
email address.

## Running it

```sh
pnpm dev
```

Then, in another terminal, apply the migrations to the local database:

```sh
pnpm migrate:local
```

Sign in with email: the local `send_email` binding prints the message, code
included, in the dev server's output. Google sign-in needs `GOOGLE_CLIENT_ID`
in `cloudflare.config.ts`, set to a Google OAuth client for the Web, with
`<origin>/google/callback` as an authorised redirect URI.

`pnpm test` checks the generated code and migrations, then signs two users in
under Miniflare and exercises the API as each of them. `pnpm typecheck`
checks the Worker.

## Deploying

The config binds a D1 database, a KV namespace for OpenAuth, and Email
Service. Before deploying:

- **Email:** onboard the sending domain with Email Service, and set
  `EMAIL_FROM` to an address on it.
- **Custom domain:** set one up. `workers.dev` is off, because tokens only
  work on the origin that issued them.
- **Migrations:** apply them to the remote database with
  `cf d1 migrations apply <database-id>`.
