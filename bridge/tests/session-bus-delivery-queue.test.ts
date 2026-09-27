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
  CONFIRM_TIMEOUT_MS,
  DeliveryKindSchema,
  MAX_QUEUED_LINES,
  MAX_SUBMIT_ATTEMPTS,
  SessionBusDeliveryQueue,
  emptyDeliveries,
  enqueueLine,
  forgetSession,
  linesFor,
  loadDeliveries,
  removeLine,
  saveDeliveries,
  type BusInjectOutcome,
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

/** The queue plus the two things `ProjectCore` supplies it: the delivery gate
 *  from the work-status reduction, and a submit that reports whether the line
 *  actually went into a session. */
function harness(abDir: string, opts: { live?: boolean; confirmable?: boolean } = {}) {
  const openTurns = new Set<string>();
  const injected: QueuedLine[] = [];
  let live = opts.live !== false;
  // Default false: five of the six agents announce nothing, so that is the
  // ordinary session, and a write is the only answer one gives.
  const confirmable = opts.confirmable === true;
  let now = 1_000;
  const queue = new SessionBusDeliveryQueue({
    abDir,
    projectId: PROJECT,
    // Only the turn half of the real gate: what else holds a line is
    // `busDeliverable`'s business and is covered in work-status.test.ts. The
    // unattributed key stays, because it is what makes this differ from a
    // membership check.
    canDeliver: (id) => !turnOpenFor(openTurns, id),
    inject: (l) => {
      if (!live) return "refused";
      injected.push(l);
      return confirmable ? "awaiting-turn" : "submitted";
    },
    now: () => now,
  });
  return {
    queue,
    injected,
    openTurns,
    setLive(v: boolean) { live = v; },
    advance(ms: number) { now += ms; },
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
      canDeliver: () => true,
      inject: (l): BusInjectOutcome => {
        if (throwing) throw new Error("the adapter is gone");
        injected.push(l);
        return "submitted";
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

  test("a line submitted into an agent that announces nothing is removed on the write", () => {
    // Five of the six adapters declare `observation.turnStart: false`, so no
    // edge is ever coming for them. Holding the line would time out and
    // re-inject on every delivery to every one of them.
    const h = harness(tempDir());
    h.queue.queue(line());
    expect(h.queue.lines).toHaveLength(0);
  });

  test("a line submitted into a session that announces its turns is held until the turn opens", () => {
    const abDir = tempDir();
    const h = harness(abDir, { confirmable: true });
    h.queue.queue(line());
    expect(h.injected).toHaveLength(1);
    // Still held: the adapter took the text, which is not the same as the agent
    // having read it — that is the whole defect.
    expect(h.queue.lines.map((l) => l.id)).toEqual(["l-1"]);
    expect(h.queue.lines[0]!.sentAt).toBe(1_000);

    // No second copy while the window is open, whatever re-enters the drain.
    h.queue.drain(SESSION);
    h.queue.drainAll();
    expect(h.injected).toHaveLength(1);

    h.queue.confirm(SESSION);
    expect(h.queue.lines).toHaveLength(0);
    expect(loadDeliveries(abDir, PROJECT).lines).toHaveLength(0);
  });

  test("a confirm on a head that was never submitted leaves it queued", () => {
    // A session opening a turn of its own is not a delivery confirmation, and
    // reading it as one would drop a line that never reached the agent at all.
    const h = harness(tempDir(), { live: false });
    h.queue.queue(line());
    h.queue.confirm(SESSION);
    expect(h.queue.lines.map((l) => l.id)).toEqual(["l-1"]);
  });

  test("a submit whose turn never opens is retried once, then dropped rather than cycling forever", () => {
    const h = harness(tempDir(), { confirmable: true });
    h.queue.queue(line());
    expect(h.injected).toHaveLength(1);

    h.advance(CONFIRM_TIMEOUT_MS);
    h.queue.drain(SESSION);
    expect(h.injected).toHaveLength(MAX_SUBMIT_ATTEMPTS);

    // Past the cap the line goes: every later arrival for this session queues
    // behind it, and each retry appends another copy into the composer holding
    // the ones before it.
    h.advance(CONFIRM_TIMEOUT_MS);
    h.queue.drain(SESSION);
    expect(h.injected).toHaveLength(MAX_SUBMIT_ATTEMPTS);
    expect(h.queue.lines).toHaveLength(0);
  });

  test("the line behind a dropped head goes in on the same drain", () => {
    // A drop opens no turn and clears no block, so it produces none of the edges
    // that re-enter the drain: the rest of the queue would sit behind it on a
    // session that is already idle until something unrelated happened.
    const h = harness(tempDir(), { confirmable: true });
    h.queue.queue(line({ id: "head" }));
    h.queue.queue(line({ id: "behind" }));
    expect(h.injected.map((l) => l.id)).toEqual(["head"]);

    h.advance(CONFIRM_TIMEOUT_MS);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["head", "head"]);

    h.advance(CONFIRM_TIMEOUT_MS);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["head", "head", "behind"]);
    expect(h.queue.lines.map((l) => l.id)).toEqual(["behind"]);
  });

  test("a redelivery of an already-held line re-drains it rather than short-circuiting on the id", () => {
    // The sender's outbox retries until acked, and for a session whose stamped
    // head went stale that redelivery may be the only event it gets.
    const h = harness(tempDir(), { confirmable: true });
    h.queue.queue(line());
    expect(h.injected).toHaveLength(1);

    h.advance(CONFIRM_TIMEOUT_MS);
    h.queue.queue(line());
    expect(h.injected).toHaveLength(2);
    expect(h.queue.lines).toHaveLength(1);
  });

  test("a row persisted before the confirmation fields existed still loads", () => {
    // `readRecords` drops a row whose parse fails and reports nothing, so a
    // required field here empties every session's queue on upgrade — and the
    // lines it drops are the ones nothing re-sends.
    const abDir = tempDir();
    saveDeliveries(abDir, PROJECT, { lines: [{ ...line(), queuedAt: 1 }] });
    expect(loadDeliveries(abDir, PROJECT).lines.map((l) => l.id)).toEqual(["l-1"]);
  });

  test("a submit stamp does not survive the process that made it", () => {
    // The stamp says the text is in the agent's composer, and that composer
    // died with the previous process's PTY. Carried across, nothing re-enters
    // the drain inside the confirm window — the timer is in memory — and the
    // next turn the session opens for any reason retires the line as read.
    const abDir = tempDir();
    saveDeliveries(abDir, PROJECT, { lines: [{ ...line(), queuedAt: 1, sentAt: 1, attempts: 1 }] });

    const h = harness(abDir, { confirmable: true });
    // Re-submitted at once rather than waited on, and the attempt bound is the
    // one thing that DOES carry over.
    expect(h.injected.map((l) => l.id)).toEqual([]);
    h.queue.drainAll();
    expect(h.injected.map((l) => l.id)).toEqual(["l-1"]);
    expect(h.queue.lines[0]!.attempts).toBe(2);
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
