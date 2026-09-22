import { expect, test } from "bun:test";
import { fileURLToPath } from "node:url";

test("native host resume restores Dart E2E and both project bindings on the shared endpoint", async () => {
  const script = fileURLToPath(new URL("../../bridge/scripts/iroh-interop-smoke.ts", import.meta.url));
  const child = Bun.spawn([process.execPath, script], { stdout: "pipe", stderr: "pipe", env: process.env });
  try {
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
    ]);
    expect(code, stderr).toBe(0);
    const result = stdout.split("\n").filter((line) => line.startsWith("{"))
      .map((line) => JSON.parse(line)).find((value) => value.gate === "cross-binding");
    expect(result?.resumeCycles).toBe(3);
    expect(result?.projects).toBe(2);
    expect(result?.centralOutage).toBe(true);
    console.log(JSON.stringify(result));
  } finally { child.kill(); }
}, 130_000);
