// The Worker entrypoint: sessions, and one Durable Object per table.

export { BlackjackTable } from "./room.ts";

export default {
  async fetch(request: Request, env: Env) {
    const url = new URL(request.url);

    // The browser calls this once, then keeps the token. The token is the
    // credential: the table derives a player id from it and never reads one
    // from the arguments.
    if (url.pathname === "/session") {
      return Response.json(
        { session: crypto.randomUUID() },
        { headers: { "cache-control": "no-store" } },
      );
    }

    if (url.pathname === "/rpc") {
      // Cap'n Web doesn't check Origin, and browsers allow cross-site
      // WebSockets, so reject other sites here.
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      const session = url.searchParams.get("session") ?? "";
      if (session.length < 8 || session.length > 128) {
        return new Response("Missing session", { status: 401 });
      }
      return env.TABLE.getByName(tableName(url.searchParams.get("table"))).fetch(
        request,
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

function tableName(raw: string | null) {
  const cleaned = (raw ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}
