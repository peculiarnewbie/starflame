import { Runtime } from "./lustre_server_runtime_ffi.mjs";
import { configure_server_component } from "../../lustre/lustre/runtime/app.mjs";

// Compatibility shim for Lustre 5.7.1: its public start() passes five arguments
// to a constructor requiring six. Use the actual Lustre runtime with the name.
export function startRuntime(app) {
  return new Runtime(
    app.name, app.init, app.update, app.view,
    configure_server_component(app.config), undefined,
  );
}
