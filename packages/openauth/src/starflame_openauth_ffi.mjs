// The OpenAuth issuer and client, configured from starflame_openauth.gleam,
// plus the routes that keep the tokens in cookies.
//
// The issuer assumes it owns the root of its origin: its redirects and
// links are absolute paths. So it gets its own paths (`/authorize`,
// `/token`, `/.well-known/...`, `/google/...`, `/code/...`) rather than a
// prefix, and the app's routes live under `/auth/`.

import { issuer as createIssuer } from "@openauthjs/openauth/issuer";
import { createClient } from "@openauthjs/openauth/client";
import { GoogleOidcProvider } from "@openauthjs/openauth/provider/google";
import { CodeProvider } from "@openauthjs/openauth/provider/code";
import { CodeUI } from "@openauthjs/openauth/ui/code";
import { Select } from "@openauthjs/openauth/ui/select";
import { CloudflareStorage } from "@openauthjs/openauth/storage/cloudflare";
import { Result$Ok, Result$Error } from "./gleam.mjs";
import { Option$Some, Option$None } from "../gleam_stdlib/gleam/option.mjs";
import {
  Identity$Google,
  Identity$Email,
  Provider$isGoogleProvider,
} from "./starflame_openauth.mjs";

const LOGIN = "/auth/login";
const CALLBACK = "/auth/callback";
const LOGOUT = "/auth/logout";
const ISSUER = ["/authorize", "/token"];

const ACCESS = "sf_access";
const REFRESH = "sf_refresh";
const PENDING = "sf_login";

// Wrong codes allowed per address before it's locked for LOCK_SECONDS.
const MAX_FAILURES = 5;
const LOCK_SECONDS = 15 * 60;

// The issuer's name for each provider, which is also its path prefix.
const providerName = (provider) =>
  Provider$isGoogleProvider(provider) ? "google" : "code";

export function handles(auth, request) {
  const path = new URL(request.url).pathname;
  if (path === LOGIN || path === CALLBACK || path === LOGOUT) return true;
  if (ISSUER.includes(path) || path.startsWith("/.well-known/")) return true;
  return auth.providers
    .toArray()
    .some((provider) => path.startsWith(`/${providerName(provider)}/`));
}

export async function route(auth, request, env, ctx) {
  try {
    const path = new URL(request.url).pathname;
    if (path === LOGIN) return await login(auth, request, env, ctx);
    if (path === CALLBACK) return await callback(auth, request, env, ctx);
    if (path === LOGOUT) return await logout(auth, request, env);
    // OpenAuth redirects to a refused redirect_uri with the error, which
    // would make it an open redirect, so refuse other clients first.
    if (path === "/authorize" && !ownClient(auth, request)) {
      return page(400, "This sign-in link isn't for this site.");
    }
    return await issuer(auth, env).fetch(trusted(request), env, ctx);
  } catch (error) {
    console.error(error);
    return page(500, "Something went wrong signing in. Try again.");
  }
}

export async function authenticated(auth, request, env, ctx, validate, serve) {
  const session = await verify(auth, request, env, ctx, validate);
  if (session.user === undefined) {
    return respond(session, new Response("Unauthorized", { status: 401 }));
  }
  return respond(session, await serve(session.user));
}

export async function user(auth, request, env, ctx, validate) {
  const session = await verify(auth, request, env, ctx, validate);
  const user =
    session.user === undefined ? Result$Error(undefined) : Result$Ok(session.user);
  return [user, session];
}

export function respond(session, response) {
  if (session.cookies.length === 0) return response;
  // Responses from fetch() have immutable headers.
  const copy = new Response(response.body, response);
  for (const cookie of session.cookies) copy.headers.append("Set-Cookie", cookie);
  return copy;
}

// Routes ----------------------------------------------------------------------

async function login(auth, request, env, ctx) {
  const url = new URL(request.url);
  const provider = url.searchParams.get("provider") ?? undefined;
  const { challenge, url: target } = await client(auth, request, env, ctx).authorize(
    new URL(CALLBACK, url).href,
    "code",
    { pkce: true, provider },
  );
  const pending = {
    state: challenge.state,
    verifier: challenge.verifier,
    return: localPath(url.searchParams.get("return")),
  };
  return redirect(target, [
    cookie(request, PENDING, JSON.stringify(pending), 10 * 60),
  ]);
}

