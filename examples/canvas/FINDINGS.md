# What building this found

Notes from building a capability-based canvas. These are framework gaps, not
bugs in the example.

## 1. The RPC kit cannot express a method that returns a capability

This is the headline. A capability is a live object passed by reference — an
`RpcTarget`. The generated layer only knows data types: every return value is
encoded with `plain`. So the central method of this app,

```ts
enter(readOnly: boolean) {
  return { board: readOnly ? new BoardViewApi(...) : new BoardApi(...) };
}
```

cannot be written in Gleam or generated from an API module. It is hand-written
TypeScript, and the generated client has no function for it.

The consequences:

- `board_client.gleam` is a **hand-written** client: `client.call(root, "enter",
  …, handles_decoder())` with `client.stub_decoder()` for the handle, then
  `client.call(board, "add", …)` for each method.
- The generated `api.gleam` is still useful — it owns validation and D1 — but it
  is a backend the capability wrappers call, not the RPC surface the browser
  sees.
- Every capability app will repeat this: a TS target tree, a hand-written Gleam
  client, and an API module used indirectly.

**Suggestion:** a way to declare capabilities in the API module, for example a
`Capability(...)` return type that the kit maps to `plain.unsafe_reference`, and
generated client functions that keep the stub instead of decoding it. That would
make the capability tree as typed as the data layer, and remove the second
client.

## 2. Capability-shaped authorization is genuinely nicer

Read-only mode is not a boolean checked on every call. It is a different object:

```ts
read_only ? new BoardViewApi(...) : new BoardApi(...)
```

`add` and `clear` do not exist on the viewer, so no code path can forget to
check a flag. The test calls `view.add(...)` and expects the RPC to fail. This
is the strongest argument for capabilities over route + role checks, and it
deserves to be the documented pattern for per-user permissions.

## 3. Disposal is the tricky part

Subscriptions are tied to a capability, so the capability's `[Symbol.dispose]`
has to unregister the listener and publish presence. That works, but it is
manual and easy to get wrong: a client that drops the stub without disposing
leaves a phantom subscriber. A `starflame/server` subscription registry that
owns this lifecycle would remove the boilerplate (it would also help the chat
example).

## 4. TypeScript inheritance and private fields fight `RpcTarget`

`BoardApi extends BoardViewApi` needs its own copies of the room and identity
because `#private` fields are not inherited. The result is duplication in the
target tree. Composition (a `Board` target holding a `View` target) works but
changes how disposal propagates. Minor, but it adds up in a capability tree
with more than two nodes.

## 5. D1 is doing the work of DO storage again

Strokes are per-board and colocated with the capability, which is exactly what
`ctx.storage.sql` is for. The runtime still has no bindings for it (the chat
FINDINGS made the same point), so the example uses D1 and every stroke write
leaves the object.

## Verdict

Capabilities are a strong fit for per-user permissions and live state, and this
demo proves the model works end to end. The cost is that **the typed client
stops at the capability boundary**: everything below `enter` is hand-written.

If capabilities are going to be a first-class part of the story, the kit needs a
capability type. If they are an advanced escape hatch, the docs should show this
exact pattern — hand-written tree, generated codecs for payloads — so the next
person doesn't try to force it through `plain`.
