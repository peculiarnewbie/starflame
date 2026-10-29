import { Error, Ok } from "../gleam.mjs";
import { env } from "./server.mjs";

export function bucket(context, binding) {
  const value = env(context)[binding];
  if (!value) throw new globalThis.Error(`No R2 binding named ${binding}`);
  return value;
}

export function put(bucket, key, body, contentType) {
  return attempt(async () => {
    await bucket.put(key, bytes(body), {
      httpMetadata: { contentType: contentType },
    });
    return undefined;
  });
}

// Resolves to Ok(null) when the key is missing, so Gleam can decode it as an
// Option without the FFI constructing Gleam's Option classes.
export function get(bucket, key) {
  return attempt(async () => {
    const object = await bucket.get(key);
    if (!object) return null;
    const buffer = await object.arrayBuffer();
    return {
      body: new Uint8Array(buffer),
      content_type: object.httpMetadata?.contentType ?? "",
      size: object.size,
    };
  });
}

export function delete_(bucket, key) {
  return attempt(async () => {
    await bucket.delete(key);
    return undefined;
  });
}

// An R2 binding rejects with a plain Error; keep the message.
async function attempt(run) {
  try {
    return new Ok(await run());
  } catch (error) {
    const message = String(error?.message ?? error);
    return new Error(message);
  }
}

function bytes(bits) {
  if (bits.bitOffset !== 0 || bits.bitSize % 8 !== 0) {
    throw new globalThis.Error("R2 bodies must be byte-aligned");
  }
  const view = new Uint8Array(bits.byteSize);
  for (let i = 0; i < bits.byteSize; i++) view[i] = bits.byteAt(i);
  return view;
}

export function describe_value(value) {
  try {
    return JSON.stringify(value, (_, v) =>
      v instanceof Uint8Array ? `<Uint8Array ${v.length}>` : v,
    );
  } catch {
    return String(value);
  }
}
