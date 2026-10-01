import { describe, expect, test } from "bun:test";
import {
  DISAGREEMENT_GRACE_MS,
  EVIDENCE_LIMIT,
  ONSET_LOG_CAP,
  TITLE_IDLE_DEBOUNCE_MS,
  classifyTitle,
  coarseOld,
  compare,
  exited,
  initialShadow,
  nextDeadline,
  observe,
  shadowAgent,
  shadowClass,
  shadowKey,
  track,
  type ShadowEvent,
  type ShadowLine,
  type ShadowState,
} from "../src/status-shadow";
import type { WorkStatus } from "../src/protocol";

const ID = "t1";

function tracked(agent: "claude-code" | "codex" = "claude-code", at = 0): ShadowState {
  return track(initialShadow, ID, agent, at);
}
function ev(s: ShadowState, e: ShadowEvent, now: number): ShadowState {
  return observe(s, ID, e, now);
}
function title(s: ShadowState, t: string, now: number): ShadowState {
  return ev(s, { kind: "title", title: t }, now);
}
function cls(s: ShadowState, now: number) {
  return shadowClass(s.sessions.get(ID)!, now);
}
function cmp(s: ShadowState, old: WorkStatus | undefined, now: number): { state: ShadowState; lines: ShadowLine[] } {
  return compare(s, ID, old, now);
}

describe("classifyTitle", () => {
  const rows: Array<[string, string, string]> = [
    ["claude-code", "\u25D0 Fix", "spin"],
    ["claude-code", "\u280B Fix", "spin"],
    ["claude-code", "\u2733 Fix", "idle"],
    ["claude-code", "\u2733Fix", "other"],
    ["claude-code", "C:\\tools\\claude.exe", "other"],
    ["claude-code", "", "other"],
    ["codex", "\u280B proj", "spin"],
    ["codex", "\u2819 name | proj", "spin"],
    ["codex", "\u25CF \u2839 proj", "spin"],
    ["codex", "\u280B", "spin"],
    ["codex", "\u280B | proj", "idle"],
    ["codex", "name \u280B | proj", "idle"],
    ["codex", "proj", "idle"],
    ["codex", "", "idle"],
    ["codex", "[ ! ] Action Required | proj", "blocked"],
    ["codex", "[ . ] Action Required | proj", "blocked"],
  ];
  for (const [agent, t, want] of rows) {
    test(`${agent} ${JSON.stringify(t)} is ${want}`, () => {
      expect(classifyTitle(agent as "codex", t)).toBe(want as "spin");
    });
  }
});

describe("shadowKey", () => {
  const rows: Array<[string, string | undefined]> = [
    ["\x1b", "esc"],
    ["\x1b[27u", "esc"],
    ["\x03", "ctrl-c"],
    ["\r", "submit"],
    ["/compact\r", "command-submit"],
    ["/", "slash"],
    ["2", "digit"],
    ["0", undefined],
    ["ab", undefined],
    ["\x1b\r", undefined],
  ];
  for (const [input, want] of rows) {
    test(`${JSON.stringify(input)} is ${want}`, () => {
      expect(shadowKey(input)).toBe(want as undefined);
    });
  }
  test("shadowAgent admits only the measured agents", () => {
    expect(shadowAgent("claude-code")).toBe("claude-code");
    expect(shadowAgent("codex")).toBe("codex");
    expect(shadowAgent("opencode")).toBeUndefined();
    expect(shadowAgent(undefined)).toBeUndefined();
  });
});

describe("debounce", () => {
  test("working until the debounce elapses", () => {
    let s = title(tracked(), "\u25D0 x", 0);
    s = title(s, "\u2733 x", 1000);
    expect(cls(s, 1000 + TITLE_IDLE_DEBOUNCE_MS - 1)).toBe("working");
    expect(cls(s, 1000 + TITLE_IDLE_DEBOUNCE_MS)).toBe("idle");
  });
  test("a spin inside the debounce cancels the pending idle", () => {
    let s = title(tracked(), "\u25D0 x", 0);
    s = title(s, "\u2733 x", 1000);
    s = title(s, "\u25D1 x", 1800);
    expect(cls(s, 9999)).toBe("working");
    expect(nextDeadline(s)).toBeUndefined();
  });
  test("repeated same-class titles return the same state object", () => {
    const s = title(tracked(), "\u25D0 x", 0);
    expect(title(s, "\u25D1 y", 100)).toBe(s);
  });
});

