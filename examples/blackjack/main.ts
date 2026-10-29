// Vite builds the Gleam client into build/, and this entry loads it. The
// session token identifies this browser to the table, so it is fetched before
// the client opens a connection.
const KEY = "blackjack:session";

async function session() {
  const existing = localStorage.getItem(KEY);
  if (existing) return existing;
  const response = await fetch("/session");
  const { session } = await response.json();
  localStorage.setItem(KEY, session);
  return session;
}

await session();
const { main } = await import("./build/dev/javascript/blackjack/blackjack/client.mjs");
main();