async function callback(auth, request, env, ctx) {
  const url = new URL(request.url);
  const clear = cookie(request, PENDING, "", 0);
  let pending;
  try {
    pending = JSON.parse(readCookie(request, PENDING) ?? "null");
  } catch {
    pending = null;
  }
  // OpenAuth reports errors here without the state.
  const error = url.searchParams.get("error");
  if (error !== null) {
    const description = url.searchParams.get("error_description") || error;
    return page(400, `Couldn't sign in: ${description}`, [clear]);
  }
  const state = url.searchParams.get("state");
  if (!pending || !state || state !== pending.state) {
    return page(400, "This sign-in has expired. Try again.", [clear]);
  }
  const code = url.searchParams.get("code");
  if (!code) return page(400, "This sign-in has expired. Try again.", [clear]);
  const exchanged = await client(auth, request, env, ctx).exchange(
    code,
    new URL(CALLBACK, url).href,
    pending.verifier,
  );
  if (exchanged.err) {
    return page(400, "This sign-in has expired. Try again.", [clear]);
  }
  return redirect(pending.return, [
    clear,
    ...tokenCookies(auth, request, exchanged.tokens),
  ]);
}

async function logout(auth, request, env) {
  if (request.method !== "POST") {
    return new Response("Sign out with a POST", {
      status: 405,
      headers: { Allow: "POST" },
    });
  }
  if (!sameOrigin(request)) return new Response("Forbidden", { status: 403 });
  const refresh = readCookie(request, REFRESH);
  if (refresh) {
    // A refresh token is `<subject>:<id>`, stored under that subject.
    const parts = refresh.split(":");
    const id = parts.pop();
    const storage = CloudflareStorage({ namespace: env[auth.storage] });
    await storage.remove(["oauth:refresh", parts.join(":"), id]);
  }
  return redirect("/", clearTokens(request), 303);
}

// Verifying -------------------------------------------------------------------

async function verify(auth, request, env, ctx, validate) {
  const access = readCookie(request, ACCESS);
  const refresh = readCookie(request, REFRESH);
  const signedOut = { user: undefined, cookies: [] };
  if (!refresh) return access ? { ...signedOut, cookies: clearTokens(request) } : signedOut;

  const openauth = client(auth, request, env, ctx);
  const subjects = { user: schema(validate) };
  let verified;
  if (access) {
    verified = await openauth.verify(subjects, access, { refresh });
  } else {
    const refreshed = await openauth.refresh(refresh);
    verified = refreshed.err
      ? refreshed
      : {
          ...(await openauth.verify(subjects, refreshed.tokens.access)),
          tokens: refreshed.tokens,
        };
  }
  if (verified.err) return { ...signedOut, cookies: clearTokens(request) };
  return {
    user: verified.subject.properties,
    cookies: verified.tokens ? tokenCookies(auth, request, verified.tokens) : [],
  };
}

// A Standard Schema that checks a token's user with the app's decoder.
function schema(validate) {
  return {
    "~standard": {
      version: 1,
      vendor: "starflame",
      validate: (value) =>
        validate(value)
          ? { value }
          : { issues: [{ message: "The token's user doesn't decode" }] },
    },
  };
}

// The issuer ------------------------------------------------------------------

// One issuer per isolate: it keeps its signing keys in memory once loaded.
const issuers = new Map();

