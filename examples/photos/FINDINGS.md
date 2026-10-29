# What building this found

Notes from building an R2-backed upload demo. These are framework gaps, not
bugs in this example.

## 1. The wire had no binary type — fixed

`starflame/plain` covered Int, Float, String, Bool, Nil, List, tuple, Option,
Dict and custom types. There was no way to send bytes, so uploads would have
needed base64 (33% larger, stringly typed) or a side-channel HTTP route that
bypasses RPC entirely.

The wire layer now supports `BitArray` as first-class:

```gleam
pub fn bit_array(value: BitArray) -> Plain
pub fn bit_array_decoder() -> Decoder(BitArray)
// fast_decode.BytesKind
```

The representation is Cap'n Web's native `bytes` (a `Uint8Array`), so it is
compact and typed. Only byte-aligned arrays are supported: a 3-bit BitArray
fails loudly rather than silently padding. There is no size limit at this
layer — backpressure is the app's job.

**Remaining:** there is no stream type. A 100 MB upload still has to be one
`BitArray` in memory on both sides. For large files the right shape is a
presigned R2 URL or a direct `PUT` route, not RPC. The runtime should say that
in the docs rather than imply RPC is for everything.

## 2. There were no R2 bindings — fixed, minimally

Only D1 and Durable Objects came with the runtime. `starflame/r2` now wraps the
three operations most apps need:

```gleam
let bucket = r2.bucket(context, "BUCKET")
r2.put(bucket, key, body, content_type)
r2.get(bucket, key)     // Option(#(BitArray, content_type, size))
r2.delete(bucket, key)
```

**Not covered:** range requests, multipart uploads, presigned URLs, custom
metadata and listing. Those matter for real apps; the module should grow only
when a demo needs them, otherwise it will drift from R2's actual surface.

## 3. HTTP RPC without a Durable Object works well

This app has no state to serialize, so the Worker calls
`newWorkersRpcResponse(request, newApi(env, ctx, owner))` directly and the
client uses `connect_http`. No DO, no websocket, no reconnect logic for reads.
That combination is a good default for CRUD apps and is much simpler than the
todo/blackjack shape. Worth documenting as the starting point.

## 4. Serving from R2 is hand-written

`/photos/:id` reads the bucket and builds a `Response` in `worker.ts`. That is
fine, but every app repeats it: find the object, fall back to 404, set the
content type, set cache headers, pass the body through. A
`starflame/r2.respond(object)` helper (or a documented recipe) would remove a
repeated 15-line block.

## 5. Binary validation is the app's problem

The API checks size and content type, but the framework offers no shared notion
of "request limits". The 2 MB cap is real (the body is buffered in memory), and
it is enforced after the RPC layer has already accepted the bytes. A limit
enforced before buffering would be a runtime concern, not an app one.

## Verdict

Adding binary was a contained change with a big payoff: uploads are now an
ordinary typed RPC call. The remaining friction is about size, not capability —
streaming and presigned URLs are deliberately outside RPC, and that boundary
deserves to be documented rather than papered over.
