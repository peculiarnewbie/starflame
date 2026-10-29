export function random_id() {
  return crypto.randomUUID().replace(/-/g, "").slice(0, 16);
}

export function now_ms() {
  return Date.now();
}
