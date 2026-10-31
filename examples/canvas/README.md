# Capability canvas

A shared whiteboard where the server hands each browser a live **capability**:
an editor gets a board they can draw on, and a viewer gets a board that has no
drawing method at all.

![Canvas](screenshot-canvas.png)

## Running it

```sh
pnpm install --frozen-lockfile
pnpm dev:canvas
```

Open `/b/sketch` in two tabs. Draw with a mouse or a finger; the other tab sees
the stroke immediately. **Watch only** re-enters with a read-only capability.

## How it is put together

```
root.enter() ──▶ Board (editor)
root.watch() ──▶ BoardView (viewer)
```

| Capability | Methods |
| --- | --- |
| `Board` (editor) | `snapshot`, `add`, `clear`, `subscribe` |
| `BoardView` (viewer) | `snapshot`, `subscribe` |

Read-only is not a flag checked per call: the viewer's object simply has no
`add` or `clear`, so a call fails at the capability boundary. The tests assert
that calling `add` on a read-only board throws.

- **State:** the room's SQLite, one row per stroke, points stored as JSON.
- **Transport:** Cap'n Web over WebSocket (capabilities are passed by
  reference, so this can't use HTTP RPC).
- **Contract:** `canvas/api.gleam` declares and implements the editor and viewer
  capabilities. Both clients and dispatchers are generated; UI helpers declare
  no independent RPC names or reply decoders.
- **Events:** `starflame/topic` carries typed `BoardEvent` values. Generated
  callbacks encode them, and generated target disposal closes subscriptions.
- **Rendering:** `<canvas>` + pointer events; points are normalised to 0..1.

## Tests

```sh
pnpm --filter @starflame/example-canvas test
```

The Miniflare suite drives generated Gleam clients and raw Cap'n Web: `enter`
returns a stub, the read-only capability refuses `add`, validation rejects empty
strokes and unknown colours, strokes round-trip through the object's SQLite, `subscribe` receives
live `StrokeAdded` and `Cleared` events plus presence, rooms are isolated, and
strokes survive a restart. It also checks typed Clear replies, generated event
decoding, subscription replacement, and cleanup when capabilities are disposed.
Compiler regression tests in the RPC kit reject incompatible implementations,
stale generation, and callers expecting an old capability return type.

## Limits

- No undo, erasing, colours, or stroke smoothing. One fixed colour and width.
- Presence counts capabilities that subscribed, not sockets.
- Edits are last-write-wins; there is no conflict handling beyond append-only
  strokes and a whole-board clear.
- The board is public: anyone with the room name can enter as an editor.
