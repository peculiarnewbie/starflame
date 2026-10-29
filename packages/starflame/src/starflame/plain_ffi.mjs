import { BitArray } from "../gleam.mjs";

export function identity(value) {
  return value;
}

export function null_() {
  return null;
}

export function array(items) {
  return items.toArray();
}

export function object(entries) {
  const result = {};
  for (const [key, value] of entries) result[key] = value;
  return result;
}

export function is_nil(value) {
  return value === null || value === undefined;
}

export function bit_array(value) {
  if (value instanceof Uint8Array) return value;
  if (value.bitSize % 8 !== 0) {
    throw new Error(
      "plain.bit_array only supports byte-aligned BitArrays (bit size must be a multiple of 8)",
    );
  }
  if (value.bitOffset === 0) return value.rawBuffer;
  // A whole number of bytes may still start partway through the first byte.
  const bytes = new Uint8Array(value.byteSize);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] =
      (value.rawBuffer[i] << value.bitOffset)
      | (value.rawBuffer[i + 1] >>> (8 - value.bitOffset));
  }
  return bytes;
}

export function is_bytes(value) {
  return value instanceof Uint8Array || value instanceof ArrayBuffer;
}

export function bytes_to_bit_array(value) {
  return new BitArray(value instanceof Uint8Array ? value : new Uint8Array(value));
}
