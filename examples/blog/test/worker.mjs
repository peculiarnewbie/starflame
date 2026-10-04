import { main } from "../build/dev/javascript/blog/blog_cases.mjs";

export default {
  async fetch(_request, env, execution) {
    const checks = (await main(env, execution)).toArray();
    return Response.json(checks);
  },
};
