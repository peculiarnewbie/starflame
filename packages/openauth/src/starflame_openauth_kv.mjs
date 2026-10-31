import { joinKey, splitKey } from "@openauthjs/openauth/storage/storage";

// Keep OpenAuth's key encoding and JSON values. KV's cleanup deadline may be
// later than a credential's actual deadline, so enforce the latter on reads.
export function createKVStorage(namespace) {
  async function get(key) {
    const { value, metadata } = await namespace.getWithMetadata(joinKey(key), "json");
    if (value === null) return;
    if (typeof metadata?.starflameExpiresAt === "number" && metadata.starflameExpiresAt <= Date.now()) return;
    return value;
  }

  return {
    get,
    async set(key, value, expiry) {
      const name = joinKey(key);
      if (!expiry) {
        await namespace.put(name, JSON.stringify(value));
        return;
      }
      const expiresAt = expiry.getTime();
      if (!Number.isFinite(expiresAt)) throw new TypeError("Invalid OpenAuth storage expiry");
      const remaining = expiresAt - Date.now();
      if (remaining <= 0) {
        await namespace.delete(name);
        return;
      }
      await namespace.put(name, JSON.stringify(value), {
        expirationTtl: Math.max(60, Math.ceil(remaining / 1000)),
        metadata: { starflameExpiresAt: expiresAt },
      });
    },
    async remove(key) {
      await namespace.delete(joinKey(key));
    },
    async* scan(prefix) {
      let cursor;
      while (true) {
        const page = await namespace.list({ prefix: joinKey([...prefix, ""]), cursor });
        for (const { name } of page.keys) {
          const key = splitKey(name);
          const value = await get(key);
          if (value !== undefined) yield [key, value];
        }
        if (page.list_complete) break;
        cursor = page.cursor;
      }
    },
  };
}
