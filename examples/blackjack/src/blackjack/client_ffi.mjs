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

export function session() {
  return getItem(SESSION);
}

/// "/app/blackjack" when mounted on the shared domain, "" on workers.dev.
export function basePath() {
  const parts = location.pathname.split("/").filter(Boolean);
  return parts[0] === "app" && parts[1] ? `/app/${parts[1]}` : "";
}

export function tableName() {
  const path = location.pathname.slice(basePath().length);
  const parts = path.split("/").filter(Boolean);
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
