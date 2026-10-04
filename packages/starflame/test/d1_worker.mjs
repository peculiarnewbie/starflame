import { main } from "../build/dev/javascript/starflame/d1_cases.mjs";

export default {
  async fetch(_request, env, ctx) {
    const checks = (await main(env, ctx))
      .toArray()
      .map(({ name, detail }) => ({ name, pass: detail === undefined, detail }));
    return Response.json(checks);
  },
};
