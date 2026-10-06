# starflame_openauth

Sign-in for Starflame apps, with an [OpenAuth](https://openauth.js.org)
issuer running in the app's own Worker. You configure it in Gleam; it keeps
the tokens in cookies and checks them on every request. Google and email codes
are supported.

```gleam
import starflame_openauth as openauth

pub fn auth() -> openauth.Auth(Me) {
  openauth.new(
    client_id: "notes",
    title: "Notes",
    storage: "AUTH",
    success: sign_in,
    to_plain: session.to_plain,
    decoder: session.decoder(),
  )
  |> openauth.google(client_id: "GOOGLE_CLIENT_ID")
  |> openauth.email_code(
    send: openauth.email_service(binding: "EMAIL", from: "login@example.com", name: "Notes"),
    database: "DB",
  )
}
```

- `storage` is a KV binding, where OpenAuth keeps its signing keys and refresh
  tokens.
- `success` turns an `Identity` into the app's user, such as by finding or
  creating it in D1. If it returns an error, that error is shown on the
  sign-in page.
- `to_plain` and `decoder` carry the user in the access token. Keep it small:
  an ID, and whatever every request needs.
- `google` names the Worker variable that holds the OAuth client ID. Google
  returns a signed ID token, so no client secret is needed.
- `email_code` sends a six-digit code with `send`. `email_service` sends it
  through Cloudflare Email Service; in local dev the `send_email` binding
  prints the message instead.

The Worker routes to it, and serves the API only to signed-in users:

```ts
const config = auth();
if (openauth.handles(config, request)) {
  return openauth.route(config, request, env, ctx);
}
if (url.pathname === "/rpc") {
  return openauth.authenticated(config, request, env, ctx, (user) =>
    newHttpBatchRpcResponse(request, newApi(env, ctx, user)));
}
```

API methods read the user with `server.auth(context)` and decode it with the
same decoder. Pages link to `/auth/login`, which can take `?provider=google` or
`?provider=code`, plus `&return=/path`. A form that posts to `/auth/logout`
signs out.

[`examples/notes`](../../examples/notes) is a complete app.

## Setup

- `@openauthjs/openauth` and `hono` are npm dependencies of the app.
- The Worker needs the `nodejs_compat` compatibility flag, because OpenAuth
  reads `process.env`.
- The issuer owns `/authorize`, `/token`, `/.well-known/*`, `/google/*` and
  `/code/*`, and this package owns `/auth/*`. With static assets, list all of
  them in `runWorkerFirst`. OpenAuth's redirects are absolute paths, so the
  issuer can't live under a prefix.
- Serve the app on one origin. Tokens are issued for the origin that signed
  in, so turn off `workers.dev` once you have a custom domain.

## Security

- **Cookies:** they're `HttpOnly` and `SameSite=Lax`. On HTTPS they're also
  `__Host-` prefixed and `Secure`.
- **Login flow:** it uses PKCE and checks its state.
- **Token lifetimes:** access tokens last 15 minutes and refresh tokens 30
  days, and refresh tokens rotate. Change these with `token_lifetimes`.
  Signing out revokes that device's refresh token, but an access token stays
  valid until it expires, because it's checked without a lookup.
- **Wrong email codes are counted in D1.** OpenAuth keeps the code in an
  encrypted cookie, which an attacker could replay to keep guessing. So after
  5 wrong codes, the address is locked for 15 minutes. The count lives in a
  `starflame_auth_attempts` table, created on first use. KV wouldn't work for
  this: it's eventually consistent, so guesses sent in parallel could all
  read the same old count.
- **Two OpenAuth behaviours are guarded against:**
  - It trusts `X-Forwarded-Host`, so those headers are stripped.
  - It redirects a refused `redirect_uri` to itself, with an error attached.
    So requests for other clients or redirect URIs are refused before
    OpenAuth sees them.

`pnpm test` runs a full sign-in in Miniflare: refreshing, signing out, the
lockout, parallel guessing, and the redirect checks. Google sign-in isn't
tested end to end, because that needs Google.
