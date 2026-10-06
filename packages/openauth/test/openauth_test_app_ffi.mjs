import { Result$Ok } from "./gleam.mjs";

export async function storeCode(env, email, code) {
  await env.CODES.put(email, code);
  return Result$Ok(undefined);
}
