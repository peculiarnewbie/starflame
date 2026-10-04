import { execFileSync } from "node:child_process";
import { Error, Ok } from "./gleam.mjs";

export function set_exit_code(code) {
  process.exitCode = code;
}

/// Lays out Gleam source with the installed `gleam format`.
export function format(source) {
  try {
    return new Ok(
      execFileSync("gleam", ["format", "--stdin"], {
        input: source,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      }),
    );
  } catch (error) {
    const detail = String(error.stderr || error.message).trim();
    return new Error("gleam format failed: " + detail);
  }
}
