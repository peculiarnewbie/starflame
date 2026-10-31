// The landing page at starflame.peculiarnewbie.com. Each demo is mounted at
// /app/<name> with its own route, which is more specific than this one.

const apps = [
  {
    href: "/app/blackjack/",
    name: "Blackjack",
    blurb:
      "A six-deck table with splits, insurance and per-player views. Why: codecs, identity, Durable Object orchestration.",
  },
  {
    href: "/app/chat/",
    name: "Chat",
    blurb:
      "Hibernating WebSockets with typed push envelopes. Why: the boundary between Cap'n Web sessions and eviction.",
  },
  {
    href: "/app/canvas/",
    name: "Canvas",
    blurb:
      "A shared board where read-only is a capability without the editing methods. Why: capabilities and their lifecycle.",
  },
  {
    href: "/app/photos/",
    name: "Photos",
    blurb:
      "Uploads through RPC with bodies in R2. Why: binary on the wire, and where streaming stops being RPC's job.",
  },
];

const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>starflame</title>
    <style>
      :root {
        color-scheme: dark;
        --bg: #0c0e12;
        --panel: #14171d;
        --line: #262b33;
        --text: #e9edf3;
        --muted: #8b94a3;
        --accent: #ffb86b;
        font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
      }
      * { box-sizing: border-box; }
      body { margin: 0; background: var(--bg); color: var(--text); min-height: 100vh; }
      .wrap { max-width: 62rem; margin: 0 auto; padding: 4rem 1.25rem; }
      header { display: flex; align-items: baseline; gap: 0.8rem; }
      h1 { margin: 0; font-size: 2.4rem; letter-spacing: -0.04em; }
      .dot { color: var(--accent); }
      .tagline { color: var(--muted); margin: 0.6rem 0 0; max-width: 38rem; line-height: 1.55; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 1rem; margin-top: 3rem; }
      a.card {
        display: block; text-decoration: none; color: inherit; background: var(--panel);
        border: 1px solid var(--line); border-radius: 0.9rem; padding: 1.1rem 1.2rem;
        transition: border-color 120ms, transform 120ms;
      }
      a.card:hover { border-color: var(--accent); transform: translateY(-2px); }
      .card h2 { margin: 0 0 0.45rem; font-size: 1.05rem; }
      .card p { margin: 0; color: var(--muted); font-size: 0.85rem; line-height: 1.5; }
      footer { margin-top: 3.5rem; color: var(--muted); font-size: 0.8rem; }
      code { color: var(--accent); }
    </style>
  </head>
  <body>
    <div class="wrap">
      <header><h1>starflame<span class="dot">.</span></h1></header>
      <p class="tagline">
        Full-stack functional programming in Gleam on Cloudflare Workers.
        Each demo below is a real Worker, mounted under <code>/app</code>, and
        each one exists to stress a different part of the runtime.
      </p>
      <div class="grid">
        ${apps
          .map(
            (app) => `<a class="card" href="${app.href}">
              <h2>${app.name}</h2>
              <p>${app.blurb}</p>
            </a>`,
          )
          .join("\n")}
      </div>
      <footer>Built with Gleam, Lustre, Cap'n Web and Durable Objects.</footer>
    </div>
  </body>
</html>`;

export default {
  fetch() {
    return new Response(html, {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
};
