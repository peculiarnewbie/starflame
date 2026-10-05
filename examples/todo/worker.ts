// The Worker entrypoint: RPC goes to the room's Durable Object.

export { TodoRoom } from "./room.ts";

export default {
  async fetch(request: Request, env: Env) {
    const url = new URL(request.url);

    if (["/rpc", "/live/rpc", "/server/socket"].includes(url.pathname)) {
      // Cap'n Web doesn't check Origin, and browsers allow cross-site
      // WebSockets, so reject other sites here.
      const origin = request.headers.get("Origin");
      if (origin !== null && origin !== url.origin) {
        return new Response("Forbidden origin", { status: 403 });
      }
      return env.ROOM.getByName("public-demo").fetch(request);
    }

    return new Response("Not found", { status: 404 });
  },
};
