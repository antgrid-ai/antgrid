import { afterEach, describe, expect, test } from "bun:test";
import type { Terminal } from "@xterm/headless";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TerminalFrameSource, TerminalFrameDelivery, type TerminalFrame } from "../src/experimental/terminal-frame-source";
import { TerminalFrameHistory, readTerminalFrameHistory } from "../src/experimental/terminal-frame-history";

const sources: TerminalFrameSource[] = [];
function source(cols = 40, rows = 6): TerminalFrameSource {
  const screen = new TerminalFrameSource(cols, rows);
  sources.push(screen);
  return screen;
}
function term(screen: TerminalFrameSource): Terminal {
  return (screen as unknown as { term: Terminal }).term;
}
function uriAt(screen: TerminalFrameSource, row: number, col: number): string | undefined {
  const terminal = term(screen);
  const cell = terminal.buffer.active.getLine(terminal.buffer.active.baseY + row)?.getCell(col) as unknown as { extended?: { urlId?: number } };
  const id = cell.extended?.urlId;
  return id ? (terminal as unknown as { _core: { _oscLinkService: { getLinkData(id: number): { uri: string } } } })._core._oscLinkService.getLinkData(id)?.uri : undefined;
}
afterEach(() => { for (const screen of sources.splice(0)) screen.dispose(); });

