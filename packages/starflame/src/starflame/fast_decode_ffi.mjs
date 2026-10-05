import { toList } from "../gleam.mjs";
import {
  BoolKind,
  DictKind,
  FloatKind,
  IntKind,
  LazyKind,
  ListKind,
  NilKind,
  OptionKind,
  RecordKind,
  ResultKind,
  SafeIntKind,
  StringKind,
  TupleKind,
  VariantsKind,
  ZeroOrOneKind,
} from "./fast_decode.mjs";

// Each check accepts at most what the matching `gleam/dynamic/decode`
// decoder accepts. Anything unusual is left to the full decoder.
export function matches(value, kind) {
  if (kind instanceof StringKind) return typeof value === "string";
  if (kind instanceof RecordKind) return isRecord(value, kind.fields);
  if (kind instanceof IntKind) return Number.isInteger(value);
  if (kind instanceof SafeIntKind) return Number.isSafeInteger(value);
  if (kind instanceof BoolKind) return value === true || value === false;
  if (kind instanceof FloatKind) return typeof value === "number";
  if (kind instanceof ListKind) return isList(value, kind.item);
  if (kind instanceof OptionKind) {
    return value === null || value === undefined || matches(value, kind.some);
  }
  if (kind instanceof VariantsKind) return isVariant(value, kind.variants);
  if (kind instanceof ResultKind) return isResult(value, kind.ok, kind.error);
  if (kind instanceof LazyKind) return matches(value, kind.get());
  if (kind instanceof NilKind) return value === null || value === undefined;
  if (kind instanceof ZeroOrOneKind) return value === 0 || value === 1;
  if (kind instanceof TupleKind) return isTuple(value, kind.elements);
  if (kind instanceof DictKind) return isDict(value, kind.value);
  return false;
}

function isObject(value) {
  return typeof value === "object" && value !== null;
}

function isRecord(value, fields) {
  if (!isObject(value)) return false;
  for (const { name, kind, nullable } of fields) {
    // `decode.field` fails on missing fields, even optional ones.
    if (!(name in value)) return false;
    const field = value[name];
    if (field === null && nullable) continue;
    if (!matches(field, kind)) return false;
  }
  return true;
}

function isVariant(value, variants) {
  if (!isObject(value)) return false;
  const tag = value.$;
  for (const variant of variants) {
    if (variant.tag === tag) return isRecord(value, variant.fields);
  }
  return false;
}

function isResult(value, ok, error) {
  if (!isObject(value) || !("0" in value)) return false;
  if (value.$ === "Ok") return matches(value[0], ok);
  if (value.$ === "Error") return matches(value[0], error);
  return false;
}

function isList(value, item) {
  if (!Array.isArray(value)) return false;
  for (const element of value) if (!matches(element, item)) return false;
  return true;
}

function isTuple(value, elements) {
  if (!Array.isArray(value)) return false;
  let index = 0;
  for (const kind of elements) {
    if (!(index in value) || !matches(value[index], kind)) return false;
    index++;
  }
  return index === value.length;
}

function isDict(value, kind) {
  if (!isObject(value)) return false;
  const proto = Object.getPrototypeOf(value);
  if (proto !== Object.prototype && proto !== null) return false;
  for (const key of Object.keys(value)) {
    if (!matches(value[key], kind)) return false;
  }
  return true;
}

export function get(object, name) {
  return object[name];
}

export function identity(value) {
  return value;
}

export function list(array, build) {
  return toList(array.map((element) => build(element)));
}

export function is_nil(value) {
  return value === null || value === undefined;
}

export function entries(object) {
  return toList(Object.entries(object));
}
