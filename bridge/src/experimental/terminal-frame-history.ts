import { openSync, writeSync, closeSync, createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { z } from "zod";
import { TerminalFrameSource } from "./terminal-frame-source";

const geometry = { cols: z.number().int().min(1).max(1000), rows: z.number().int().min(1).max(500) };
export const TerminalHistoryRecordSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("start"), version: z.literal(1), ...geometry }),
  z.object({ type: z.literal("output"), data: z.string().max(1_000_000) }),
  z.object({ type: z.literal("resize"), ...geometry }),
]);
type HistoryRecord = z.infer<typeof TerminalHistoryRecordSchema>;

/** Local recording, never part of the frame payload or a network endpoint. */
export class TerminalFrameHistory {
  private fd: number | undefined;
  constructor(path: string, cols: number, rows: number) {
    const start = TerminalHistoryRecordSchema.parse({ type: "start", version: 1, cols, rows });
    this.fd = openSync(path, "wx", 0o600);
    try { this.append(start); }
    catch (error) { this.close(); throw error; }
  }

  output(data: string): void {
    // Bound an individual record without cutting a UTF-16 surrogate pair.
    for (let start = 0; start < data.length;) {
      let end = Math.min(data.length, start + 64_000);
      const last = data.charCodeAt(end - 1);
      if (end < data.length && last >= 0xd800 && last <= 0xdbff) end--;
      this.append({ type: "output", data: data.slice(start, end) });
      start = end;
    }
  }

  resize(cols: number, rows: number): void {
    this.append(TerminalHistoryRecordSchema.parse({ type: "resize", cols, rows }));
  }

  private append(record: HistoryRecord): void {
    if (this.fd === undefined) throw new Error("Terminal history is closed");
    const bytes = Buffer.from(JSON.stringify(record) + "\n");
    // Synchronous disk writes bound memory independently of a stalled viewer.
    // This prototype deliberately measures their cost rather than hiding it
    // behind an unbounded queue. Partial writes still owe the remaining bytes.
    for (let offset = 0; offset < bytes.length;) {
      const written = writeSync(this.fd, bytes, offset, bytes.length - offset);
      if (!written) throw new Error("Terminal history write made no progress");
      offset += written;
    }
  }

  close(): void {
    if (this.fd !== undefined) closeSync(this.fd);
    this.fd = undefined;
  }
}

/** Replay from the beginning: an arbitrary suffix of PTY bytes is not a screen. */
export async function readTerminalFrameHistory(path: string, limit = 10_000): Promise<string[]> {
  z.number().int().min(1).max(10_000).parse(limit);
  const input = createReadStream(path, { encoding: "utf8" });
  const lines = createInterface({ input, crlfDelay: Infinity });
  let screen: TerminalFrameSource | undefined;
  try {
    for await (const line of lines) {
      const record = TerminalHistoryRecordSchema.parse(JSON.parse(line));
      if (record.type === "start") {
        if (screen) throw new Error("Duplicate terminal history header");
        screen = new TerminalFrameSource(record.cols, record.rows);
        screen.setHistoryLimit(limit);
      } else {
        if (!screen) throw new Error("Missing terminal history header");
        if (record.type === "resize") screen.resize(record.cols, record.rows);
        else screen.feed(record.data);
        await screen.settle();
      }
    }
    if (!screen) throw new Error("Empty terminal history");
    return screen.normalHistoryLines().slice(-limit);
  } finally {
    lines.close();
    input.destroy();
    screen?.dispose();
  }
}