describe("snapshot-only terminal prototype", () => {
  test("restores OSC 8 targets, wide labels, styles and cursor into a dirty viewer", async () => {
    const host = source();
    host.feed("\x1b[?1049h\x1b[2;3H\x1b]8;;https://example.com/hidden\x1b\\\x1b[1;38;2;20;100;200m界link\x1b]8;;\x1b\\\x1b[0m\x1b[5;9H");
    await host.settle();
    const frame = host.capture(0)!;
    const client = source();
    client.feed("stale\x1b[?1003h\x1b[?1006h\x1b[?7l");
    client.feed(frame.ansi);
    await client.settle();
    expect(client.visibleLines()).toEqual(host.visibleLines());
    expect(uriAt(client, 1, 2)).toBe("https://example.com/hidden");
    expect(uriAt(client, 1, 4)).toBe("https://example.com/hidden");
    expect(uriAt(client, 1, 8)).toBeUndefined();
    expect(term(client).buffer.active.cursorX).toBe(term(host).buffer.active.cursorX);
    expect(term(client).buffer.active.cursorY).toBe(term(host).buffer.active.cursorY);
    const cell = term(client).buffer.active.getLine(1)!.getCell(2)!;
    expect(cell.isBold()).toBeTruthy();
    expect(cell.getFgColor()).toBe(0x1464c8);
    expect(term(client).modes.mouseTrackingMode).toBe("none");
  });

  test("a new frame clears deleted hyperlinks without accumulating history", async () => {
    const host = source();
    const client = source();
    host.feed("\x1b]8;;https://example.com\x1b\\old link\x1b]8;;\x1b\\");
    await host.settle();
    client.feed(host.capture(0)!.ansi);
    await client.settle();
    expect(uriAt(client, 0, 0)).toBe("https://example.com");
    host.feed("\r\x1b[2Knew text");
    await host.settle();
    for (let i = 0; i < 10; i++) client.feed(host.capture(i * 50)!.ansi);
    await client.settle();
    expect(client.visibleLines()).toEqual(host.visibleLines());
    expect(uriAt(client, 0, 0)).toBeUndefined();
    expect(term(client).buffer.normal.baseY).toBe(0);
  });

  test("waits for parsed output and a synchronized redraw; times out an unclosed redraw", async () => {
    const host = source();
    host.feed("\x1b[?2026hhalf");
    expect(host.capture(0)).toBeNull();
    await host.settle();
    expect(host.capture(0)).toBeNull();
    expect(host.capture(999)).toBeNull();
    expect(host.capture(1000)?.syncTimedOut).toBe(true);
    host.feed(" done\x1b[?2026l");
    await host.settle();
    expect(host.capture(1001)?.syncTimedOut).toBe(false);
    expect(host.capture(1001)?.ansi).toContain("half done");
  });

  test("never forwards incomplete control sequences or raw titles", async () => {
    const host = source();
    host.feed("ready\x1b]8;;https://example.");
    await host.settle();
    const client = source();
    client.feed(host.capture(0)!.ansi);
    await client.settle();
    expect(client.visibleLines()[0]).toBe("ready");
    host.feed("com\x1b\\label\x1b]8;;\x1b\\\x1b]2;private-title\x07");
    await host.settle();
    const frame = host.capture(50)!;
    expect(frame.ansi).not.toContain("private-title");
    client.feed(frame.ansi);
    await client.settle();
    expect(uriAt(client, 0, 5)).toBe("https://example.com");
  });

  test("orders a resize between queued writes", async () => {
    const host = source(8, 3);
    host.feed("12345678AB");
    host.resize(12, 4);
    host.feed("CD");
    await host.settle();
    const client = source(12, 4);
    client.feed(host.capture(0)!.ansi);
    await client.settle();
    expect(client.visibleLines()).toEqual(host.visibleLines());
    expect(host.capture(0)!.cols).toBe(12);
  });

  test("tracks Kitty keyboard stacks independently and resets flags in each frame", async () => {
    const host = source();
    host.feed("\x1b[>1u\x1b[>3u\x1b[<u\x1b[?1049h\x1b[>8u\x1b[=2;2u");
    await host.settle();
    expect(host.capture(0)!.ansi).toContain("\x1b[=10;1u");
    host.feed("\x1b[?1049l"); await host.settle();
    expect(host.capture(0)!.ansi).toContain("\x1b[=1;1u");
    host.feed("\x1b[=1;3u"); await host.settle();
    expect(host.capture(0)!.ansi).toContain("\x1b[=0;1u");
    host.feed("\x1b[>31u\x1bc"); await host.settle();
    expect(host.capture(0)!.ansi).toContain("\x1b[=0;1u");
  });

  test("caps delivery, skips unchanged screens and captures latest after backpressure", async () => {
    const host = source();
    const frames: TerminalFrame[] = [];
    let release!: () => void;
    const delivery = new TerminalFrameDelivery(host, async (frame) => {
      frames.push(frame);
      if (frames.length === 1) await new Promise<void>((resolve) => { release = resolve; });
    });
    host.feed("first"); await host.settle();
    const first = delivery.tick(0);
    for (let i = 0; i < 100; i++) {
      host.feed(`\r\x1b[Kupdate ${i}`);
      await host.settle();
      expect(await delivery.tick(100 + i)).toBe(false);
    }
    expect(frames).toHaveLength(1);
    release(); await first;
    expect(await delivery.tick(200)).toBe(true);
    expect(frames[1].ansi).toContain("update 99");
    host.feed("\r\x1b[Knewest"); await host.settle();
    expect(await delivery.tick(249)).toBe(false);
    expect(await delivery.tick(250)).toBe(true);
    host.feed("\x1b]2;title only\x07"); await host.settle();
    expect(await delivery.tick(300)).toBe(false);
    expect(delivery.pending).toBe(false);
  });

  test("failed delivery retries without acknowledging the frame", async () => {
    const host = source();
    let attempts = 0;
    const delivery = new TerminalFrameDelivery(host, async () => { if (++attempts === 1) throw new Error("offline"); });
    host.feed("latest"); await host.settle();
    await expect(delivery.tick(0)).rejects.toThrow("offline");
    expect(delivery.pending).toBe(true);
    expect(await delivery.tick(50)).toBe(true);
    expect(delivery.pending).toBe(false);
  });

  test("parser overload fails explicitly instead of emitting silently corrupted state", () => {
    const host = source();
    expect(() => host.feed("x".repeat(1_000_001))).toThrow("backlog");
    expect(() => host.capture(0)).toThrow("backlog");
  });

  test("disk history retains lines skipped by every live frame, beyond the screen ring", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-frame-test-"));
    const path = join(dir, "history.jsonl");
    const history = new TerminalFrameHistory(path, 40, 6);
    try {
      const host = source();
      const data = Array.from({ length: 1200 }, (_, i) => `line ${i}\r\n`).join("");
      history.output(data); host.feed(data); await host.settle();
      expect(host.capture(0)!.ansi).not.toContain("line 0\r");
      history.resize(50, 8);
      history.output("\x1b[?1049hagent screen");
      history.close();
      const restored = await readTerminalFrameHistory(path, 2000);
      expect(restored).toContain("line 0");
      expect(restored).toContain("line 1199");
      expect(restored.join("\n")).not.toContain("agent screen");
      expect(() => new TerminalFrameHistory(path, 40, 6)).toThrow();
    } finally { history.close(); rmSync(dir, { recursive: true, force: true }); }
  });
});
