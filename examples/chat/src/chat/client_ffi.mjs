export function session() {
  return localStorage.getItem("chat:session") ?? "";
}

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
  } catch {}
}

export function basePath() {
  const parts = location.pathname.split("/").filter(Boolean);
  return parts[0] === "app" && parts[1] ? `/app/${parts[1]}` : "";
}

export function roomName() {
  const path = location.pathname.slice(basePath().length);
  const parts = path.split("/").filter(Boolean);
  const raw = parts[0] === "r" && parts[1] ? decodeURIComponent(parts[1]) : "lobby";
  const cleaned = raw.toLowerCase().replace(/[^a-z0-9_-]/g, "").slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}

export function socketUrl(room, name) {
  const params = new URLSearchParams({
    room,
    session: session(),
    name,
  });
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${location.host}${basePath()}/socket?${params}`;
}

export function socket(url, onText, onStatus) {
  let socket;
  let stopped = false;
  let attempts = 0;

  const open = () => {
    socket = new WebSocket(url);
    socket.onopen = () => {
      attempts = 0;
      onStatus("open");
    };
    socket.onclose = () => {
      onStatus("closed");
      if (!stopped) {
        const delay = Math.min(5000, 400 * 2 ** attempts++);
        setTimeout(open, delay);
      }
    };
    socket.onerror = () => socket.close();
    socket.onmessage = (event) => onText(event.data);
  };

  open();
  return () => {
    stopped = true;
    socket?.close();
  };
}

export function parseJson(text) {
  return JSON.parse(text);
}

export function timeLabel(ms) {
  return new Date(ms).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}
