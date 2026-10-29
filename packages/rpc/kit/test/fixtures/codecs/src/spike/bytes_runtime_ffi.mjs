import { toList, BitArray } from "../gleam.mjs";

export function byte_inputs() {
  const bytes = new Uint8Array([0, 127, 128, 255]);
  const view = new Uint8Array([99, ...bytes, 99]).subarray(1, 5);
  return toList([bytes, bytes.buffer, view]);
}

export function non_bytes() {
  return toList([
    null, undefined, "bytes", 42, false, [], {},
    new Uint16Array([1]), new DataView(new ArrayBuffer(4)),
    new BitArray(new Uint8Array([1])),
  ]);
}

export function upload(bytes) {
  return { bytes, chunks: [bytes], metadata: [bytes, "bytes"] };
}

export function encoding_rejected(encode) {
  try {
    encode();
    return false;
  } catch (error) {
    return error.message.includes("byte-aligned BitArrays");
  }
}