describe("observability", () => {
  test("Codex idle titles before any spin log nothing", () => {
    let s = tracked("codex");
    s = title(s, "proj", 10);
    s = title(s, "", 20);
    expect(cls(s, 100_000)).toBeUndefined();
    const first = cmp(s, "working", 100_000);
    expect(first.lines).toEqual([]);
    expect(cmp(first.state, "working", 100_000 + DISAGREEMENT_GRACE_MS).lines).toEqual([]);
  });
  test("Claude idle glyph before any spin is not observable", () => {
    const s = title(tracked(), "\u2733 x", 5);
    expect(cls(s, 10)).toBeUndefined();
  });
  test("a Codex blocked title makes the session observable", () => {
    const s = title(tracked("codex"), "[ ! ] Action Required | p", 5);
    expect(cls(s, 5)).toBe("needs-you");
  });
  test("a Claude other title changes only evidence", () => {
    let s = title(tracked(), "\u25D0 x", 0);
    const before = s.sessions.get(ID)!;
    s = title(s, "C:\\claude.exe", 10);
    const after = s.sessions.get(ID)!;
    expect(cls(s, 10)).toBe("working");
    expect(after.spinning).toBe(before.spinning);
    expect(after.evidence.at(-1)!.what).toBe("title:other:43");
  });
  test("a spinner frame after a Claude other title is not a spin edge", () => {
    let s = title(tracked(), "\u25D0 x", 0);
    s = ev(s, { kind: "ask-open" }, 10);
    s = title(s, "C:\\Windows\\system32\\cmd.exe", 20);
    s = title(s, "\u25D1 x", 30);
    expect(s.sessions.get(ID)!.block).toBe("ask");
    s = title(s, "\u2733 x", 40);
    expect(cls(s, 40 + TITLE_IDLE_DEBOUNCE_MS)).toBe("needs-you");
  });
});

