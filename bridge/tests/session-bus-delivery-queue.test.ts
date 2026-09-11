// Turn-boundary delivery (`docs/session-messaging.md` §7.2). Two guarantees are
// load-bearing and both fail silently if broken: a line never lands mid-turn,
// and a line never vanishes — the sending machine is told a message left the
// moment it does, so a line dropped here is one nothing on either side can
// notice is missing.
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DeliveryKindSchema,
  MAX_QUEUED_LINES,
  SessionBusDeliveryQueue,
  closedTurns,
  emptyDeliveries,
  enqueueLine,
  forgetSession,
  linesFor,
  loadDeliveries,
  removeLine,
  saveDeliveries,
  type QueuedLine,
} from "../src/session-bus/delivery-queue";
import { UNATTRIBUTED_TURN, turnOpenFor } from "../src/work-status";

const dirs: string[] = [];
function tempDir(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "bus-queue-")));
  dirs.push(dir);
  return dir;
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

const PROJECT = "p1";
const SESSION = "s1";

function line(over: Partial<QueuedLine> = {}): Omit<QueuedLine, "queuedAt"> {
  return { id: "l-1", sessionId: SESSION, kind: "notify", text: "a line", ...over };
}

/** The queue plus the two things `ProjectCore` supplies it: the turn-open set
 *  from the work-status reduction, and a submit that reports whether the line
 *  actually went into a session. */
function harness(abDir: string, opts: { live?: boolean } = {}) {
  const openTurns = new Set<string>();
  const injected: QueuedLine[] = [];
  let live = opts.live !== false;
  const queue = new SessionBusDeliveryQueue({
    abDir,
    projectId: PROJECT,
    // The predicate ProjectCore hands the real queue, not a re-reading of the
    // same set: the unattributed key is what makes the two differ.
    isTurnOpen: (id) => turnOpenFor(openTurns, id),
    inject: (l) => {
      if (!live) return false;
      injected.push(l);
      return true;
    },
    now: () => 1_000,
  });
  return {
    queue,
    injected,
    openTurns,
    setLive(v: boolean) { live = v; },
  };
}

describe("the delivery queue folds", () => {
  test("a duplicate id is not queued twice", () => {
    const one = enqueueLine(emptyDeliveries(), { ...line(), queuedAt: 1 });
    const again = enqueueLine(one, { ...line(), queuedAt: 2 });
    expect(again).toBe(one);
    expect(again.lines).toHaveLength(1);
  });

  test("past the cap the oldest goes, whichever kind is holding the head", () => {
    let s = emptyDeliveries();
    s = enqueueLine(s, { ...line({ id: "oldest", kind: "reply" }), queuedAt: 0 });
    for (let i = 0; i < MAX_QUEUED_LINES; i += 1) {
      s = enqueueLine(s, { ...line({ id: `n-${i}`, kind: "notify" }), queuedAt: i + 1 });
    }
    expect(s.lines).toHaveLength(MAX_QUEUED_LINES);
    // Both surviving kinds are conversation and both are allowed to be lost, so
    // nothing at the head is protected: the cap is plain oldest-first. Nothing
    // re-sends what this queue accepted — the sending machine was told the
    // message left as soon as it did — so the loss is real either way.
    expect(s.lines.map((l) => l.id)).not.toContain("oldest");
    expect(s.lines[0]!.id).toBe("n-0");
  });

  test("no kind is exempt from eviction, so the cap can never drop a line out of order", () => {
    // The trap: a kind added to the enum but left out of EVICTABLE_KINDS is
    // treated as load-bearing, and the eviction then falls back to dropping
    // index 0 outright — a line that may belong to a different session
    // altogether. The enum forces a type edit; the Set does not, so this is what
    // holds the two in lockstep.
    for (const kind of DeliveryKindSchema.options) {
      let s = emptyDeliveries();
      s = enqueueLine(s, { ...line({ id: "head", kind }), queuedAt: 0 });
      for (let i = 0; i < MAX_QUEUED_LINES; i += 1) {
        s = enqueueLine(s, { ...line({ id: `n-${i}`, kind: "notify" }), queuedAt: i + 1 });
      }
      expect(s.lines).toHaveLength(MAX_QUEUED_LINES);
      expect(s.lines.map((l) => l.id), `a ${kind} line at the head outlived the cap`).not.toContain("head");
    }
  });

  test("lines are read and removed per session", () => {
    let s = emptyDeliveries();
    s = enqueueLine(s, { ...line({ id: "a", sessionId: "s1" }), queuedAt: 1 });
    s = enqueueLine(s, { ...line({ id: "b", sessionId: "s2" }), queuedAt: 2 });
    expect(linesFor(s, "s1").map((l) => l.id)).toEqual(["a"]);
    expect(removeLine(s, "a").lines.map((l) => l.id)).toEqual(["b"]);
    expect(forgetSession(s, "s2").lines.map((l) => l.id)).toEqual(["a"]);
    // An unchanged fold returns the same object, so a caller can skip the write.
    expect(removeLine(s, "nope")).toBe(s);
  });

  test("closedTurns names only the sessions whose turn ended", () => {
    const prev = { activeTurns: new Set(["a", "b"]) };
    const next = { activeTurns: new Set(["b", "c"]) };
    expect(closedTurns(prev, next)).toEqual(["a"]);
  });

  test("the unattributed key survives the diff, because it is a boundary for every session", () => {
    // An agent that cannot attribute its turn-starts records them under the
    // empty-string key, and a falsy-filter here would drop the only edge those
    // agents ever produce. `ProjectCore.commitWork` turns it into a drainAll.
    const prev = { activeTurns: new Set([UNATTRIBUTED_TURN]) };
    const next = { activeTurns: new Set<string>() };
    expect(closedTurns(prev, next)).toEqual([UNATTRIBUTED_TURN]);
  });
});

