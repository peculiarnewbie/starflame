import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chromium } from "playwright";
import { newHttpBatchRpcSession } from "capnweb";

// Run against the dev server, or pass a deployed URL. Only our own rows are removed.
const base = process.argv[2] ?? "http://localhost:5173";
const browser = await chromium.launch({ headless: true });
const prefix = `Compare ${randomUUID()}`;
const errors = [];
const contexts = [];
const pages = [];
const input = (page) => page.getByRole("textbox", { name: "New todo" });
const item = (page, title) => page.locator("li").filter({ hasText: title });
const rpc = () => newHttpBatchRpcSession(new URL("/rpc", base).href);

try {
  for (const route of ["/", "/live", "/live", "/server", "/server"]) {
    const context = await browser.newContext();
    contexts.push(context);
    await context.addInitScript(() => {
      window.testSockets = [];
      const Native = window.WebSocket;
      window.WebSocket = new Proxy(Native, {
        construct(target, args) {
          const socket = new target(...args);
          window.testSockets.push(socket);
          return socket;
        },
      });
    });
    const page = await context.newPage();
    page.on("pageerror", (error) => errors.push(`${route}: ${error.message}`));
    await page.goto(new URL(route, base).href);
    await page.getByText("live", { exact: true }).waitFor();
    pages.push(page);
  }
  const [baseline, liveA, liveB, serverA, serverB] = pages;
  await input(liveB).fill("Private browser draft");
  await input(serverB).fill("Private server draft");
  const title = `${prefix} from server`;
  await input(serverA).fill(title);
  await input(serverA).press("Enter");
  for (const page of [liveA, liveB, serverA, serverB]) await item(page, title).waitFor();
  assert.equal(await item(baseline, title).count(), 0);
  assert.equal(await input(liveB).inputValue(), "Private browser draft");
  assert.equal(await input(serverB).inputValue(), "Private server draft");
  await baseline.evaluate(() => window.dispatchEvent(new Event("focus")));
  await item(baseline, title).waitFor();
  console.log("PASS server create pushes to both live routes; baseline refreshes on focus; drafts stay private");

  await item(liveA, title).getByRole("checkbox").check();
  for (const page of [liveB, serverA, serverB]) {
    await page.waitForFunction((title) => {
      const root = document.querySelector("lustre-server-component")?.shadowRoot ?? document;
      return [...root.querySelectorAll("li")].some((row) => row.textContent.includes(title) && row.querySelector("input").checked);
    }, title);
  }
  await serverB.getByRole("button", { name: "Done", exact: true }).click();
  await item(serverB, title).waitFor();
  assert.ok(await serverA.getByRole("button", { name: "All", exact: true }).evaluate((element) => element.classList.contains("selected")));
  await item(serverB, title).getByRole("button", { name: `Delete ${title}` }).click();
  for (const page of [liveA, liveB, serverA, serverB]) await item(page, title).waitFor({ state: "detached" });
  console.log("PASS browser update and server delete push across routes; filters stay private");

  const second = `${prefix} from baseline`;
  await input(baseline).fill(second);
  await input(baseline).press("Enter");
  await serverB.getByRole("button", { name: "All", exact: true }).click();
  for (const page of pages) {
    try { await item(page, second).waitFor(); }
    catch (error) {
      console.error("Failed route:", page.url());
      console.error(await page.evaluate(() => {
        const root = document.querySelector("lustre-server-component")?.shadowRoot ?? document;
        return root.textContent;
      }));
      throw error;
    }
  }
  await serverA.reload();
  await item(serverA, second).waitFor();
  console.log("PASS original route writes broadcast; server UI restores persisted data after reload");

  for (const [page, context, path] of [[liveA, contexts[1], "/live/rpc"], [serverA, contexts[3], "/server/socket"]]) {
    if (path === "/server/socket") await input(page).fill("Reconnect marker");
    await context.setOffline(true);
    await page.evaluate((path) => {
      for (const socket of window.testSockets) {
        if (new URL(socket.url).pathname === path) socket.close();
      }
    }, path);
    if (path === "/live/rpc") await page.getByText("reconnecting…", { exact: true }).waitFor();
    await context.setOffline(false);
    if (path === "/server/socket") {
      // A new server session mounts a fresh UI. Waiting for the draft reset
      // prevents the old, still-visible DOM from falsely passing this check.
      await page.waitForFunction(() =>
        document.querySelector("lustre-server-component")?.shadowRoot?.querySelector("input.new-todo")?.value === "",
      );
    }
    await page.getByText("live", { exact: true }).waitFor();
    await item(page, second).waitFor();
  }
  console.log("PASS both live approaches reconnect and restore the current list");

  for (const path of ["/rpc", "/live/rpc", "/server/socket"]) {
    const response = await fetch(new URL(path, base), { headers: { Origin: "https://other.example" } });
    assert.equal(response.status, 403);
  }
  assert.deepEqual(errors, []);
  console.log("PASS origin rejection on all transports; no browser runtime errors");
} finally {
  try {
    const todos = await rpc().list_todos();
    for (const todo of todos) {
      if (todo.title.startsWith(prefix)) await rpc().delete_todo(todo.id);
    }
  } finally {
    await browser.close();
  }
}
