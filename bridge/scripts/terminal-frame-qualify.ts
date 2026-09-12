import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { parseArgs } from "node:util";

const root = resolve(import.meta.dir, "../..");
const { values } = parseArgs({
  args: process.argv.slice(2),
  options: { phase: { type: "string", default: "all" }, output: { type: "string" } },
});
const phase = values.phase!;
if (!["all", "native", "e2e", "performance"].includes(phase)) {
  throw new Error("--phase must be all, native, e2e, or performance");
}
const output = resolve(values.output ?? resolve(root, ".tmp/terminal-frame-qualification"));
mkdirSync(output, { recursive: true });

async function run(command: string[], cwd: string, report?: string): Promise<void> {
  console.error(`qualification: ${command.join(" ")}`);
  const child = Bun.spawn(command, {
    cwd, stdout: report ? "pipe" : "inherit", stderr: "inherit", stdin: "ignore",
  });
  const captured = report ? new Response(child.stdout as ReadableStream).text() : Promise.resolve("");
  const [code, text] = await Promise.all([child.exited, captured]);
  if (report) await Bun.write(resolve(output, report), text);
  if (code !== 0) throw new Error(`${command.join(" ")} failed (${code})`);
}

if (phase === "all" || phase === "native") {
  const flutter = Bun.which("flutter");
  if (!flutter) throw new Error("Flutter is required for native terminal qualification");
  const command = process.platform === "win32"
    ? ["cmd.exe", "/d", "/c", flutter]
    : [flutter];
  await run([...command, "test", "-j", "2", "test/terminal_frame_prototype_test.dart"], resolve(root, "app"));
}
if (phase === "all" || phase === "e2e") {
  await run([process.execPath, "run", "--filter", "antgrid-evals", "test:evals:terminal-frames"], root);
}
if (phase === "all" || phase === "performance") {
  for (const ackDelay of [0, 50, 100, 250]) {
    for (const bandwidth of [0, 256 * 1024]) {
      await run([
        process.execPath, "run", "scripts/terminal-frame-bench.ts", "--json",
        `--ack-delay-ms=${ackDelay}`, `--bandwidth-bytes-sec=${bandwidth}`,
      ], resolve(root, "bridge"), `ack-${ackDelay}-bandwidth-${bandwidth}.json`);
    }
  }
}
console.error("Automated terminal qualification completed. Real-agent host checks and input-to-paint measurements remain a separate release requirement.");
