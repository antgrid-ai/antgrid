import { parseArgs } from "node:util";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { z } from "zod";
import { setLogLevel } from "../src/logger";
import { TerminalSession } from "../src/terminal-session";
import { TerminalModeTracker } from "../src/terminal-modes";
import { TerminalFrameSource, TerminalFrameDelivery, FRAME_INTERVAL_MS } from "../src/experimental/terminal-frame-source";
import { TerminalFrameHistory, readTerminalFrameHistory } from "../src/experimental/terminal-frame-history";

const rawArgs = process.argv.slice(2);
const separator = rawArgs.indexOf("--");
const { values } = parseArgs({
  args: separator < 0 ? rawArgs : rawArgs.slice(0, separator),
  options: {
    demo: { type: "boolean" }, json: { type: "boolean" }, help: { type: "boolean" },
    record: { type: "string" }, history: { type: "string" },
    cols: { type: "string" }, rows: { type: "string" }, "delay-ms": { type: "string" },
    lines: { type: "string" },
  },
});
if (values.help) {
  console.log("terminal-frame-prototype [--demo | -- command args...] [--record NEW_FILE] [--json] [--delay-ms N]\nterminal-frame-prototype --history FILE [--lines N]");
  process.exit(0);
}
const opts = z.object({
  cols: z.coerce.number().int().min(1).max(1000),
  rows: z.coerce.number().int().min(1).max(500),
  delay: z.coerce.number().int().min(0).max(10_000),
  lines: z.coerce.number().int().min(1).max(10_000),
}).parse({ cols: values.cols ?? process.stdout.columns ?? 120,
  rows: values.rows ?? process.stdout.rows ?? 40, delay: values["delay-ms"] ?? 0, lines: values.lines ?? 10_000 });

setLogLevel("fatal");
async function writeOutput(text: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    process.stdout.write(text, (error) => error ? reject(error) : resolve());
  });
}

if (values.history) {
  await writeOutput((await readTerminalFrameHistory(values.history, opts.lines)).join("\n") + "\n");
} else {
  const commandArgs = separator < 0 ? [] : rawArgs.slice(separator + 1);
  if (!values.demo && !commandArgs.length) throw new Error("Use --demo or -- command args...");
  if (values.demo && commandArgs.length) throw new Error("Choose --demo or a command");
  const recording = values.record ?? join(mkdtempSync(join(tmpdir(), "antgrid-terminal-frames-")), "history.jsonl");
  const history = new TerminalFrameHistory(recording, opts.cols, opts.rows);
  const source = new TerminalFrameSource(opts.cols, opts.rows);
  const json = values.json || !process.stdout.isTTY;
  let rawBytes = 0;
  let frameBytes = 0;
  let frames = 0;
  let syncTimeouts = 0;
  let failure: unknown;
  let exited = false;
  let stopping = false;
  let tickTask: Promise<void> | undefined;
  const started = performance.now();
  const delivery = new TerminalFrameDelivery(source, async (frame) => {
    if (opts.delay) await Bun.sleep(opts.delay);
    const output = json ? JSON.stringify(frame) + "\n" : frame.ansi;
    await writeOutput(output);
    frameBytes += Buffer.byteLength(output);
    frames++;
    if (frame.syncTimedOut) syncTimeouts++;
  });
  const session = new TerminalSession({
    terminalId: "frame-prototype", cols: opts.cols, rows: opts.rows,
    command: values.demo ? process.execPath : commandArgs[0],
    args: values.demo ? [join(import.meta.dir, "terminal-frame-demo.ts")] : commandArgs.slice(1),
    // The prototype cannot advertise Ghostty's extended VT feature set.
    env: { TERM_PROGRAM: "xterm.js", TERM_PROGRAM_VERSION: "6.0.0" },
    onMessage(msg) {
      if (msg.type === "terminal:output") {
        try {
          rawBytes += Buffer.byteLength(msg.data);
          history.output(msg.data);
          source.feed(msg.data);
        } catch (error) { failure = error; }
      } else if (msg.type === "terminal:exited") exited = true;
    },
  });
  const inputDecoder = new StringDecoder("utf8");
  const input = (data: Buffer) => session.write(inputDecoder.write(data));
  const resize = () => {
    const cols = Math.min(1000, process.stdout.columns || opts.cols);
    const rows = Math.min(500, process.stdout.rows || opts.rows);
    try {
      history.resize(cols, rows);
      source.resize(cols, rows);
      session.resize("prototype", cols, rows);
    } catch (error) { failure = error; }
  };
  const stop = () => { stopping = true; };
  const interactive = process.stdin.isTTY && !json;
  console.error(`History recording: ${recording}`);
  try {
    session.spawn();
    if (interactive) {
      process.stdin.setRawMode(true);
      process.stdin.on("data", input);
      process.stdout.on("resize", resize);
    }
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    while ((!exited || delivery.pending) && !failure && !stopping) {
      // Do not await a slow viewer here: PTY parsing and recording keep running.
      tickTask ??= delivery.tick(performance.now()).then(() => {}, (error) => {
        failure = error;
      }).finally(() => { tickTask = undefined; });
      await Bun.sleep(FRAME_INTERVAL_MS);
    }
    if (failure) throw failure;
  } finally {
    if (interactive) {
      process.stdin.off("data", input);
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdout.off("resize", resize);
    }
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
    await session.close(0);
    await tickTask;
    source.dispose();
    history.close();
    if (!json) {
      const resetModes = new TerminalModeTracker();
      resetModes.feed("\x1bc");
      await writeOutput("\x1b[?2026l\x1b]8;;\x1b\\\x1b[=0;1u\x1b[?1049l\x1b[=0;1u"
        + resetModes.supplementalPrelude()
        + "\x1b[?6l\x1b[r\x1b[4l\x1b[?7h\x1b[?45l\x1b[?66l\x1b[?9l\x1b[0m\r\n");
    }
    console.error(JSON.stringify({ frames, rawBytes, frameBytes, syncTimeouts,
      elapsedMs: Math.round(performance.now() - started), recording }));
  }
}
