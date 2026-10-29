import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { Error, Ok } from "./gleam.mjs";
import { absolutePaths } from "./starflame_rpc_kit_ffi.mjs";

export function shell(directory, command, args) {
  const result = spawnSync(command, args.toArray(), {
    cwd: directory,
    encoding: "utf8",
  });
  const output = (result.stdout ?? "") + (result.stderr ?? "");
  return result.status === 0 ? new Ok(output) : new Error(output);
}

export function fixture_project(name) {
  const fixture = resolve("test/fixtures/codecs");
  const root = resolve("build/kit-test", name);
  mkdirSync(root, { recursive: true });
  rmSync(`${root}/src`, { recursive: true, force: true });
  cpSync(`${fixture}/src`, `${root}/src`, { recursive: true });
  // gleeunit scans every .gleam under test/, including nested projects.
  for (const file of readdirSync(`${root}/src`, { recursive: true })) {
    if (file.endsWith(".gleam.in")) renameSync(`${root}/src/${file}`, `${root}/src/${file.slice(0, -3)}`);
  }
  const dependencies = resolve("build/kit-test/dependencies");
  mkdirSync(dependencies, { recursive: true });
  for (const file of ["gleam.toml", "manifest.toml"]) {
    const source = absolutePaths(readFileSync(`${fixture}/${file}`, "utf8"), fixture);
    writeFileSync(`${root}/${file}`, source);
    writeFileSync(`${dependencies}/${file}`, source);
  }
  if (!existsSync(`${dependencies}/build/packages/packages.toml`)) {
    const result = spawnSync("gleam", ["deps", "download"], { cwd: dependencies, encoding: "utf8" });
    if (result.status !== 0) throw new globalThis.Error((result.stdout ?? "") + (result.stderr ?? ""));
  }
  if (!existsSync(`${root}/build/packages/packages.toml`)) {
    mkdirSync(`${root}/build`, { recursive: true });
    cpSync(`${dependencies}/build/packages`, `${root}/build/packages`, { recursive: true });
  }
  return root;
}
