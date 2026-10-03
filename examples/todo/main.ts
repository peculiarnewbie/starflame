// Each route loads only the browser runtime it needs.
if (location.pathname === "/server" || location.pathname === "/server/") {
  await import("./build/packages/lustre/priv/static/lustre-server-component.mjs");
  const component = document.createElement("lustre-server-component");
  component.setAttribute("route", "/server/socket");
  document.querySelector("#app")!.append(component);
} else if (location.pathname === "/live" || location.pathname === "/live/") {
  const { live } = await import("./build/dev/javascript/todos/todos/client.mjs");
  live();
} else {
  const { main } = await import("./build/dev/javascript/todos/todos/client.mjs");
  main();
}
