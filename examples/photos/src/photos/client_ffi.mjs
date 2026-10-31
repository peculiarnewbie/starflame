import { BitArray, Error, Ok } from "../gleam.mjs";

const SESSION = "photos:session";

export function session() {
  return localStorage.getItem(SESSION) ?? "";
}

export function basePath() {
  const parts = location.pathname.split("/").filter(Boolean);
  return parts[0] === "app" && parts[1] ? `/app/${parts[1]}` : "";
}

/// Reads the file input by id and resolves to Ok(#(name, type, bytes)) or
/// Error(Nil) when nothing is selected.
export function selectedFile(inputId) {
  const input = document.getElementById(inputId);
  const file = input?.files?.[0];
  if (!file) return Promise.resolve(new Error(undefined));
  return file.arrayBuffer().then((buffer) => {
    const bytes = new Uint8Array(buffer);
    return new Ok([file.name, file.type || "application/octet-stream", new BitArray(bytes)]);
  });
}
