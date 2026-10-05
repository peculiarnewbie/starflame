import {
  BoolKind,
  FloatKind,
  IntKind,
  SafeIntKind,
  StringKind,
  ZeroOrOneKind,
} from "./fast_decode.mjs";

export function matches(value, fields) {
  if (typeof value !== "object" || value === null) return false;
  for (const { name, kind, nullable } of fields) {
    const field = value[name];
    if (field === null) {
      if (nullable) continue;
      return false;
    }
    if (!is(kind, field)) return false;
  }
  return true;
}

function is(kind, value) {
  if (kind instanceof StringKind) return typeof value === "string";
  if (kind instanceof SafeIntKind) return Number.isSafeInteger(value);
  if (kind instanceof ZeroOrOneKind) return value === 0 || value === 1;
  if (kind instanceof IntKind) return Number.isInteger(value);
  if (kind instanceof FloatKind) return typeof value === "number";
  if (kind instanceof BoolKind) return value === true || value === false;
  return false;
}

export function get(object, name) {
  return object[name];
}

export function is_null(object, name) {
  return object[name] === null;
}
