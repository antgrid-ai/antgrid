import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const cases = ["terminal", "bad-agent-key", "bad-app-key", "oversize-record", "wrong-destination", "extra-stream", "disconnect",
  "client-oversize-record", "client-wrong-destination", "client-extra-stream"];
const results: Array<{ testCase: string; exitCode: number; output: string }> = [];
for (const testCase of cases) {
  const child = Bun.spawn([Bun.which("bun") ?? "bun", "run", "prototype.ts"], {
    cwd: import.meta.dir,
    env: { ...Bun.env, IROH_QUALIFICATION_CASE: testCase, IROH_QUALIFICATION_COMPILED: "0" },
    stdout: "pipe", stderr: "inherit",
  });
  const output = await new Response(child.stdout).text();
  const exitCode = await child.exited;
  const result = { testCase, exitCode, output: output.trim() };
  results.push(result);
  console.log(JSON.stringify(result));
  if (exitCode !== 0) break;
}
const outputDir = resolve(import.meta.dir, "../../.tmp/iroh-qualification");
await mkdir(outputDir, { recursive: true });
await writeFile(resolve(outputDir, "prototype-results.json"), JSON.stringify({
  recordedAt: new Date().toISOString(), platform: process.platform, arch: process.arch,
  bun: Bun.version, profile: "loopback-no-relay", results,
}, null, 2) + "\n");
if (results.length !== cases.length || results.some((r) => r.exitCode !== 0)) process.exitCode = 1;