function issuer(auth, env) {
  const cached = issuers.get(auth.client_id);
  if (cached && cached.env === env) return cached.issuer;

  const providers = {};
  for (const provider of auth.providers.toArray()) {
    providers[providerName(provider)] = Provider$isGoogleProvider(provider)
      ? GoogleOidcProvider({
          clientID: env[provider.client_id],
          scopes: ["email", "profile"],
        })
      : emailCode(provider, env);
  }

  const created = createIssuer({
    // Only the client checks subjects, in `verify`.
    subjects: {},
    storage: CloudflareStorage({ namespace: env[auth.storage] }),
    providers,
    theme: {
      title: auth.title,
      radius: "md",
      primary: { light: "black", dark: "white" },
    },
    select: Select({
      providers: { google: { display: "Google" }, code: { display: "Email" } },
    }),
    ttl: { access: auth.access_ttl, refresh: auth.refresh_ttl },
    allow: async (_input, req) => ownClient(auth, req),
    async success(response, value) {
      const identity = await identify(value, auth, env);
      if (typeof identity === "string") return page(403, identity);
      const result = await auth.success(env, identity);
      if (!result.isOk()) return page(403, result[0]);
      return response.subject("user", auth.to_plain(result[0]));
    },
  });
  issuers.set(auth.client_id, { env, issuer: created });
  return created;
}

// The Identity for a finished sign-in, or why it's refused.
async function identify(value, auth, env) {
  if (value.provider === "google") {
    const claims = value.id;
    if (typeof claims.email !== "string") {
      return "Google didn't share an email address.";
    }
    const name = typeof claims.name === "string" ? Option$Some(claims.name) : Option$None();
    return Identity$Google(claims.sub, claims.email, claims.email_verified === true, name);
  }
  const email = normalise(value.claims.email);
  const provider = auth.providers.toArray().find((p) => !Provider$isGoogleProvider(p));
  const database = env[provider.database];
  // Checked here, not on each guess: an attacker replaying the encrypted
  // state cookie can submit guesses in parallel, but every wrong one is
  // counted before a right one can finish signing in.
  if (await failures(database, email) >= MAX_FAILURES) {
    return "Too many wrong codes. Try again in 15 minutes.";
  }
  await database.prepare("DELETE FROM starflame_auth_attempts WHERE email = ?").bind(email).run();
  return Identity$Email(email);
}

function emailCode(provider, env) {
  const ui = CodeUI({
    copy: { code_info: "We'll email you a code to sign in." },
    async sendCode(claims, code) {
      const email = normalise(claims.email);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return { type: "invalid_claim", key: "email", value: claims.email ?? "" };
      }
      const sent = await provider.send(env, email, code);
      if (!sent.isOk()) {
        console.error(`Couldn't send a sign-in code: ${sent[0]}`);
        return { type: "invalid_claim", key: "email", value: claims.email };
      }
    },
  });
  return CodeProvider({
    ...ui,
    async request(req, state, form, error) {
      if (error?.type === "invalid_code" && state.type === "code") {
        await recordFailure(env[provider.database], normalise(state.claims.email));
      }
      return ui.request(req, state, form, error);
    },
  });
}

export async function sendEmail(env, binding, from, name, to, code) {
  const sender = env[binding];
  if (!sender) return Result$Error(`There's no send_email binding named ${binding}`);
  try {
    await sender.send({
      to,
      from: { email: from, name },
      subject: `${code} is your ${name} sign-in code`,
      text:
        `Your ${name} sign-in code is ${code}.\n\n` +
        "If you didn't try to sign in, you can ignore this email.",
      html:
        `<p>Your ${escape(name)} sign-in code is <strong>${code}</strong>.</p>` +
        "<p>If you didn't try to sign in, you can ignore this email.</p>",
    });
    return Result$Ok(undefined);
  } catch (error) {
    return Result$Error(String(error?.message ?? error));
  }
}

const normalise = (email) => String(email ?? "").trim().toLowerCase();

// Wrong-code counts. D1, unlike KV, is consistent, so parallel guesses can't
// all read a stale count.

let attemptsTable = null;

function attempts(database) {
  attemptsTable ??= database
    .prepare(
      "CREATE TABLE IF NOT EXISTS starflame_auth_attempts " +
        "(email TEXT PRIMARY KEY, failures INTEGER NOT NULL, expires INTEGER NOT NULL)",
    )
    .run()
    .catch((error) => {
      attemptsTable = null;
      throw error;
    });
  return attemptsTable;
}

