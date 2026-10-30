# What building this found

Notes from building a capability-based canvas. These are framework gaps, not
bugs in the example.

## 1. Capabilities are generated — but not where side effects are needed

**Correction:** an earlier version of this file claimed the kit could not
express a capability. That was wrong. The kit has supported them for a while
(`CapabilityT` in `model.gleam`, `SessionTarget` in `codegen.gleam`, typed
client handles and `stub_decoder`); `examples/rpc` returns a `Session`
capability with `me` and `rename`. A capability is a record whose fields are all
functions, and it can be **returned** from an API method.

So the hand-written tree here was not forced by the client. What actually
pushed this demo into TypeScript is narrower:

1. **A capability cannot be a field of another type.** The natural shape,
   `enter() -> { board: Board }`, is rejected ("a capability ... can only be
   returned", `model.gleam:412`). Returning the board directly works; returning
   a read-only and an editor variant needs two methods (`enter`, `watch`).
2. **Generated capability methods cannot be intercepted by the Durable
   Object.** `add` has to broadcast a `StrokeAdded` event, but the generated
   target calls the Gleam function directly; the DO only wraps the *root*
   target. Without a runtime publish/subscribe registry, broadcasting has to
   happen inside the API, where it has no access to the DO's listeners. That is
   why this demo kept the capability tree in `room.ts`: to own the side effect.
3. **Generated targets have no disposal hook** for application resources
   (`codegen.gleam:1119`), so subscriptions tied to a capability still need
   manual `[Symbol.dispose]` work in either design.

**Suggestion:** the missing piece is not a capability type; it is lifecycle.
A `starflame/server` publish/subscribe registry, plus an API hook that runs when
a capability target is disposed, would let capabilities be fully generated
*and* broadcast correctly. The client side already has the typed handles.

The read-only shape remains the right pattern. It just does not need a bespoke
client to be useful.


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

Capabilities are a strong fit for per-user permissions and live state, and the
model works end to end. The remaining friction is not the capability type —
that is generated — it is the **lifecycle around it**: broadcasting from inside a
capability method, disposing the resources a capability owns, and keeping the
typed client when a capability has to be nested in a record.

If capabilities are going to be a first-class part of the story, the runtime
needs a publish/subscribe registry and a disposal hook, not another type.
