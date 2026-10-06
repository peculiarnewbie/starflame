// Signs in through test/worker.js in Miniflare with an email code, the way a
// browser would, then checks refreshing, signing out and the safeguards.
// Usage: pnpm test   (runs `gleam build` first)

import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const root = resolve(fileURLToPath(import.meta.url), "../..");
const outfile = `${root}/build/test-worker.mjs`;

await build({
  entryPoints: [`${root}/test/worker.js`],
  outfile,
  bundle: true,
  format: "esm",
  platform: "neutral",
  conditions: ["workerd", "worker", "import"],
  mainFields: ["module", "main"],
  external: ["cloudflare:*", "node:*"],
  logLevel: "warning",
});

const mf = new Miniflare(
  convertV4MiniflareOptions({
    modules: true,
    scriptPath: outfile,
    compatibilityDate: "2026-09-30",
    compatibilityFlags: ["nodejs_compat"],
    kvNamespaces: ["AUTH", "CODES"],
    d1Databases: ["DB"],
  }),
);
const base = (await mf.ready).origin;
const codes = await mf.getKVNamespace("CODES");
const database = await mf.getD1Database("DB");

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`  ${ok ? "PASS" : "FAIL"} ${name}${detail ? `  ${detail}` : ""}`);
  if (!ok) failures++;
};

