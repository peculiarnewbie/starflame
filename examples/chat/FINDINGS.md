# What building this found

Notes from building a room chat on a hibernating WebSocket. These are
framework gaps, not bugs in the example.

## 1. Typed RPC and hibernation are incompatible today

This is the headline. A Cap'n Web session is a stateful object: pending calls,
import/export tables, and callback stubs live in the Durable Object's memory.
Hibernation exists precisely to throw that memory away while keeping the socket
open. There is no handshake to rebuild the session on wake, so a Cap'n Web
socket cannot hibernate.

The demo resolves it by splitting the transport:

- **Actions** go over HTTP RPC (`connect_http`) to the room's DO.
- **Live updates** go over the hibernating socket as one-way envelopes.

The important part is that the push channel is still typed: envelopes are built
from `chat/shared` and encoded by the generated codecs, and the client decodes
with `room_event_decoder`. It is not a second, hand-written protocol.

**What the runtime could add:** a documented "stateless push" transport for
hibernating sockets, or a Cap'n Web mode that re-establishes a session by
replaying a subscribe call. Either would let an app keep one protocol for both
directions. Until then, every realtime app will rediscover this split.

## 2. Hibernation itself is structurally easy

Once the session state is out of the picture, the DO needs almost nothing:

```ts
this.ctx.acceptWebSocket(server, [player]);
server.serializeAttachment({ player, name });
// later
this.ctx.getWebSockets(); // all live sockets, across evictions
```

No maps to rebuild, no `setTimeout` heartbeats, no per-connection objects. The
attachment carries the identity. That is a genuine improvement over the todo
example, which keeps listeners and Lustre runtimes in memory and therefore
cannot hibernate.

**Gotcha:** `getWebSockets()` includes sockets that are closing, so a presence
count read inside `webSocketClose` is one too high. Filter on
`socket.readyState === WebSocket.OPEN`.

## 3. Eviction can't be tested locally

Miniflare's `setOptions` restarts workerd, which *drops* sockets; it does not
evict a DO while keeping them open. So the suite proves the important half —
that no in-memory state is required to resume — but it does not prove that
hibernation reclaims the object. That claim here rests on the code shape, not a
measurement.

**Suggestion:** a Miniflare hook to force a DO eviction (or `cf dev` exposing
one) would make this testable, and would let the todo example's cost claim
become a number too.

## 4. No Durable Object storage bindings — fixed

`starflame/do_sql` now wraps `ctx.storage.sql`, reading the object state through
`execution(context)`: `database`, `setup`, `run` (rows written), and `all` with
decoders, plus typed values. Calls are synchronous because the database lives in
the object, so the chat API dropped its Promises.

This unlocks the "one DO per entity" pattern: history stays in the room, with no
D1 round trip per message.

**Still missing:** transactions (you can `exec("BEGIN")` by hand, but there is no
helper), a `first`/`Option` shorthand, migration versioning, and an `Error` shape
as rich as D1's. The module also assumes the object was created with
`storage: "sqlite"`; otherwise it throws.

## 5. Two endpoints, one session helper

`/rpc` and `/socket` both need the session. The helper made that a two-line
check in each; without it, this would have been the fourth copy of the token
logic. Worth having done first.

## Verdict

The split transport works and is honest: calls are typed RPC, pushes are typed
envelopes. The cost is that the push protocol is one-way and the client must
reconnect itself (backoff in `client_ffi.mjs`).

If realtime is a core use case, the priority is clear: **a stateless push
transport with codecs**, so apps don't hand-roll a second protocol, and a way to
test eviction so hibernation stops being an article of faith.

## 6. Live-state recovery is the client's job — and it was wrong here

An earlier version started history and the socket together, then replaced the
message list with the history response. A live message that arrived while
history was in flight was erased, and a reconnect missed everything sent while
the socket was down.

The client now merges snapshots and events by id (`chat/messages.merge`) and
refreshes history when a reconnect opens. Those three rules — merge, order,
refresh on reconnect — are the same in every realtime app. The framework offers
no snapshot revision, no "subscribed" boundary, and no reconnect hook, so each
app rediscovers them.

**Suggestion:** a documented recovery recipe (or a small helper) that pairs
history with a subscription and defines what happens between them. A registry
of listeners alone would not have caught this: the bug is ordering, not
cleanup.
