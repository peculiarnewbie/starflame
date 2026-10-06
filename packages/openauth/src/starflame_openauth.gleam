//// Sign-in with an OpenAuth issuer that runs in the app's own Worker.
////
//// The issuer handles the sign-in pages and tokens; this module configures
//// it in Gleam, keeps the tokens in cookies, and checks them on each request.
//// The Worker routes to it:
////
//// ```ts
//// if (openauth.handles(auth(), request)) {
////   return openauth.route(auth(), request, env, ctx);
//// }
//// if (url.pathname === "/rpc") {
////   return openauth.authenticated(auth(), request, env, ctx, (user) =>
////     newHttpBatchRpcResponse(request, newApi(env, ctx, user)));
//// }
//// ```
////
//// Links to `/auth/login` sign in, optionally with `?provider=google` or
//// `?provider=code` and `&return=/path`. A form posting to `/auth/logout`
//// signs out.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import starflame/plain.{type Plain}

/// A Fetch API `Request`.
pub type Request

/// A Fetch API `Response`.
pub type Response

/// How someone proved who they are.
pub type Identity {
  /// Google's verified OpenID Connect claims. `subject` is Google's stable ID
  /// for the account; the email address can change.
  Google(
    subject: String,
    email: String,
    email_verified: Bool,
    name: Option(String),
  )
  /// An email address that received a code and entered it.
  Email(address: String)
}

pub type Provider {
  /// Google sign-in. `client_id` names the Worker variable holding the OAuth
  /// client ID; Google sends a signed ID token, so no secret is needed.
  GoogleProvider(client_id: String)
  /// A six-digit code sent by email. `send` delivers it; an error is shown
  /// on the form. `database` names the D1 binding where wrong codes are
  /// counted, in a `starflame_auth_attempts` table it creates.
  EmailCodeProvider(
    send: fn(Dynamic, String, String) -> Promise(Result(Nil, String)),
    database: String,
  )
}

/// Configures sign-in for an app whose user is `user`.
pub opaque type Auth(user) {
  Auth(
    client_id: String,
    title: String,
    storage: String,
    providers: List(Provider),
    success: fn(Dynamic, Identity) -> Promise(Result(user, String)),
    to_plain: fn(user) -> Plain,
    decoder: Decoder(user),
    access_ttl: Int,
    refresh_ttl: Int,
  )
}

/// Sign-in for the app named `client_id`, with no providers yet.
///
/// - `title` is shown on the sign-in pages.
/// - `storage` names the KV binding where OpenAuth keeps its signing keys
///   and refresh tokens.
/// - `success` turns an identity into the app's user, such as by finding or
///   creating it in D1. It gets the Worker's `env`. An error is shown on the
///   sign-in page instead.
/// - `to_plain` and `decoder` carry the user in the access token, so keep it
///   small: an ID and what's shown on every page.
pub fn new(
  client_id client_id: String,
  title title: String,
  storage storage: String,
  success success: fn(Dynamic, Identity) -> Promise(Result(user, String)),
  to_plain to_plain: fn(user) -> Plain,
  decoder decoder: Decoder(user),
) -> Auth(user) {
  Auth(
    client_id:,
    title:,
    storage:,
    providers: [],
    success:,
    to_plain:,
    decoder:,
    access_ttl: 15 * 60,
    refresh_ttl: 30 * 24 * 60 * 60,
  )
}

/// Adds Google sign-in, with the OAuth client ID in the Worker variable
/// `client_id`.
pub fn google(auth: Auth(user), client_id client_id: String) -> Auth(user) {
  Auth(
    ..auth,
    providers: list.append(auth.providers, [GoogleProvider(client_id)]),
  )
}

/// Adds sign-in with a code sent by email.
pub fn email_code(
  auth: Auth(user),
  send send: fn(Dynamic, String, String) -> Promise(Result(Nil, String)),
  database database: String,
) -> Auth(user) {
  Auth(
    ..auth,
    providers: list.append(auth.providers, [EmailCodeProvider(send, database)]),
  )
}