async function recordFailure(database, email) {
  await attempts(database);
  const now = Math.floor(Date.now() / 1000);
  await database
    .prepare(
      "INSERT INTO starflame_auth_attempts (email, failures, expires) VALUES (?1, 1, ?2) " +
        "ON CONFLICT (email) DO UPDATE SET " +
        "failures = CASE WHEN expires <= ?3 THEN 1 ELSE failures + 1 END, expires = ?2",
    )
    .bind(email, now + LOCK_SECONDS, now)
    .run();
}

async function failures(database, email) {
  await attempts(database);
  const row = await database
    .prepare("SELECT failures FROM starflame_auth_attempts WHERE email = ? AND expires > ?")
    .bind(email, Math.floor(Date.now() / 1000))
    .first();
  return row?.failures ?? 0;
}

// Whether an /authorize request is this app, coming back to its own callback.
function ownClient(auth, request) {
  const url = new URL(request.url);
  return (
    url.searchParams.get("client_id") === auth.client_id &&
    url.searchParams.get("redirect_uri") === new URL(CALLBACK, url).href
  );
}

// An OpenAuth client that reaches the issuer in this Worker directly.
function client(auth, request, env, ctx) {
  return createClient({
    clientID: auth.client_id,
    issuer: new URL(request.url).origin,
    fetch: (input, init) => issuer(auth, env).fetch(new Request(input, init), env, ctx),
  });
}

// OpenAuth builds its own URLs from X-Forwarded-* headers, which anyone can
// send to a Worker.
function trusted(request) {
  const headers = new Headers(request.headers);
  for (const name of ["x-forwarded-host", "x-forwarded-proto", "x-forwarded-port"]) {
    headers.delete(name);
  }
  return new Request(request, { headers });
}

// Cookies ---------------------------------------------------------------------

// `__Host-` cookies must be Secure, so plain-HTTP local dev drops the prefix.
const secure = (request) => new URL(request.url).protocol === "https:";
const cookieName = (request, name) => (secure(request) ? `__Host-${name}` : name);

function cookie(request, name, value, maxAge) {
  return (
    `${cookieName(request, name)}=${encodeURIComponent(value)}; Path=/; HttpOnly; ` +
    `SameSite=Lax; Max-Age=${maxAge}${secure(request) ? "; Secure" : ""}`
  );
}

function readCookie(request, name) {
  const wanted = cookieName(request, name);
  for (const part of (request.headers.get("Cookie") ?? "").split(";")) {
    const index = part.indexOf("=");
    if (index !== -1 && part.slice(0, index).trim() === wanted) {
      try {
        return decodeURIComponent(part.slice(index + 1).trim());
      } catch {
        return undefined;
      }
    }
  }
  return undefined;
}

// Both cookies last as long as the refresh token, so an expired access
// token can still be refreshed.
function tokenCookies(auth, request, tokens) {
  return [
    cookie(request, ACCESS, tokens.access, auth.refresh_ttl),
    cookie(request, REFRESH, tokens.refresh, auth.refresh_ttl),
  ];
}

function clearTokens(request) {
  return [cookie(request, ACCESS, "", 0), cookie(request, REFRESH, "", 0)];
}

// Responses -------------------------------------------------------------------

function sameOrigin(request) {
  const origin = request.headers.get("Origin");
  return origin !== null && origin === new URL(request.url).origin;
}

// Only paths on this site, so `return` can't send someone elsewhere.
function localPath(path) {
  return path && path.startsWith("/") && !path.startsWith("//") && !path.includes("\\")
    ? path
    : "/";
}

function redirect(location, cookies = [], status = 302) {
  const headers = new Headers({ Location: location });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  return new Response(null, { status, headers });
}

function page(status, message, cookies = []) {
  const headers = new Headers({ "Content-Type": "text/html; charset=utf-8" });
  for (const cookie of cookies) headers.append("Set-Cookie", cookie);
  const body =
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
    `<title>Sign in</title><p>${escape(message)}</p><p><a href="${LOGIN}">Sign in</a></p>`;
  return new Response(body, { status, headers });
}

const escape = (text) =>
  String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
