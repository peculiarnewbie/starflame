// Bundles worker.ts, runs it in Miniflare, then plays at two tables through the
// generated Gleam client. Usage: pnpm test (runs `gleam build` first).

import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import * as client from "../build/dev/javascript/blackjack/blackjack/generated/client.mjs";
import * as shared from "../build/dev/javascript/blackjack/blackjack/shared.mjs";

const root = resolve(fileURLToPath(import.meta.url), "../..");
const outfile = `${root}/.test/worker.mjs`;

await build({
  entryPoints: [`${root}/worker.ts`],
  outfile,
  bundle: true,
  format: "esm",
  platform: "neutral",
  conditions: ["workerd", "worker", "import"],
  mainFields: ["module", "main"],
  external: ["cloudflare:*"],
  logLevel: "warning",
});

const options = convertV4MiniflareOptions({
  modules: true,
  scriptPath: outfile,
  compatibilityDate: "2026-09-30",
  port: 8798, // fixed, so reconnecting after a restart hits the same URL
  d1Databases: ["DB"],
  durableObjects: {
    TABLE: { className: "BlackjackTable", useSQLite: true },
  },
});
const mf = new Miniflare(options);
const base = await mf.ready;
const httpBase = `http://${base.host}`;

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`  ${ok ? "PASS" : "FAIL"} ${name}  ${detail}`);
  if (!ok) failures++;
};
const arr = (list) => (Array.isArray(list) ? list : list.toArray());
const ok = (reply) => reply.isOk() && reply[0].isOk();
const gameError = (reply) =>
  reply.isOk() && !reply[0].isOk() ? reply[0][0] : null;
const errorName = (reply) => gameError(reply)?.constructor?.name ?? null;
const some = (option) => (option?.constructor?.name === "Some" ? option[0] : null);
const phase = (view) => view.phase.constructor.name;
const players = (view) => arr(view.players);
const tick = () => new Promise((r) => setTimeout(r, 40));

async function newSession() {
  const response = await fetch(`${httpBase}/session`);
  assert.equal(response.status, 200);
  return (await response.json()).session;
}

async function open(table, session) {
  const token = session ?? (await newSession());
  const socket = client.connect(
    `ws://${base.host}/rpc?table=${table}&session=${token}`,
  );
  const views = [];
  return {
    session: socket,
    token,
    views,
    latest: () => views.at(-1),
    async subscribe() {
      const reply = await client.subscribe(socket, (view) => views.push(view));
      assert.ok(reply.isOk(), `subscribe failed: ${JSON.stringify(reply)}`);
      await tick();
    },
    async join(name) {
      const reply = await client.join(socket, name);
      await tick();
      return reply;
    },
    async act(action) {
      const reply = await client.act(socket, action);
      await tick();
      return reply;
    },
  };
}

console.log("\n# Origin and routing");
{
  const forbidden = await fetch(`${httpBase}/rpc?table=t1&session=0123456789`, {
    headers: { Origin: "https://evil.example" },
  });
  check("cross-origin RPC rejected", forbidden.status === 403, String(forbidden.status));

  const anonymous = await fetch(`${httpBase}/rpc?table=t1`);
  check("RPC without a session is rejected", anonymous.status === 401, String(anonymous.status));

  const session = await newSession();
  check("sessions are unguessable", /^[0-9a-f-]{36}$/.test(session), session);
}

console.log("\n# Seating");
const ada = await open("t1");
const bob = await open("t1");
check("each browser gets its own session", ada.token !== bob.token);
await ada.subscribe();
await bob.subscribe();
{
  const joined = await ada.join("Ada");
  check("join returns the caller's view", ok(joined) && joined[0][0].my_id.length === 16);
  await bob.join("Bob");
  const view = ada.latest();
  check("both players are seated", players(view).length === 2, String(players(view).length));
  check("dealer value is unknown before the deal", view.dealer.value?.constructor?.name === "None");
  check("no cards until everyone bets", phase(view) === "Betting");
  check("players see different ids", ada.latest().my_id !== bob.latest().my_id);
  check(
    "the view exposes no session token",
    !JSON.stringify(ada.latest()).includes(ada.token),
  );
}

