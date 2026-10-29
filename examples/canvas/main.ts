import { browserSession } from "@starflame/runtime/session.ts";

await browserSession("canvas:session");
const { main } = await import("./build/dev/javascript/canvas/canvas/client.mjs");
main();
