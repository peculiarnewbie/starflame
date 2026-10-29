// Vite builds the Gleam client into build/, and this entry loads it. The
// session token identifies this browser to the API.
const KEY = "photos:session";

async function session() {
  const existing = localStorage.getItem(KEY);
  if (existing) return existing;
  const response = await fetch("/session");
  const { session } = await response.json();
  localStorage.setItem(KEY, session);
  return session;
}

await session();
const { main } = await import("./build/dev/javascript/photos/photos/client.mjs");
main();