describe("block lifecycle", () => {
  const observable = (agent: "claude-code" | "codex" = "claude-code") => {
    let s = title(tracked(agent), "\u25D0 x", 0);
    s = title(s, agent === "codex" ? "proj" : "\u2733 x", 100);
    return s;
  };
  const idleAt = 100 + TITLE_IDLE_DEBOUNCE_MS;

  test("opens on permission_request, question and ask-open", () => {
    for (const e of [
      { kind: "notify", type: "permission_request" },
      { kind: "notify", type: "question" },
      { kind: "ask-open" },
    ] as ShadowEvent[]) {
      expect(cls(ev(observable(), e, 200), idleAt)).toBe("needs-you");
    }
  });
  test("task_complete, idle, error retire any block", () => {
    for (const type of ["task_complete", "idle", "error"] as const) {
      let s = ev(observable(), { kind: "ask-open" }, 200);
      s = ev(s, { kind: "notify", type }, 300);
      expect(cls(s, idleAt)).toBe("idle");
    }
  });
  test("awaiting_input retires a notify block but spares an ask block", () => {
    let s = ev(observable(), { kind: "notify", type: "permission_request" }, 200);
    expect(cls(ev(s, { kind: "notify", type: "awaiting_input" }, 300), idleAt)).toBe("idle");
    s = ev(observable(), { kind: "ask-open" }, 200);
    expect(cls(ev(s, { kind: "notify", type: "awaiting_input" }, 300), idleAt)).toBe("needs-you");
  });
  test("ask-open replaces a notify block, which then survives submit", () => {
    let s = ev(observable(), { kind: "notify", type: "question" }, 200);
    s = ev(s, { kind: "ask-open" }, 210);
    s = ev(s, { kind: "key", key: "submit", via: "user" }, 220);
    expect(cls(s, idleAt)).toBe("needs-you");
    s = ev(s, { kind: "ask-answered" }, 230);
    expect(cls(s, idleAt)).toBe("idle");
  });
  test("an open block keeps its first source", () => {
    let s = ev(observable(), { kind: "ask-open" }, 200);
    s = ev(s, { kind: "notify", type: "permission_request" }, 210);
    expect(s.sessions.get(ID)!.block).toBe("ask");
  });
  test("turn-end retires", () => {
    const s = ev(ev(observable(), { kind: "ask-open" }, 200), { kind: "turn-end" }, 300);
    expect(cls(s, idleAt)).toBe("idle");
  });
  test("esc and ctrl-c retire even an ask block", () => {
    for (const key of ["esc", "ctrl-c"] as const) {
      const s = ev(ev(observable(), { kind: "ask-open" }, 200), { kind: "key", key, via: "user" }, 300);
      expect(cls(s, idleAt)).toBe("idle");
    }
  });
  test("submit, command-submit and digit retire a non-ask block", () => {
    for (const key of ["submit", "command-submit", "digit"] as const) {
      const s = ev(
        ev(observable(), { kind: "notify", type: "permission_request" }, 200),
        { kind: "key", key, via: "user" },
        300,
      );
      expect(cls(s, idleAt)).toBe("idle");
    }
  });
  test("a bus submit retires a non-ask block", () => {
    const s = ev(
      ev(observable(), { kind: "notify", type: "permission_request" }, 200),
      { kind: "key", key: "submit", via: "bus" },
      300,
    );
    expect(cls(s, idleAt)).toBe("idle");
    expect(s.sessions.get(ID)!.evidence.at(-1)!.what).toBe("bus:submit");
  });
  test("slash is evidence only", () => {
    let s = ev(observable(), { kind: "notify", type: "permission_request" }, 200);
    s = ev(s, { kind: "key", key: "slash", via: "user" }, 300);
    expect(cls(s, idleAt)).toBe("needs-you");
    expect(s.sessions.get(ID)!.evidence.at(-1)!.what).toBe("key:slash");
  });
  test("a block opened while spinning survives until the next idle", () => {
    let s = title(tracked(), "\u25D0 x", 0);
    s = ev(s, { kind: "ask-open" }, 50);
    s = title(s, "\u25D1 x", 60);
    expect(cls(s, 70)).toBe("working");
    s = title(s, "\u2733 x", 100);
    expect(cls(s, 100 + TITLE_IDLE_DEBOUNCE_MS)).toBe("needs-you");
  });
  test("a spin edge retires a block", () => {
    let s = ev(observable(), { kind: "notify", type: "permission_request" }, 200);
    s = title(s, "\u25D0 x", 300);
    expect(s.sessions.get(ID)!.block).toBeUndefined();
  });
  test("a Codex blocked title skips the debounce", () => {
    let s = title(tracked("codex"), "\u280B p", 0);
    s = title(s, "[ ! ] Action Required | p", 10);
    expect(cls(s, 10)).toBe("needs-you");
    expect(nextDeadline(s)).toBeUndefined();
  });
  test("Codex blocked then idle retires a notify block", () => {
    let s = title(tracked("codex"), "\u280B p", 0);
    s = ev(s, { kind: "notify", type: "permission_request" }, 5);
    s = title(s, "[ ! ] Action Required | p", 10);
    s = title(s, "p", 20);
    expect(cls(s, 20)).toBe("idle");
  });
  test("Codex blocked then idle retires an ask block too", () => {
    let s = title(tracked("codex"), "\u280B p", 0);
    s = ev(s, { kind: "ask-open" }, 5);
    s = title(s, "[ ! ] Action Required | p", 10);
    s = title(s, "p", 20);
    expect(cls(s, 20)).toBe("idle");
  });
  test("Codex stays needs-you while its title reads Action Required, whatever retires the block", () => {
    const retirers: ShadowEvent[] = [
      { kind: "key", key: "submit", via: "user" },
      { kind: "key", key: "digit", via: "user" },
      { kind: "key", key: "esc", via: "user" },
      { kind: "key", key: "ctrl-c", via: "user" },
      { kind: "key", key: "submit", via: "bus" },
      { kind: "notify", type: "awaiting_input" },
      { kind: "notify", type: "idle" },
    ];
    for (const e of retirers) {
      let s = title(tracked("codex"), "\u280B p", 0);
      s = ev(s, { kind: "notify", type: "permission_request" }, 5);
      s = title(s, "[ ! ] Action Required | p", 10);
      expect(cls(s, 10)).toBe("needs-you");
      s = ev(s, e, 20);
      s = title(s, "[ . ] Action Required | p", 30);
      expect(cls(s, 30)).toBe("needs-you");
      s = title(s, "p", 40);
      expect(cls(s, 40)).toBe("idle");
    }
  });
  test("events on an untracked id return the same state", () => {
    expect(observe(initialShadow, "zz", { kind: "turn-end" }, 0)).toBe(initialShadow);
  });
});

describe("coarseOld", () => {
  test("maps every status", () => {
    expect(coarseOld("working")).toBe("working");
    expect(coarseOld("attention")).toBe("needs-you");
    expect(coarseOld("done")).toBe("idle");
    expect(coarseOld("unread")).toBe("idle");
    expect(coarseOld("error")).toBe("idle");
    expect(coarseOld(undefined)).toBeUndefined();
  });
});

