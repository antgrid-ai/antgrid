import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { TerminalFrameSchema } from "../src/experimental/terminal-frame-source";
import { readTerminalFrameHistory } from "../src/experimental/terminal-frame-history";

const dir = mkdtempSync(join(tmpdir(), "antgrid-frame-smoke-"));
for (const delay of [0, 150]) {
  const recording = join(dir, `history-${delay}.jsonl`);
  const child = Bun.spawn([process.execPath, join(import.meta.dir, "terminal-frame-prototype.ts"),
    "--demo", "--json", "--record", recording, "--delay-ms", String(delay)], {
    stdout: "pipe", stderr: "pipe", stdin: "ignore",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  assert.equal(code, 0, stderr);
  const frames = stdout.trim().split("\n").map((line) => TerminalFrameSchema.parse(JSON.parse(line)));
  assert.ok(frames.length > 1);
  assert.ok(frames.at(-1)!.ansi.includes("Complete"));
  assert.ok(frames.at(-1)!.ansi.includes("https://example.com/report"));
  const history = await readTerminalFrameHistory(recording, 2000);
  assert.ok(history.includes("history row 0"));
  assert.ok(history.includes("history row 999"));
  const stats = JSON.parse(stderr.trim().split("\n").at(-1)!);
  assert.ok(stats.frames <= Math.floor(stats.elapsedMs / 50) + 1);
  console.log(JSON.stringify({ viewerDelayMs: delay, ...stats, historyRows: history.length }));
}
