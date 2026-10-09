import { describe, expect, test } from "bun:test";
import { hostClipboardCommands, readHostClipboard } from "./host-reader";

const commands = [{ file: "first", args: [] }, { file: "fallback", args: [] }];
describe("explicit host clipboard reads", () => {
  test("platform backends use fixed hidden commands and respect display availability", () => {
    expect(hostClipboardCommands("linux", {})).toEqual([]);
    expect(hostClipboardCommands("linux", { WAYLAND_DISPLAY: "wayland", DISPLAY: ":0" }).map((c) => c.file)).toEqual(["wl-paste", "wl-paste", "xclip", "xsel"]);
    expect(hostClipboardCommands("linux", { WAYLAND_DISPLAY: "wayland" }).map((c) => c.args.at(-1))).toEqual(["text/plain;charset=utf-8", "text/plain"]);
    expect(hostClipboardCommands("darwin")[0]?.file).toBe("/usr/bin/pbpaste");
    expect(hostClipboardCommands("win32")[0]?.args).toContain("Hidden");
    expect(hostClipboardCommands("freebsd")).toEqual([]);
  });
  test("fallbacks share one two-second budget", async () => {
    let now = 0;
    const budgets: number[] = [];
    expect(await readHostClipboard({ commands, now: () => now, run: async (_command, timeout) => {
      budgets.push(timeout);
      if (budgets.length === 1) { now = 1500; return "failed"; }
      return Buffer.from("text\n");
    } })).toEqual({ text: "text\n" });
    expect(budgets).toEqual([2000, 500]);
  });
  test("late completion and cancellation cannot return clipboard content", async () => {
    let now = 0;
    expect(await readHostClipboard({ commands, now: () => now, run: async () => { now = 2001; return Buffer.from("late"); } })).toEqual({ error: "unavailable" });
    const controller = new AbortController();
    expect(await readHostClipboard({ commands, signal: controller.signal, run: async () => { controller.abort(); return Buffer.from("cancelled"); } })).toEqual({ error: "unavailable" });
  });
  test("formats and bounds fail closed without reading a fallback clipboard", async () => {
    for (const [buffer, error] of [[Buffer.alloc(0), "empty"], [Buffer.alloc(100001), "too-large"], [Buffer.from([0xff]), "failed"], [Buffer.from("a\0b"), "failed"]] as const) {
      let calls = 0;
      expect(await readHostClipboard({ commands, run: async () => { calls++; return buffer; } })).toEqual({ error });
      expect(calls).toBe(1);
    }
    expect(await readHostClipboard({ commands: [], run: async () => { throw new Error("must not read"); } })).toEqual({ error: "unsupported" });
    expect(await readHostClipboard({ commands, run: async () => { throw new Error("sensitive helper detail"); } })).toEqual({ error: "unavailable" });
  });
  test("the real helper runner bounds output and terminates timed-out commands", async () => {
    const command = (source: string) => [{ file: process.execPath, args: ["-e", source] }];
    expect(await readHostClipboard({ commands: command('process.stdout.write("synthetic\\n")') })).toEqual({ text: "synthetic\n" });
    expect(await readHostClipboard({ commands: command('process.stdout.write("x".repeat(100001))') })).toEqual({ error: "too-large" });
    const started = performance.now();
    expect(await readHostClipboard({ commands: command("setTimeout(() => {}, 10000)") })).toEqual({ error: "unavailable" });
    expect(performance.now() - started).toBeLessThan(5000);
  }, 10000);
  test("macOS rejects rich-only formats before pbpaste and validates the same pasteboard generation afterward", async () => {
    const mac = hostClipboardCommands("darwin");
    let calls: string[] = [];
    const probe = (plainText: boolean, changeCount = 3, empty = false) => Buffer.from(JSON.stringify({ plainText, changeCount, empty }));
    expect(await readHostClipboard({ commands: mac, run: async (command) => {
      calls.push(command.file);
      return command.file === "/usr/bin/osascript" ? probe(false) : Buffer.from("{\\rtf1 rich}");
    } })).toEqual({ error: "unsupported" });
    expect(calls).toEqual(["/usr/bin/osascript"]);
    calls = [];
    let now = 0;
    const budgets: number[] = [];
    expect(await readHostClipboard({ commands: mac, now: () => now, run: async (command, remaining) => {
      calls.push(command.file); budgets.push(remaining); now += 500;
      return command.file === "/usr/bin/osascript" ? probe(true) : Buffer.from("plain\n");
    } })).toEqual({ text: "plain\n" });
    expect(calls).toEqual(["/usr/bin/osascript", "/usr/bin/pbpaste", "/usr/bin/osascript"]);
    expect(budgets).toEqual([2000, 1500, 1000]);
    let probes = 0;
    expect(await readHostClipboard({ commands: mac, run: async (command) => command.file === "/usr/bin/osascript" ? probe(true, ++probes) : Buffer.from("raced") })).toEqual({ error: "unavailable" });
    expect(await readHostClipboard({ commands: mac, run: async () => probe(false, 3, true) })).toEqual({ error: "empty" });
    for (const metadata of [Buffer.from("not json"), Buffer.from('{"plainText":true}'), "failed"] as const) {
      let reads = 0;
      expect(await readHostClipboard({ commands: mac, run: async () => { reads++; return metadata; } })).toEqual({ error: "unavailable" });
      expect(reads).toBe(1);
    }
    now = 0;
    calls = [];
    expect(await readHostClipboard({ commands: mac, now: () => now, run: async (command) => {
      calls.push(command.file); now = 2000; return probe(true);
    } })).toEqual({ error: "unavailable" });
    expect(calls).toEqual(["/usr/bin/osascript"]);
  });
});