describe("grace and logging", () => {
  const spinning = () => title(tracked("claude-code", 1000), "\u25D0 x", 1000);

  test("a disagreement just under the grace logs nothing", () => {
    const s0 = spinning();
    const a = cmp(s0, "done", 2000);
    const b = cmp(a.state, "done", 2000 + DISAGREEMENT_GRACE_MS - 1);
    expect(a.lines).toEqual([]);
    expect(b.lines).toEqual([]);
  });
  test("at the grace one onset with exact fields, then one resolution", () => {
    const a = cmp(spinning(), "done", 2000);
    const b = cmp(a.state, "done", 2000 + DISAGREEMENT_GRACE_MS);
    expect(b.lines).toHaveLength(1);
    expect(b.lines[0]!.msg).toBe("status shadow: disagreement");
    expect(b.lines[0]!.fields).toEqual({
      terminalId: ID,
      agent: "claude-code",
      old: "done",
      oldClass: "idle",
      shadow: "working",
      first: "idle/working",
      forMs: DISAGREEMENT_GRACE_MS,
      sinceTrackMs: 1000 + DISAGREEMENT_GRACE_MS,
      evidence: ["-16000ms title:spin", "-15000ms old:done"],
    });
    const again = cmp(b.state, "done", 40_000);
    expect(again.lines).toEqual([]);
    const c = cmp(again.state, "working", 50_000);
    expect(c.lines).toHaveLength(1);
    expect(c.lines[0]!.msg).toBe("status shadow: agreed again");
    expect(c.lines[0]!.fields.durationMs).toBe(48_000);
    expect(c.lines[0]!.fields.to).toBe("working");
    expect(c.lines[0]!.fields.last).toBe("idle/working");
  });
  test("agreement inside the grace emits nothing", () => {
    const a = cmp(spinning(), "done", 2000);
    const b = cmp(a.state, "working", 5000);
    const c = cmp(b.state, "done", 6000 + DISAGREEMENT_GRACE_MS);
    expect(b.lines).toEqual([]);
    expect(c.lines).toEqual([]);
  });
  test("a pair change inside one span stays one episode", () => {
    let s = spinning();
    s = cmp(s, "done", 2000).state;
    s = cmp(s, "attention", 5000).state;
    const r = cmp(s, "attention", 2000 + DISAGREEMENT_GRACE_MS);
    expect(r.lines).toHaveLength(1);
    expect(r.lines[0]!.fields.first).toBe("idle/working");
    const end = cmp(r.state, "working", 60_000);
    expect(end.lines[0]!.fields.last).toBe("needs-you/working");
  });
  test("an old status going undefined resolves as unobservable", () => {
    const a = cmp(cmp(spinning(), "done", 2000).state, "done", 2000 + DISAGREEMENT_GRACE_MS);
    const b = cmp(a.state, undefined, 40_000);
    expect(b.lines[0]!.fields.to).toBe("unobservable");
  });
  test("an unchanged comparison returns the same state object", () => {
    const a = cmp(spinning(), "working", 2000);
    const b = cmp(a.state, "working", 3000);
    expect(b.state).toBe(a.state);
  });
});

describe("scenario folds", () => {
  test("Claude permission dialog timeline logs nothing", () => {
    let s = title(tracked(), "\u25D0 x", 0);
    let old: WorkStatus = "working";
    let out: ShadowLine[] = [];
    const step = (now: number) => {
      const r = cmp(s, old, now);
      s = r.state;
      out = out.concat(r.lines);
    };
    // Compare at every deadline the shell would arm, so a grace shorter than
    // the dialog-to-notify lag logs here.
    const until = (end: number) => {
      let d: number | undefined;
      while ((d = nextDeadline(s)) !== undefined && d < end) step(d);
    };
    step(0);
    s = title(s, "\u2733 x", 1000);
    step(1000);
    until(7600);
    s = ev(s, { kind: "notify", type: "permission_request" }, 7600);
    old = "attention";
    step(7600);
    step(7600 + DISAGREEMENT_GRACE_MS + 5000);
    expect(out).toEqual([]);
  });
  test("Esc wedge: onset, then done, then a resolution", () => {
    let s = title(tracked(), "\u25D0 x", 0);
    s = title(s, "\u2733 x", 1000);
    s = ev(s, { kind: "key", key: "esc", via: "user" }, 1000);
    let r = cmp(s, "working", 2600);
    r = cmp(r.state, "working", 2600 + DISAGREEMENT_GRACE_MS);
    expect(r.lines).toHaveLength(1);
    expect(r.lines[0]!.fields.shadow).toBe("idle");
    expect((r.lines[0]!.fields.evidence as string[]).some((e) => e.endsWith("key:esc"))).toBe(true);
    const done = cmp(r.state, "done", 90_000);
    expect(done.lines[0]!.msg).toBe("status shadow: agreed again");
  });
  test("/compact: old done while the title spins past the grace", () => {
    let s = tracked("claude-code", 0);
    s = ev(s, { kind: "key", key: "slash", via: "user" }, 100);
    s = title(s, "\u25D0 x", 200);
    let r = cmp(s, "done", 300);
    r = cmp(r.state, "done", 300 + DISAGREEMENT_GRACE_MS);
    expect(r.lines).toHaveLength(1);
    expect((r.lines[0]!.fields.evidence as string[]).some((e) => e.endsWith("key:slash"))).toBe(true);
  });
});

