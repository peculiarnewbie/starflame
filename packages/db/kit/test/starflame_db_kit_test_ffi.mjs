import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { Error, Ok } from "./gleam.mjs";

export function row_text(row) {
  return Object.values(row)
    .map((value) => (value === null ? "" : String(value)))
    .join("|");
}

export function shell(directory, command, args) {
  const result = spawnSync(command, args.toArray(), {
    cwd: directory,
    encoding: "utf8",
  });
  const output = (result.stdout ?? "") + (result.stderr ?? "");
  return result.status === 0 ? new Ok(output) : new Error(output);
}

export function absolute(path) {
  return resolve(path);
}
