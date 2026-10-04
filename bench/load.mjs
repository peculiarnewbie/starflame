// The load driver, run as a child process so its CPU isn't counted as the
// server's. Virtual users are spread over worker threads; each one makes
// calls back to back and records those that start inside the window.

import { isMainThread, parentPort, Worker, workerData } from "node:worker_threads";
import { client, operations } from "./clients.mjs";

const now = () => performance.timeOrigin + performance.now();

if (isMainThread) {
  process.once("message", async (job) => {
    const threads = Math.min(job.threads, job.concurrency);
    const cpu = process.cpuUsage();
    const results = await Promise.all(
      Array.from({ length: threads }, (_, index) => {
        const users =
          Math.floor(job.concurrency / threads) + (index < job.concurrency % threads ? 1 : 0);
        return new Promise((resolve, reject) => {
          const worker = new Worker(new URL(import.meta.url), {
            workerData: { ...job, users },
          });
          worker.once("message", resolve);
          worker.once("error", reject);
        });
      }),
    );
    const used = process.cpuUsage(cpu);
    const latencies = new Float64Array(results.reduce((sum, r) => sum + r.latencies.length, 0));
    let offset = 0;
    for (const result of results) {
      latencies.set(result.latencies, offset);
      offset += result.latencies.length;
    }
    process.send({
      latencies: Array.from(latencies),
      errors: results.reduce((sum, r) => sum + r.errors, 0),
      firstError: results.find((r) => r.firstError)?.firstError,
      clientCpuMs: (used.user + used.system) / 1000,
    });
  });
} else {
  const { transport, base, details, operation, users, start, end } = workerData;
  const transportClient = client(transport, base, details);
  const latencies = [];
  let errors = 0;
  let firstError;

  await Promise.all(
    Array.from({ length: users }, async () => {
      const session = transportClient.open();
      while (now() < end) {
        const began = now();
        try {
          await transportClient.call(session, ...operations[operation]());
          if (began >= start) latencies.push(now() - began);
        } catch (error) {
          errors++;
          firstError ??= String(error?.stack ?? error);
        }
      }
      transportClient.close(session);
    }),
  );
  parentPort.postMessage({ latencies: Float64Array.from(latencies), errors, firstError });
}