// A browser: keeps cookies, doesn't follow redirects by itself.
function browser() {
  const jar = new Map();
  const send = async (path, init = {}) => {
    const headers = new Headers(init.headers);
    if (jar.size > 0) {
      headers.set("Cookie", [...jar].map(([k, v]) => `${k}=${v}`).join("; "));
    }
    const response = await mf.dispatchFetch(new URL(path, base), {
      ...init,
      headers,
      redirect: "manual",
    });
    for (const cookie of response.headers.getSetCookie()) {
      const [pair, ...attributes] = cookie.split(";");
      const index = pair.indexOf("=");
      const name = pair.slice(0, index).trim();
      const expired = attributes.some((a) => a.trim().toLowerCase() === "max-age=0");
      if (expired) jar.delete(name);
      else jar.set(name, pair.slice(index + 1));
    }
    return response;
  };
  const form = (path, fields) =>
    send(path, {
      method: "POST",
      body: new URLSearchParams(fields),
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
  return { jar, send, form };
}

// Follows redirects within the Worker, returning the last response.
async function follow(client, response) {
  while (response.status >= 300 && response.status < 400) {
    const location = new URL(response.headers.get("Location"), base);
    if (location.origin !== base) return response;
    response = await client.send(location.pathname + location.search);
  }
  return response;
}

// Starts signing in with an email code, up to the form asking for the code.
async function requestCode(client, email, extra = "") {
  await follow(client, await client.send(`/auth/login?provider=code${extra}`));
  return client.form("/code/authorize", { action: "request", email });
}

async function signIn(email, extra = "") {
  const client = browser();
  await requestCode(client, email, extra);
  const code = await codes.get(email.toLowerCase());
  const done = await client.form("/code/authorize", { action: "verify", code });
  return { client, done };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

console.log("\n# Signing in");
{
  const anonymous = browser();
  check("signed out is 401", (await anonymous.send("/me")).status === 401);

  const client = browser();
  const login = await client.send("/auth/login?provider=code&return=/me");
  const target = new URL(login.headers.get("Location"));
  check(
    "login redirects to the issuer with PKCE",
    login.status === 302 &&
      target.pathname === "/authorize" &&
      target.searchParams.get("code_challenge_method") === "S256" &&
      target.searchParams.get("redirect_uri") === `${base}/auth/callback`,
    target.pathname,
  );
  const form = await follow(client, login);
  check("issuer shows the email form", form.status === 200 && (await form.text()).includes('name="email"'));

  const asked = await client.form("/code/authorize", { action: "request", email: " Ada@Example.com " });
  const code = await codes.get("ada@example.com");
  check("code sent to the normalised address", asked.status === 200 && /^\d{6}$/.test(code ?? ""), code);

  const wrong = await client.form("/code/authorize", { action: "verify", code: code === "000000" ? "111111" : "000000" });
  check("wrong code is refused", wrong.status === 200 && (await wrong.text()).includes("Invalid code"));

  const right = await client.form("/code/authorize", { action: "verify", code });
  const callback = new URL(right.headers.get("Location") ?? "", base);
  check("right code returns to the callback", callback.pathname === "/auth/callback", callback.pathname);

  const back = await client.send(callback.pathname + callback.search);
  check(
    "callback sets the tokens and returns",
    back.status === 302 && back.headers.get("Location") === "/me" && client.jar.has("sf_access") && client.jar.has("sf_refresh"),
    back.headers.get("Location"),
  );
  check("cookies are HttpOnly and SameSite=Lax", back.headers.getSetCookie().every((c) => /HttpOnly/.test(c) && /SameSite=Lax/.test(c)));

  const me = await client.send("/me");
  const user = await me.json();
  check("signed-in user reaches the app", me.status === 200 && user.id === "email:ada@example.com", JSON.stringify(user));

  const replay = await client.send(callback.pathname + callback.search);
  check("callback can't be replayed", replay.status === 400, `status ${replay.status}`);

  console.log("\n# Refreshing and signing out");
  const oldRefresh = client.jar.get("sf_refresh");
  await sleep(2500); // the access token lasts 2 seconds
  const refreshed = await client.send("/me");
  check(
    "expired access token is refreshed",
    refreshed.status === 200 && refreshed.headers.getSetCookie().some((c) => c.startsWith("sf_access=")),
    `status ${refreshed.status}`,
  );
  check("refresh token rotates", client.jar.get("sf_refresh") !== oldRefresh);

  const stolen = browser();
  stolen.jar.set("sf_access", client.jar.get("sf_access"));
  stolen.jar.set("sf_refresh", client.jar.get("sf_refresh"));

  const getLogout = await client.send("/auth/logout");
  check("logout needs POST", getLogout.status === 405);
  const crossSite = await client.send("/auth/logout", { method: "POST", headers: { Origin: "https://evil.example" } });
  check("cross-site logout refused", crossSite.status === 403);
  const logout = await client.send("/auth/logout", { method: "POST", headers: { Origin: base } });
  check("logout clears the cookies", logout.status === 303 && !client.jar.has("sf_refresh"));
  check("signed out afterwards", (await client.send("/me")).status === 401);

  await sleep(2500);
  check("revoked refresh token can't sign in again", (await stolen.send("/me")).status === 401);
}

console.log("\n# Safeguards");
{
  const client = browser();
  await requestCode(client, "eve@example.com");
  const code = await codes.get("eve@example.com");
  const wrong = code === "000000" ? "111111" : "000000";
  for (let i = 0; i < 5; i++) await client.form("/code/authorize", { action: "verify", code: wrong });
  const locked = await client.form("/code/authorize", { action: "verify", code });
  check("five wrong codes lock the address", locked.status === 403 && (await locked.text()).includes("Too many wrong codes"));

  await database.prepare("UPDATE starflame_auth_attempts SET expires = 0").run();
  const { done } = await signIn("eve@example.com");
  check("the lock expires", done.status === 302, `status ${done.status}`);

  const parallel = browser();
  await requestCode(parallel, "mallory@example.com");
  const target = await codes.get("mallory@example.com");
  const guesses = Array.from({ length: 20 }, (_, i) => String(i).padStart(6, "0")).filter((g) => g !== target);
  await Promise.all(guesses.map((g) => parallel.form("/code/authorize", { action: "verify", code: g })));
  const late = await parallel.form("/code/authorize", { action: "verify", code: target });
  check("parallel guesses are all counted", late.status === 403, `status ${late.status}`);

  const blocked = await signIn("blocked@example.com");
  check("success can refuse a user", blocked.done.status === 403 && (await blocked.done.text()).includes("isn"));

  const unreachable = browser();
  const unsent = await requestCode(unreachable, "unreachable@example.com");
  check("a failed send is shown on the form", unsent.status === 200 && (await unsent.text()).includes("not valid"));

  const offsite = await signIn("ada@example.com", "&return=//evil.example/x");
  const offsiteBack = await offsite.client.send(new URL(offsite.done.headers.get("Location")).pathname + new URL(offsite.done.headers.get("Location")).search);
  check("return can't leave the site", offsiteBack.headers.get("Location") === "/", offsiteBack.headers.get("Location"));

  const forged = browser();
  await forged.send("/auth/login?provider=code");
  const badState = await forged.send("/auth/callback?code=x&state=forged");
  check("callback checks the state", badState.status === 400);

  const tampered = browser();
  tampered.jar.set("sf_access", "not.a.token");
  tampered.jar.set("sf_refresh", "user:nope:nope");
  const rejected = await tampered.send("/me");
  check("bad tokens are refused and cleared", rejected.status === 401 && !tampered.jar.has("sf_refresh"));

  const wellKnown = await browser().send("/.well-known/oauth-authorization-server", {
    headers: { "X-Forwarded-Host": "evil.example" },
  });
  check("X-Forwarded-Host is ignored", (await wellKnown.json()).issuer === base);

  const foreign = await browser().send(
    `/authorize?client_id=test&redirect_uri=${encodeURIComponent("https://evil.example/auth/callback")}&response_type=code`,
  );
  check(
    "other redirect URIs are refused, not redirected to",
    foreign.status === 400 && foreign.headers.get("Location") === null,
    `status ${foreign.status}`,
  );

  check("unconfigured providers aren't routed", (await browser().send("/google/authorize")).status === 404);

  const https = await mf.dispatchFetch("https://notes.example/auth/login?provider=code", { redirect: "manual" });
  const pending = https.headers.getSetCookie()[0] ?? "";
  check("HTTPS cookies are __Host- and Secure", pending.startsWith("__Host-sf_login=") && /; Secure/.test(pending), pending.split(";")[0].slice(0, 20));
}

console.log("\n# Email Service sender");
{
  const { email_service } = await import(`${root}/build/dev/javascript/starflame_openauth/starflame_openauth.mjs`);
  const send = email_service("EMAIL", "login@notes.example", "Notes");
  const sent = [];
  const ok = await send({ EMAIL: { send: async (message) => sent.push(message) } }, "ada@example.com", "123456");
  const message = sent[0] ?? {};
  check(
    "sends the code from the configured address",
    ok.isOk() && message.to === "ada@example.com" && message.from.email === "login@notes.example" &&
      message.subject === "123456 is your Notes sign-in code" && message.text.includes("123456") && message.html.includes("123456"),
    message.subject,
  );
  const failed = await send({ EMAIL: { send: async () => { throw new Error("domain not onboarded"); } } }, "a@b.c", "1");
  check("reports a failed send", !failed.isOk() && failed[0] === "domain not onboarded", failed[0]);
  const missing = await send({}, "a@b.c", "1");
  check("reports a missing binding", !missing.isOk(), missing[0]);
}

await mf.dispose();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
