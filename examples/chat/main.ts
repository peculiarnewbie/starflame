import { browserSession } from "@starflame/runtime/session.ts";

await browserSession("chat:session");
const { main } = await import("./build/dev/javascript/chat/chat/client.mjs");
main();
