# Benchmarks

The same five RPC methods, served by each framework from the same D1 table,
measured under Miniflare's workerd on one machine. Absolute numbers aren't
production numbers; the comparison between targets is the point.

```sh
pnpm install
pnpm --filter @starflame/bench bench            # everything, ~10 minutes
node bench/run.mjs --check                     # does every target answer correctly?
node bench/run.mjs --targets starflame-ws,hono --operations list --duration 10
```

Needs Gleam, Node 22.17 or later, and Linux, since server CPU is read from
`/proc`. Results go to `bench/results/`, which is ignored.

## Methods

| Operation | Call | Exercises |
| --- | --- | --- |
| `ping` | `ping(1)` returns `2` | RPC overhead alone |
| `echo` | `echo_todos(todos)` returns the same 50 todos | decoding and encoding a payload |
| `list` | `list_todos()` returns 50 rows | a D1 read, 50 rows |
| `get` | `get_todo(id)` returns one row or null | a D1 point read |
| `add` | `add_todo(title)` returns the new row | a D1 write with `RETURNING` |

Every app validates arguments as strictly as Starflame's decoders: integers
must be safe integers, and every todo field must have the right type.

## Targets

| Target | Server | Client |
| --- | --- | --- |
| `starflame-ws` | [Starflame](starflame): Gleam API, wire codecs and the `starflame_db` generated module behind a Cap'n Web target | Cap'n Web WebSocket session |
| `starflame-http` | the same | Cap'n Web HTTP batch, one POST per call |
| `capnweb-ws` | [Cap'n Web](capnweb) in plain TypeScript with the same methods | Cap'n Web WebSocket session |
| `capnweb-http` | the same | Cap'n Web HTTP batch |
| `plain` | [a bare fetch handler](plain) with JSON routes | `fetch` |
| `hono` | [Hono](hono) with the same JSON routes | `fetch` |
| `sveltekit` | [SvelteKit 3](sveltekit) remote functions (`query`/`command`, experimental) with valibot | `fetch`, as SvelteKit's client sends it |

`capnweb-*` isolates what Starflame adds to Cap'n Web; `plain` is the floor
for an HTTP request, so `hono - plain` is Hono's overhead. The TypeScript apps
share [the D1 queries](shared/todos.ts). The schema is the migration the
Starflame app's [Gleam schema](starflame/src/bench/schema.gleam) generates,
applied to every app with 1,000 seeded rows.

## How it measures

- Each target runs in a fresh Miniflare with in-memory D1. Requests go
  straight to the worker's socket, not through Miniflare's entry worker,
  which production doesn't have and which costs several hundred microseconds
  per HTTP request.
- A separate Node process drives the load from worker threads, so its CPU
  isn't counted as the server's. Each virtual user makes one call at a time,
  back to back; WebSocket users keep one session.
- After a warmup, only calls that start inside the measured window count.
  Latencies include the client's own encoding and decoding.
- **Server CPU per request** is the CPU time of every workerd thread during
  the window, from `/proc/<pid>/task/*/schedstat`, divided by the calls
  completed. It includes the D1 simulator, which runs in the same process, so
  D1 operations share a large fixed cost.
- At concurrency 32 workerd's JavaScript thread is saturated, so requests per
  second there is server throughput. Check the client cores in the console
  output stay well under `--threads`; otherwise the client is the limit.
- Before measuring, every target's answers are checked, so a broken target
  fails instead of reporting fast errors.

Worker bundle sizes are each worker's final bundle, minified by esbuild.

## Caveats

- One machine, local workerd: no network, no real D1, and no isolate limits.
- WebSocket calls skip HTTP request handling entirely; that's a real
  advantage of a session, but not a like-for-like transport comparison.
- SvelteKit's remote functions are experimental, and their wire format isn't
  public. The client here does what SvelteKit's generated client does, read
  from its source.