describe("turn-boundary delivery", () => {
  test("a line queued while a turn is open waits, and goes in exactly once when it closes", () => {
    const h = harness(tempDir());
    h.openTurns.add(SESSION);
    h.queue.queue(line());
    expect(h.injected).toHaveLength(0);
    expect(h.queue.lines).toHaveLength(1);

    // The closing edge is what `ProjectCore.commitWork` drains on.
    h.openTurns.delete(SESSION);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["l-1"]);
    expect(h.queue.lines).toHaveLength(0);

    // Every later boundary must be a no-op: a second copy of a wake reads as a
    // second completion.
    h.queue.drain(SESSION);
    h.queue.drainAll();
    expect(h.injected).toHaveLength(1);
  });

  test("a line waits while an UNATTRIBUTED turn is open, and the project-wide close releases it", () => {
    const h = harness(tempDir());
    // The agent is mid-turn; it just cannot say in which session. Delivering
    // here is the mid-turn arrival the queue exists to prevent.
    h.openTurns.add(UNATTRIBUTED_TURN);
    h.queue.queue(line());
    expect(h.injected).toHaveLength(0);

    h.openTurns.delete(UNATTRIBUTED_TURN);
    h.queue.drainAll();
    expect(h.injected.map((l) => l.id)).toEqual(["l-1"]);
  });

  test("an idle session is delivered to at once", () => {
    const h = harness(tempDir());
    h.queue.queue(line());
    expect(h.injected.map((l) => l.id)).toEqual(["l-1"]);
    expect(h.queue.lines).toHaveLength(0);
  });

  test("a line for a session with no live agent stays queued at the head", () => {
    const h = harness(tempDir(), { live: false });
    h.queue.queue(line({ id: "first" }));
    h.queue.queue(line({ id: "second" }));
    expect(h.injected).toHaveLength(0);
    expect(h.queue.lines.map((l) => l.id)).toEqual(["first", "second"]);

    // Order is kept rather than skipped ahead: delivering the second first would
    // hand the agent a result for work it was never told about. One per
    // boundary, because the line just delivered opened a turn this bridge only
    // hears about a round trip later.
    h.setLive(true);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["first"]);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["first", "second"]);
  });

  test("a submit that throws leaves the line queued rather than losing it", () => {
    const abDir = tempDir();
    const injected: QueuedLine[] = [];
    let throwing = true;
    const queue = new SessionBusDeliveryQueue({
      abDir,
      projectId: PROJECT,
      isTurnOpen: () => false,
      inject: (l) => {
        if (throwing) throw new Error("the adapter is gone");
        injected.push(l);
        return true;
      },
    });
    queue.queue(line());
    expect(queue.lines).toHaveLength(1);
    throwing = false;
    queue.drain(SESSION);
    expect(injected).toHaveLength(1);
    expect(queue.lines).toHaveLength(0);
  });

  test("the queue survives a reload, and its startup drain delivers what outlived the restart", () => {
    const abDir = tempDir();
    const first = harness(abDir, { live: false });
    first.queue.queue(line({ id: "held" }));
    expect(first.injected).toHaveLength(0);

    // A fresh queue over the same directory is what a restarted bridge builds.
    const second = harness(abDir);
    expect(second.queue.lines.map((l) => l.id)).toEqual(["held"]);
    second.queue.drainAll();
    expect(second.injected.map((l) => l.id)).toEqual(["held"]);

    // And the file is written back, so a third boot holds nothing.
    expect(loadDeliveries(abDir, PROJECT).lines).toHaveLength(0);
  });

  test("a persisted queue over the cap is trimmed on the way to disk", () => {
    const abDir = tempDir();
    let s = emptyDeliveries();
    for (let i = 0; i < MAX_QUEUED_LINES; i += 1) {
      s = enqueueLine(s, { ...line({ id: `l-${i}` }), queuedAt: i });
    }
    saveDeliveries(abDir, PROJECT, s);
    expect(loadDeliveries(abDir, PROJECT).lines).toHaveLength(MAX_QUEUED_LINES);
  });

  test("forget drops a deleted session's lines, which can never be delivered", () => {
    const h = harness(tempDir(), { live: false });
    h.queue.queue(line({ id: "a" }));
    h.queue.queue(line({ id: "b", sessionId: "other" }));
    h.queue.forget(SESSION);
    expect(h.queue.lines.map((l) => l.id)).toEqual(["b"]);
  });

  test("two projects on one machine keep distinct queues and never see each other's lines", () => {
    const abDir = tempDir();
    let p1 = emptyDeliveries();
    p1 = enqueueLine(p1, { ...line({ id: "p1-line" }), queuedAt: 1 });
    saveDeliveries(abDir, "project-one", p1);

    let p2 = emptyDeliveries();
    p2 = enqueueLine(p2, { ...line({ id: "p2-line" }), queuedAt: 1 });
    saveDeliveries(abDir, "project-two", p2);

    expect(loadDeliveries(abDir, "project-one").lines.map((l) => l.id)).toEqual(["p1-line"]);
    expect(loadDeliveries(abDir, "project-two").lines.map((l) => l.id)).toEqual(["p2-line"]);

    // Pinned to the literal path, not just to a helper's return value: reading
    // and writing through the same helper would still pass if the queue moved,
    // so this is the only thing in the suite that would notice a relocation.
    expect(existsSync(join(abDir, "session-bus", "bus.db"))).toBe(true);
    // The queue is keyed by project INSIDE that one table. A per-project
    // directory reappearing here would mean a reclaim had gone back to being a
    // directory delete, which is what stopped covering these rows.
    expect(existsSync(join(abDir, "agents", "project-one"))).toBe(false);
  });
});
