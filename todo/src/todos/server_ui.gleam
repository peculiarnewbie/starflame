//// The same todo UI running as a real Lustre server component.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import lustre
import lustre/server_component
import todos/client
import todos/generated/client as api
import todos/generated/wire

pub fn start(
  stub: Dynamic,
  emit: fn(String) -> Nil,
) -> lustre.Runtime(client.Msg) {
  let app =
    lustre.application(
      fn(_) { client.init_with_api(api.from_dynamic(stub), client.Server) },
      client.update,
      client.view,
    )
  let runtime = start_runtime(app)
  lustre.send(
    runtime,
    server_component.register_callback(fn(message) {
      message
      |> server_component.client_message_to_json
      |> json.to_string
      |> emit
    }),
  )
  runtime
}

pub fn receive(runtime: lustre.Runtime(client.Msg), data: String) -> Bool {
  case json.parse(data, server_component.runtime_message_decoder()) {
    Ok(message) -> {
      lustre.send(runtime, message)
      True
    }
    Error(_) -> False
  }
}

pub fn change(runtime: lustre.Runtime(client.Msg), data: Dynamic) -> Nil {
  case decode.run(data, wire.change_decoder()) {
    Ok(change) -> lustre.send(runtime, lustre.dispatch(client.Changed(change)))
    Error(_) -> Nil
  }
}

pub fn stop(runtime: lustre.Runtime(client.Msg)) -> Nil {
  lustre.send(runtime, lustre.shutdown())
}

// Lustre 5.7.1's JavaScript start function omits the name argument expected by
// its Runtime constructor. Keep the compatibility fix at this FFI boundary.
@external(javascript, "./server_ui_ffi.mjs", "startRuntime")
fn start_runtime(
  app: lustre.App(Nil, client.Model, client.Msg),
) -> lustre.Runtime(client.Msg)
