import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { Error, Ok } from "./gleam.mjs";

export function set_exit_code(code) {
  process.exitCode = code;
}

/// Lays out Gleam source with the installed `gleam format`.
export function format(source) {
  const result = spawnSync("gleam", ["format", "--stdin"], {
    input: source,
    encoding: "utf8",
  });
  if (result.status === 0) return new Ok(result.stdout);
  const detail = String(result.stderr || result.error?.message).trim();
  return new Error("gleam format failed: " + detail);
}

/// Exports the package interface of the API module and the modules it
/// imports. The generated modules import the API, so after the API changes
/// they may not compile; exporting from a copy without them still works.
export function export_interface(root, api, generated) {
  root = resolve(root);
  const scratch = join(root, "build", "starflame_rpc_kit", "project");
  try {
    const src = join(root, "src");
    const modules = closure(src, api, generated);
    // Tells tools like @starflame/vite which changes can affect the API.
    mkdirSync(dirname(scratch), { recursive: true });
    writeIfChanged(
      join(dirname(scratch), "sources.json"),
      JSON.stringify({ sources: [...modules].map((module) => `src/${module}.gleam`).sort() }) + "\n",
    );

    mkdirSync(scratch, { recursive: true });
    for (const file of ["gleam.toml", "manifest.toml"]) {
      const path = join(root, file);
      if (!existsSync(path)) continue;
      writeIfChanged(join(scratch, file), absolutePaths(readFileSync(path, "utf8"), root));
    }
    const packages = join(root, "build", "packages");
    const scratchPackages = join(scratch, "build", "packages");
    const list = (dir) => {
      const path = join(dir, "packages.toml");
      return existsSync(path) ? readFileSync(path, "utf8") : null;
    };
    if (existsSync(packages) && list(packages) !== list(scratchPackages)) {
      rmSync(scratchPackages, { recursive: true, force: true });
      cpSync(packages, scratchPackages, { recursive: true, preserveTimestamps: true });
    }

    rmSync(join(scratch, "src"), { recursive: true, force: true });
    for (const file of supportFiles(src, join(src, generated))) {
      copy(join(src, file), join(scratch, "src", file));
    }
    for (const module of modules) {
      copy(join(src, module + ".gleam"), join(scratch, "src", module + ".gleam"));
    }

    const out = join(scratch, "interface.json");
    rmSync(out, { force: true });
    const result = spawnSync("gleam", ["export", "package-interface", "--out", out], {
      cwd: scratch,
      encoding: "utf8",
    });
    if (result.status !== 0) {
      const output = (result.stdout ?? "") + (result.stderr ?? "") || String(result.error);
      // Point at the app's files rather than the copies.
      return new Error(output.split(scratch + "/").join(root + "/").trim());
    }
    return new Ok(readFileSync(out, "utf8"));
  } catch (error) {
    return new Error(String(error?.message ?? error));
  }
}

/// `api` and every module of the app it imports, directly or not.
function closure(src, api, generated) {
  const found = new Set();
  const visit = (module, from) => {
    if (found.has(module)) return;
    if (module === generated || module.startsWith(generated + "/")) {
      throw `${from} imports ${module}, but the API can't depend on generated code.`;
    }
    const path = join(src, module + ".gleam");
    if (!existsSync(path)) {
      if (from === null) throw `There's no module ${module} in src/.`;
      return; // A dependency's module.
    }
    found.add(module);
    const source = readFileSync(path, "utf8");
    for (const [, imported] of source.matchAll(/^import\s+([a-z][a-z0-9_]*(?:\/[a-z][a-z0-9_]*)*)/gm)) {
      visit(imported, module);
    }
  };
  visit(api, null);
  return found;
}

/// FFI and other non-Gleam files, outside the generated directory.
function supportFiles(src, skip) {
  const files = [];
  const walk = (dir) => {
    if (dir === skip || !existsSync(dir)) return;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (!entry.name.endsWith(".gleam")) files.push(relative(src, path));
    }
  };
  walk(src);
  return files;
}

function copy(from, to) {
  mkdirSync(dirname(to), { recursive: true });
  cpSync(from, to, { preserveTimestamps: true });
}

/// The copy lives elsewhere, so path dependencies need absolute paths.
function absolutePaths(toml, root) {
  return toml.replace(/path = "([^"]+)"/g, (match, path) =>
    isAbsolute(path) ? match : `path = "${resolve(root, path)}"`,
  );
}

function writeIfChanged(path, content) {
  if (existsSync(path) && readFileSync(path, "utf8") === content) return;
  writeFileSync(path, content);
}
