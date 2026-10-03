import { describe, expect, test } from "bun:test";
import { TerminalSession } from "../src/terminal-session";
import type { AbMessage } from "../src/protocol";

function run(opts: { suppressOscTitle?: boolean; osc: string }, setup: (s: TerminalSession) => void): Promise<void> {
  const session = new TerminalSession({
    terminalId: "tap1",
    name: "tap1",
    command: process.execPath,
    args: ["-e", `process.stdout.write(${JSON.stringify(opts.osc)}); setTimeout(() => {}, 300)`],
    cols: 80,
    rows: 24,
    suppressOscTitle: opts.suppressOscTitle,
    onTitle: undefined,
    onMessage: () => {},
  });
  setup(session);
  return new Promise<void>((resolve) => {
    const orig = (session as unknown as { onMessage: (m: AbMessage) => void }).onMessage;
    (session as unknown as { onMessage: (m: AbMessage) => void }).onMessage = (msg: AbMessage) => {
      orig(msg);
      if (msg.type === "terminal:exited") resolve();
    };
    session.spawn();
  });
}

describe("title tap", () => {
  test("sees titles the hook-owned suppression keeps from onTitle", async () => {
    const seen: string[] = [];
    const routed: string[] = [];
    const session = { routed };
    await run({ suppressOscTitle: true, osc: "\x1b]0;◐ x\x07" }, (s) => {
      (s as unknown as { onTitle: (t: string) => void }).onTitle = (t) => session.routed.push(t);
      s.onTitleObserved((t) => seen.push(t));
    });
    expect(seen.some((t) => t.includes("◐ x"))).toBe(true);
    expect(routed).toEqual([]);
  });

  test("a throwing observer does not stop onTitle", async () => {
    const routed: string[] = [];
    await run({ osc: "\x1b]0;◐ x\x07" }, (s) => {
      (s as unknown as { onTitle: (t: string) => void }).onTitle = (t) => routed.push(t);
      s.onTitleObserved(() => {
        throw new Error("observer");
      });
    });
    expect(routed.some((t) => t.includes("◐ x"))).toBe(true);
  });

  // ConPTY rewrites console titles, so an empty OSC 0 never arrives verbatim there.
  test.skipIf(process.platform === "win32")("an empty title reaches the observer and not onTitle", async () => {
    const seen: string[] = [];
    const routed: string[] = [];
    await run({ osc: "\x1b]0;\x07" }, (s) => {
      (s as unknown as { onTitle: (t: string) => void }).onTitle = (t) => routed.push(t);
      s.onTitleObserved((t) => seen.push(t));
    });
    expect(seen).toContain("");
    expect(routed).toEqual([]);
  });
});
