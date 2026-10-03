import { toList } from "../gleam.mjs";

export function newLog() {
  return [];
}

export function push(log, entry) {
  log.push(entry);
}

export function entries(log) {
  return toList(log);
}