/// Sends codes with Cloudflare Email Service, through the `send_email`
/// binding named `binding`. `from` must be on a domain onboarded to Email
/// Sending; `name` is shown as the sender and in the subject.
pub fn email_service(
  binding binding: String,
  from from: String,
  name name: String,
) -> fn(Dynamic, String, String) -> Promise(Result(Nil, String)) {
  fn(env, to, code) { send_email(env, binding, from, name, to, code) }
}

@external(javascript, "./starflame_openauth_ffi.mjs", "sendEmail")
fn send_email(
  env: Dynamic,
  binding: String,
  from: String,
  name: String,
  to: String,
  code: String,
) -> Promise(Result(Nil, String))

/// How long tokens last, in seconds. The access token is checked without a
/// lookup, so signing out can't revoke it: keep it short. Signing in again
/// is needed once the refresh token expires unused. Defaults: 15 minutes and
/// 30 days.
pub fn token_lifetimes(
  auth: Auth(user),
  access access: Int,
  refresh refresh: Int,
) -> Auth(user) {
  Auth(..auth, access_ttl: access, refresh_ttl: refresh)
}

/// Whether `route` serves this request: `/auth/login`, `/auth/callback`,
/// `/auth/logout`, and the issuer's own paths.
@external(javascript, "./starflame_openauth_ffi.mjs", "handles")
pub fn handles(auth: Auth(user), request: Request) -> Bool

/// Serves a request that `handles` accepted.
@external(javascript, "./starflame_openauth_ffi.mjs", "route")
pub fn route(
  auth: Auth(user),
  request: Request,
  env: Dynamic,
  ctx: Dynamic,
) -> Promise(Response)

/// Calls `serve` with the signed-in user, as the plain value that
/// `starflame/server.auth` returns, and adds any refreshed tokens to its
/// response. Responds 401 when nobody is signed in.
pub fn authenticated(
  auth: Auth(user),
  request: Request,
  env: Dynamic,
  ctx: Dynamic,
  serve: fn(Dynamic) -> Promise(Response),
) -> Promise(Response) {
  do_authenticated(auth, request, env, ctx, validate(auth.decoder), serve)
}

/// The signed-in user, or `Error(Nil)`, with the cookies to set if the
/// tokens were refreshed. For pages rendered by the Worker.
pub fn user(
  auth: Auth(user),
  request: Request,
  env: Dynamic,
  ctx: Dynamic,
) -> Promise(#(Result(user, Nil), Session)) {
  use #(plain, session) <- promise.map(do_user(
    auth,
    request,
    env,
    ctx,
    validate(auth.decoder),
  ))
  let user =
    plain
    |> result.try(fn(plain) {
      decode.run(plain, auth.decoder) |> result.replace_error(Nil)
    })
  #(user, session)
}

/// Refreshed tokens to save, from `user`.
pub type Session

/// Adds the cookies for refreshed tokens to `response`, if there are any.
@external(javascript, "./starflame_openauth_ffi.mjs", "respond")
pub fn respond(session: Session, response: Response) -> Response

/// Checks a user from a token with the app's decoder, keeping its plain form.
fn validate(decoder: Decoder(user)) -> fn(Dynamic) -> Bool {
  fn(value) { result.is_ok(decode.run(value, decoder)) }
}

@external(javascript, "./starflame_openauth_ffi.mjs", "authenticated")
fn do_authenticated(
  auth: Auth(user),
  request: Request,
  env: Dynamic,
  ctx: Dynamic,
  validate: fn(Dynamic) -> Bool,
  serve: fn(Dynamic) -> Promise(Response),
) -> Promise(Response)

@external(javascript, "./starflame_openauth_ffi.mjs", "user")
fn do_user(
  auth: Auth(user),
  request: Request,
  env: Dynamic,
  ctx: Dynamic,
  validate: fn(Dynamic) -> Bool,
) -> Promise(#(Result(Dynamic, Nil), Session))
