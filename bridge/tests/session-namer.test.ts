import { describe, expect, test } from "bun:test";
import { SessionNamer } from "../src/session-namer";

function sink() {
  const calls: Array<[string, string]> = [];
  return { calls, applyAutoName: (id: string, name: string) => calls.push([id, name]) };
}

describe("SessionNamer", () => {
  test("applies an OSC title on flush", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onOscTitle("a", "Hello world");
    n.flush();
    expect(s.calls).toEqual([["a", "Hello world"]]);
  });

  test("structured title wins over OSC title regardless of order", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onOscTitle("a", "osc filler");
    n.onStructuredTitle("a", "Structured");
    n.flush();
    expect(s.calls).toEqual([["a", "Structured"]]);
  });

  test("OSC title used as filler until a structured title arrives", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onOscTitle("a", "osc filler");
    n.flush();
    n.onStructuredTitle("a", "Structured");
    n.flush();
    expect(s.calls).toEqual([["a", "osc filler"], ["a", "Structured"]]);
  });

  test("sanitizes control chars, spinners, whitespace and caps length", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onStructuredTitle("a", "\x1b[31m  Fix\t the   ⠉ bug \x07");
    n.flush();
    expect(s.calls[0][1]).toBe("Fix the bug");
    const long = "x".repeat(200);
    n.onStructuredTitle("b", long);
    n.flush();
    expect(s.calls[1][1].length).toBe(60);
  });

  test("empty-after-sanitize is not applied", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onOscTitle("a", "   \x07  ");
    n.flush();
    expect(s.calls).toEqual([]);
  });

  test("debounce coalesces rapid changes to the latest", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onOscTitle("a", "one");
    n.onOscTitle("a", "two");
    n.onOscTitle("a", "three");
    n.flush();
    expect(s.calls).toEqual([["a", "three"]]);
  });

  test("forget drops a session's buffered state so a stale title can't reapply", () => {
    const s = sink();
    const n = new SessionNamer(s);
    // A previous run set a structured title (which wins precedence).
    n.onStructuredTitle("a", "Previous run");
    n.forget("a");
    // The restarted same-id session emits only an OSC title; without forget the
    // stale structured title would still win on flush.
    n.onOscTitle("a", "Fresh run");
    n.flush();
    expect(s.calls).toEqual([["a", "Fresh run"]]);
  });

  test("forget discards a pending name without flushing it", async () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 5 });
    n.onOscTitle("a", "pending");
    n.forget("a");
    await new Promise((r) => setTimeout(r, 20));
    expect(s.calls).toEqual([]);
  });

  test("dispose cancels the pending debounce timer", async () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 5 });
    n.onOscTitle("a", "pending");
    n.dispose();
    await new Promise((r) => setTimeout(r, 20));
    expect(s.calls).toEqual([]);
  });
});