describe("cap", () => {
  test("25 flapping episodes give 20 onsets, 20 resolutions and one summary", () => {
    let s = title(tracked("claude-code", 0), "\u25D0 x", 0);
    const lines: ShadowLine[] = [];
    let t = 1000;
    for (let i = 0; i < 25; i++) {
      let r = cmp(s, "done", t);
      r = cmp(r.state, "done", t + DISAGREEMENT_GRACE_MS);
      lines.push(...r.lines);
      r = cmp(r.state, "working", t + DISAGREEMENT_GRACE_MS + 10);
      lines.push(...r.lines);
      s = r.state;
      t += DISAGREEMENT_GRACE_MS + 100;
    }
    const onsets = lines.filter((l) => l.msg === "status shadow: disagreement");
    expect(onsets).toHaveLength(ONSET_LOG_CAP);
    expect(onsets[ONSET_LOG_CAP - 1]!.fields.capped).toBe(true);
    expect(onsets[0]!.fields.capped).toBeUndefined();
    expect(lines.filter((l) => l.msg === "status shadow: agreed again")).toHaveLength(ONSET_LOG_CAP);
    const end = exited(s, ID, t);
    expect(end.lines).toHaveLength(1);
    expect(end.lines[0]!.msg).toBe("status shadow: disagreements past grace not logged");
    expect(end.lines[0]!.fields.suppressed).toBe(5);
  });
});

describe("exited", () => {
  test("an emitted span resolves with to: exit and the session is gone", () => {
    let r = cmp(title(tracked(), "\u25D0 x", 0), "done", 100);
    r = cmp(r.state, "done", 100 + DISAGREEMENT_GRACE_MS);
    const x = exited(r.state, ID, 20_000);
    expect(x.lines).toHaveLength(1);
    expect(x.lines[0]!.fields.to).toBe("exit");
    expect(x.state.sessions.has(ID)).toBe(false);
  });
  test("an unemitted span resolves silently", () => {
    const r = cmp(title(tracked(), "\u25D0 x", 0), "done", 100);
    const x = exited(r.state, ID, 200);
    expect(x.lines).toEqual([]);
    expect(x.state.sessions.has(ID)).toBe(false);
  });
  test("an untracked id returns prev with no lines", () => {
    const x = exited(initialShadow, "nope", 0);
    expect(x.state).toBe(initialShadow);
    expect(x.lines).toEqual([]);
  });
});

describe("nextDeadline", () => {
  test("undefined at rest and never at or before now after compare", () => {
    expect(nextDeadline(initialShadow)).toBeUndefined();
    let s = title(tracked(), "\u25D0 x", 0);
    s = title(s, "\u2733 x", 100);
    expect(nextDeadline(s)).toBe(100 + TITLE_IDLE_DEBOUNCE_MS);
    let r = cmp(s, "working", 100);
    expect(nextDeadline(r.state)).toBe(100 + TITLE_IDLE_DEBOUNCE_MS);
    const now = 100 + TITLE_IDLE_DEBOUNCE_MS;
    r = cmp(r.state, "working", now);
    expect(nextDeadline(r.state)).toBe(now + DISAGREEMENT_GRACE_MS);
    r = cmp(r.state, "working", now + DISAGREEMENT_GRACE_MS);
    expect(nextDeadline(r.state)).toBeUndefined();
  });
});

describe("privacy", () => {
  test("evidence is capped and no line carries title text", () => {
    let s = tracked("codex");
    s = title(s, "\u280B secret-project-name", 0);
    for (let i = 0; i < 30; i++) s = ev(s, { kind: "key", key: "slash", via: "user" }, i);
    expect(s.sessions.get(ID)!.evidence).toHaveLength(EVIDENCE_LIMIT);
    let r = cmp(s, "done", 100);
    r = cmp(r.state, "done", 100 + DISAGREEMENT_GRACE_MS);
    expect(JSON.stringify(r.lines)).not.toContain("secret-project-name");
  });
});
