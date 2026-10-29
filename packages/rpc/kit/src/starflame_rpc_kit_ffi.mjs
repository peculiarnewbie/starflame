import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { Error, Ok, toList } from "./gleam.mjs";

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
export function export_interface(root, api, generated, typesOnly) {
  root = resolve(root);
  const scratch = join(root, "build", "starflame_rpc_kit", "project");
  try {
    const src = join(root, "src");
    const modules = closure(src, api, generated, typesOnly);
    // Tells tools like @starflame/vite which changes can affect the API.
    mkdirSync(dirname(scratch), { recursive: true });
    const sources = [...modules].map((module) => `src/${module}.gleam`).sort();
    if (typesOnly) {
      const path = join(dirname(scratch), "codecs-sources.json");
      const entries = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {};
      entries[api] = sources;
      writeIfChanged(path, JSON.stringify(entries) + "\n");
    } else {
      writeIfChanged(join(dirname(scratch), "sources.json"), JSON.stringify({ sources }) + "\n");
    }

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
function closure(src, api, generated, typesOnly) {
  const found = new Set();
  const visit = (module, from) => {
    if (found.has(module)) return;
    if (module === generated || (!typesOnly && module.startsWith(generated + "/"))) {
      throw `${from} imports ${module}, but the ${typesOnly ? "types module" : "API"} can't depend on generated code.`;
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

/// The copy lives elsewhere, so local path dependencies need absolute paths.
/// They're inline tables, in gleam.toml and manifest.toml alike. A git
/// dependency's `path` is a directory in its repository, and stays relative.
export function absolutePaths(toml, root) {
  return toml.replace(/\{[^{}]*\}/g, (table) =>
    /\bgit\s*=|source\s*=\s*"git"/.test(table)
      ? table
      : table.replace(/\bpath\s*=\s*"([^"]+)"/g, (match, path) =>
          isAbsolute(path) ? match : `path = "${resolve(root, path)}"`,
        ),
  );
}

function writeIfChanged(path, content) {
  if (existsSync(path) && readFileSync(path, "utf8") === content) return;
  writeFileSync(path, content);
}

/// Replace only after the complete output has been written successfully.
export function atomic_write(path, content) {
  const temporary = `${path}.${process.pid}.tmp`;
  try {
    writeFileSync(temporary, content, { flag: "wx" });
    renameSync(temporary, path);
    return new Ok(undefined);
  } catch (error) {
    return new Error(String(error?.message ?? error));
  } finally {
    rmSync(temporary, { force: true });
  }
}

/// Read the string array in [starflame]. No other Gleam configuration is
/// interpreted here. Both TOML string quotes, comments and multiline arrays
/// are accepted; entries themselves must be unambiguous module paths.
export function codec_entries(toml) {
  try {
    const uncommented = toml.replace(/"(?:\\.|[^"\\])*"|'[^']*'|#[^\r\n]*/g,
      (token) => token.startsWith("#") ? "" : token);
    const sections = uncommented.split(/^\s*\[([^\]\r\n]+)\][ \t]*\r?$/m);
    const entries = [];
    let found = false;
    for (let i = 1; i < sections.length; i += 2) {
      if (sections[i].trim() !== "starflame") continue;
      const section = sections[i + 1];
      const assignments = [...section.matchAll(/^[ \t]*codecs\s*=/gm)];
      if (!assignments.length) continue;
      if (found || assignments.length > 1) throw "codecs is defined more than once";
      found = true;
      let rest = section.slice(assignments[0].index + assignments[0][0].length).trimStart();
      if (!rest.startsWith("[")) throw "codecs must be an array of \"<module>:<out>\" strings";
      rest = rest.slice(1).trimStart();
      while (!rest.startsWith("]")) {
        const match = /^("(?:\\.|[^"\\\r\n])*"|'[^'\r\n]*')/.exec(rest);
        if (!match) throw "codecs must be an array of \"<module>:<out>\" strings";
        const value = match[0].startsWith('"') ? JSON.parse(match[0]) : match[0].slice(1, -1);
        entries.push(value.split(":"));
        rest = rest.slice(match[0].length).trimStart();
        if (rest.startsWith("]")) break;
        if (!rest.startsWith(",")) throw "expected a comma between codecs entries";
        rest = rest.slice(1).trimStart();
      }
      if (!/^\][ \t]*(?:\r?\n|$)/.test(rest)) throw "unexpected content after codecs array";
    }
    return new Ok(toList(entries));
  } catch (error) {
    return new Error(`Invalid [starflame].codecs: ${error?.message ?? error}.`);
  }
}

export function validate_codec_entries(entries) {
  const outputs = new Set();
  const modulePath = /^[a-z][a-z0-9_]*(?:\/[a-z][a-z0-9_]*)*$/;
  for (const entry of entries) {
    const [module, out] = entry;
    if (entry.length !== 2 || !modulePath.test(module) || !modulePath.test(out)) {
      return new Error("Invalid codecs entry: expected <module>:<out> with slash-separated Gleam module paths (without src/ or .gleam).");
    }
    if (module === out) return new Error(`Codecs output ${out} cannot overwrite its types module.`);
    if (outputs.has(out)) return new Error(`More than one codecs entry writes ${out}.`);
    outputs.add(out);
  }
  return new Ok(entries);
}
