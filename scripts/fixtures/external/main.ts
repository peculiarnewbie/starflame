import { encode } from "./build/dev/javascript/starflame_external_check/ext/app.mjs";
import { Note } from "./build/dev/javascript/starflame_external_check/ext/shared.mjs";

document.body.textContent = JSON.stringify(encode(new Note(1, "external")));
