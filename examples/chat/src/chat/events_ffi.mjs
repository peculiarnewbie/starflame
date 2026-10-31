export function stringify(value) {
  return JSON.stringify(value);
}

export function broadcast(execution, payload) {
  for (const socket of execution.getWebSockets()) {
    try {
      socket.send(payload);
    } catch {
      // Closing sockets are removed by the Durable Object runtime.
    }
  }
}
