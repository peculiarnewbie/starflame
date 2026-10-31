// Sessions: the Worker mints a token, the browser keeps it, and the server
// derives a stable public id from it. The token is the credential; the id is a
// hash, so it can appear in views and records without leaking the token.
//
//   import { fromRequest, issue } from "@starflame/runtime/session.ts";
//
//   if (url.pathname === "/session") return issue();
//   const session = await fromRequest(request);
//   if (!session) return new Response("Missing session", { status: 401 });
//   newApi(env, ctx, session.player);

export interface Session {
  token: string;
  player: string;
}

const PARAM = "session";

/// "/app/<name>" when the app is mounted on a shared domain, else "".
export function basePath(): string {
  const parts = location.pathname.split("/").filter(Boolean);
  return parts[0] === "app" && parts[1] ? `/app/${parts[1]}` : "";
}

/// `GET /session`: a fresh token, never cached.
export function issue(): Response {
  return Response.json(
    { session: crypto.randomUUID() },
    { headers: { "cache-control": "no-store" } },
  );
}

/// The request's session, or null when the token is missing or malformed.
export async function fromRequest(request: Request): Promise<Session | null> {
  const token = new URL(request.url).searchParams.get(PARAM) ?? "";
  if (!valid(token)) return null;
  return { token, player: await playerId(token) };
}

/// The public player id for a token: 16 hex characters.
export async function playerId(token: string): Promise<string> {
  const encoded = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest).slice(0, 8))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/// Browser side: reuse the stored token, or fetch one. Call before importing
/// the Gleam client, which reads the same key.
export async function browserSession(
  storageKey = "starflame:session",
): Promise<string> {
  const existing = localStorage.getItem(storageKey);
  if (existing) return existing;
  const response = await fetch(`${basePath()}/session`);
  if (!response.ok) throw new Error(`Could not start a session (${response.status})`);
  const { session } = (await response.json()) as { session: string };
  localStorage.setItem(storageKey, session);
  return session;
}

function valid(token: string): boolean {
  return token.length >= 8 && token.length <= 128;
}
