const SESSION = "blackjack:session";

export function getItem(key) {
  try {
    return localStorage.getItem(key) ?? "";
  } catch {
    return "";
  }
}

export function setItem(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Private mode: the table still works, the name just isn't remembered.
  }
}

// main.ts fetches a session before loading this module, so this is only a
// fallback for a stale page.
export function session() {
  return getItem(SESSION);
}

export function tableName() {
  const parts = location.pathname.split("/").filter(Boolean);
  const raw = parts[0] === "t" && parts[1] ? decodeURIComponent(parts[1]) : "lobby";
  return sanitise(raw);
}

export function sanitise(raw) {
  const cleaned = String(raw)
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "")
    .slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}