console.log("\n# Turn order and validation");
const chipsBefore = {};
{
  const view = ada.latest();
  for (const p of players(view)) chipsBefore[p.id] = p.chips;

  const outside = await bob.act(new shared.Hit());
  check("acting before the deal is refused", errorName(outside) !== null);
  check("the error is WrongPhase", errorName(outside) === "WrongPhase", errorName(outside));

  await ada.act(new shared.PlaceBet(10));
  check("one bet does not deal", phase(ada.latest()) === "Betting");
  const again = await ada.act(new shared.PlaceBet(10));
  check("a second bet is refused", errorName(again) === "AlreadyBet", errorName(again));

  await bob.act(new shared.PlaceBet(25));
  check("both bets deal", phase(ada.latest()) !== "Betting", phase(ada.latest()));
  check(
    "dealer hole card is hidden during play",
    phase(ada.latest()) === "Settled"
      ? true
      : arr(ada.latest().dealer.cards)[1]?.constructor.name === "Hidden",
  );

  if (phase(ada.latest()) === "Playing") {
    const view = ada.latest();
    const current = players(view)[view.current_player_index];
    const other = current.id === view.my_id ? bob : ada;
    const refused = await other.act(new shared.Hit());
    check("out-of-turn hit is refused", errorName(refused) === "NotYourTurn", errorName(refused));
  }
}

console.log("\n# Playing a round to settlement");
{
  for (let step = 0; step < 40 && phase(ada.latest()) === "Playing"; step++) {
    const view = ada.latest();
    const current = players(view)[view.current_player_index];
    const seat = current.id === ada.latest().my_id ? ada : bob;
    // Stand on every hand so the round always ends.
    const reply = await seat.act(new shared.Stand());
    assert.ok(ok(reply), `stand failed: ${JSON.stringify(reply)}`);
  }
  const view = ada.latest();
  check("round settled", phase(view) === "Settled", phase(view));
  check("dealer is revealed", arr(view.dealer.cards)[1]?.constructor.name === "Shown");
  check("dealer has a value", view.dealer.value?.constructor?.name === "Some");
  const results = some(view.results);
  check("results cover every player", results !== null && arr(results).length === 2);
  check("results are per hand", results !== null && arr(results).every((r) => arr(r.hands).length >= 1));
  check("nobody can act after settlement", errorName(await bob.act(new shared.Hit())) !== null);

  const chipsAfter = {};
  for (const p of players(view)) chipsAfter[p.id] = p.chips;
  const nets = Object.fromEntries(arr(results).map((r) => [r.player_id, r.net_chips]));
  check(
    "chips move by the reported net",
    Object.keys(chipsBefore).every((id) => chipsAfter[id] - chipsBefore[id] === nets[id]),
    JSON.stringify(nets),
  );
}

console.log("\n# Next round");
{
  await ada.act(new shared.NewRound());
  const view = ada.latest();
  check("round number advanced", view.round_number === 2, String(view.round_number));
  check("back to betting", phase(view) === "Betting");
  check("bets are cleared", players(view).every((p) => p.bet === 0));
  check("results are cleared", view.results?.constructor?.name === "None");
  check("the shoe persists between rounds", view.shoe_count < 312 && view.shoe_count > 0, String(view.shoe_count));
}

console.log("\n# Restart persistence");
const chipsBeforeRestart = players(ada.latest()).map((p) => [p.id, p.chips]);
{
  await mf.setOptions(options); // restarts workerd, like a deploy
  await tick();

  const fresh = await open("t1", ada.token);
  await fresh.subscribe();
  const view = fresh.latest();
  check("the table survives a restart", view !== undefined && players(view).length === 2, String(view ? players(view).length : "no view"));
  check(
    "chips survive",
    JSON.stringify(players(view).map((p) => [p.id, p.chips])) === JSON.stringify(chipsBeforeRestart),
  );
  check("the session still resolves to the same player", view.my_id === ada.latest().my_id);
  check("round number survives", view.round_number === 2, String(view.round_number));
  client.dispose(fresh.session);
}

console.log("\n# Table isolation");
{
  const other = await open("t2");
  await other.subscribe();
  check("a second table starts empty", players(other.latest()).length === 0);
  client.dispose(other.session);
}

try { client.dispose(ada.session); } catch {}
try { client.dispose(bob.session); } catch {}
await mf.dispose();
console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
