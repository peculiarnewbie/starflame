// Vite builds the Gleam client into build/, and this entry starts a session
// before loading it. The client reads the same key from localStorage.
import { browserSession } from "@starflame/runtime/session.ts";

await browserSession("blackjack:session");
const { main } = await import("./build/dev/javascript/blackjack/blackjack/client.mjs");
main();
