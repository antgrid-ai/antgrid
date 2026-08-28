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
    n.onStructuredTitle("a", "Structured", "self");
    n.flush();
    expect(s.calls).toEqual([["a", "Structured"]]);
  });

  test("OSC title used as filler until a structured title arrives", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onOscTitle("a", "osc filler");
    n.flush();
    n.onStructuredTitle("a", "Structured", "self");
    n.flush();
    expect(s.calls).toEqual([["a", "osc filler"], ["a", "Structured"]]);
  });

  test("sanitizes control chars, spinners, whitespace and caps length", () => {
    const s = sink();
    const n = new SessionNamer(s);
    n.onStructuredTitle("a", "\x1b[31m  Fix\t the   ⠉ bug \x07", "self");
    n.flush();
    expect(s.calls[0][1]).toBe("Fix the bug");
    const long = "x".repeat(200);
    n.onStructuredTitle("b", long, "self");
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
    n.onStructuredTitle("a", "Previous run", "self");
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

  test("a repeated first-message read does not overwrite a generated title", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onStructuredTitle("a", "check and analyze this play requirement", "first-message");
    n.flush();
    n.onStructuredTitle("a", "Audit Play Store requirement", "self");
    n.flush();
    // Every later turn re-reads the same placeholder off the transcript.
    n.onStructuredTitle("a", "check and analyze this play requirement", "first-message");
    n.flush();
    expect(s.calls).toEqual([
      ["a", "check and analyze this play requirement"],
      ["a", "Audit Play Store requirement"],
    ]);
  });

  test("a first-message title still applies while nothing better exists", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onStructuredTitle("a", "opening prompt", "first-message");
    n.flush();
    n.onStructuredTitle("a", "a longer opening prompt", "first-message");
    n.flush();
    expect(s.calls).toEqual([["a", "opening prompt"], ["a", "a longer opening prompt"]]);
  });

  test("forget clears the rank, so a restarted session can be named again", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onStructuredTitle("a", "Generated name", "self");
    n.flush();
    n.forget("a");
    n.onStructuredTitle("a", "fresh run opening prompt", "first-message");
    n.flush();
    expect(s.calls).toEqual([["a", "Generated name"], ["a", "fresh run opening prompt"]]);
  });

  test("a title that sanitizes away neither names nor latches the guard", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    // Passes a resolver's `.trim()` check but nothing survives sanitizeTitle,
    // so no name is applied — and it must not claim the `self` rank on
    // behalf of a name the user never saw.
    n.onStructuredTitle("a", "\x1b[2K⠋", "self");
    n.flush();
    n.onStructuredTitle("a", "opening prompt", "first-message");
    n.flush();
    expect(s.calls).toEqual([["a", "opening prompt"]]);
  });

  test("forgetStructuredTitle lifts the rank so a new conversation can be named", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onStructuredTitle("a", "Audit Play Store requirement", "self");
    n.flush();
    // Same PTY, new conversation (`/clear`): nothing exits, so this is the only
    // release point.
    n.forgetStructuredTitle("a");
    n.onStructuredTitle("a", "brand new opening prompt", "first-message");
    n.flush();
    expect(s.calls).toEqual([
      ["a", "Audit Play Store requirement"],
      ["a", "brand new opening prompt"],
    ]);
  });

  test("forgetStructuredTitle keeps OSC filler and renames nothing on its own", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onOscTitle("a", "osc filler");
    n.onStructuredTitle("a", "Generated name", "self");
    n.flush();
    n.forgetStructuredTitle("a");
    n.flush();
    expect(s.calls).toEqual([["a", "Generated name"]]);
    // The OSC signal survives and is used again once something marks the slot dirty.
    n.onOscTitle("a", "osc filler two");
    n.flush();
    expect(s.calls).toEqual([["a", "Generated name"], ["a", "osc filler two"]]);
  });
  test("a rename typed at the agent outranks the title we generated", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onStructuredTitle("a", "Fix session auto-naming", "self");
    n.flush();
    // Claude `/rename`, agy `/rename`: the user naming it themselves, which is
    // the one signal allowed to replace our generated name.
    n.onStructuredTitle("a", "Release blockers", "manual");
    n.flush();
    expect(s.calls).toEqual([["a", "Fix session auto-naming"], ["a", "Release blockers"]]);
  });

  test("a generated title never displaces a rename typed at the agent", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onStructuredTitle("a", "Release blockers", "manual");
    n.flush();
    // The generated name lands after the rename on a slow spawn; it loses.
    n.onStructuredTitle("a", "Fix session auto-naming", "self");
    n.flush();
    expect(s.calls).toEqual([["a", "Release blockers"]]);
  });

  test("an equal rank still updates, so a revised rename applies", () => {
    const s = sink();
    const n = new SessionNamer(s, { debounceMs: 0 });
    n.onStructuredTitle("a", "First name", "manual");
    n.flush();
    n.onStructuredTitle("a", "Second name", "manual");
    n.flush();
    expect(s.calls).toEqual([["a", "First name"], ["a", "Second name"]]);
  });
});
