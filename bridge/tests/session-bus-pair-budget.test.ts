// bridge/tests/session-bus-pair-budget.test.ts
import { test, expect } from "bun:test";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  budgetFor,
  checkHalt,
  checkNotify,
  clearHalt,
  emptyPairBudget,
  expireNotifies,
  loadPairBudgets,
  noteExchange,
  noteProgress,
  pairEnds,
  pairKey,
  savePairBudgets,
  upsertPairBudget,
  type PairBudgetState,
  type PairEnd,
} from "../src/session-bus/pair-budget";
import { MAX_NOTIFIES_PER_PAIR_HOUR, NO_PROGRESS_EXCHANGES } from "../src/session-bus/constants";

const T0 = 5_000_000;
const HOUR_MS = 60 * 60_000;

const A: PairEnd = { machineId: "m1", sessionId: "s1" };
const B: PairEnd = { machineId: "m2", sessionId: "s2" };
const KEY = pairKey(A, B);

function withNotifies(n: number, at = T0): PairBudgetState {
  return { ...emptyPairBudget(KEY), notifiesAtMs: Array.from({ length: n }, () => at) };
}

function haltedState(now = T0): PairBudgetState {
  let s = emptyPairBudget(KEY);
  for (let i = 0; i < NO_PROGRESS_EXCHANGES; i += 1) s = noteExchange(s, now);
  return s;
}

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-pair-budget-"));
}

test("pairKey is order-independent: the same record whichever end calls it", () => {
  expect(pairKey(A, B)).toBe(pairKey(B, A));
  expect(pairKey(A, B)).not.toBe(pairKey(A, { machineId: "m3", sessionId: "s3" }));
});

test("the notify ceiling refuses once spent, and names post as the verb that still reaches", () => {
  const under = withNotifies(MAX_NOTIFIES_PER_PAIR_HOUR - 1);
  expect(checkNotify(under, T0)).toBeNull();

  const at = withNotifies(MAX_NOTIFIES_PER_PAIR_HOUR);
  const refusal = checkNotify(at, T0)!;
  expect(refusal.code).toBe("NOTIFY_RATE");
  expect(refusal.error).toContain("post");
});

test("the notify window is rolling, not lifetime — an hour-old notify drops off", () => {
  const spent = withNotifies(MAX_NOTIFIES_PER_PAIR_HOUR, T0);

  // Still within the hour: refused.
  expect(checkNotify(spent, T0 + HOUR_MS - 1)).not.toBeNull();
  // An hour and a second later, every one of those notifies has aged out.
  expect(checkNotify(spent, T0 + HOUR_MS + 1)).toBeNull();
});

test("NO_PROGRESS_EXCHANGES consecutive exchanges with no progress trip a halt", () => {
  let s = emptyPairBudget(KEY);
  for (let i = 1; i < NO_PROGRESS_EXCHANGES; i += 1) {
    s = noteExchange(s, T0);
    expect(s.haltedAt).toBeNull();
    expect(checkHalt(s)).toBeNull();
  }
  s = noteExchange(s, T0 + 9);
  expect(s.haltedAt).toBe(T0 + 9);
  expect(checkHalt(s)?.code).toBe("NO_PROGRESS");

  // A halted pair stops counting: the moment does not drift on further traffic.
  expect(noteExchange(s, T0 + 100)).toBe(s);
});

test("a halted pair refuses checkHalt regardless of which verb asks — post included", () => {
  // checkHalt takes no verb: it is the one gate consulted before post, notify
  // AND reply alike (§7.4/§8.2), so this single check IS the post-path refusal
  // too — there is no separate notify-only halt to bypass by calling post.
  const halted = haltedState();
  const refusal = checkHalt(halted)!;
  expect(refusal).not.toBeNull();
  expect(refusal.code).toBe("NO_PROGRESS");

  // An un-halted pair with the notify budget exhausted may still post — only
  // checkNotify refuses it, never checkHalt.
  const notifyExhausted = withNotifies(MAX_NOTIFIES_PER_PAIR_HOUR);
  expect(checkHalt(notifyExhausted)).toBeNull();
});

test("publishing an artifact or opening a new thread — noteProgress — resets the counter", () => {
  let s = emptyPairBudget(KEY);
  for (let i = 0; i < NO_PROGRESS_EXCHANGES - 1; i += 1) s = noteExchange(s, T0);
  expect(s.exchangesSinceProgress).toBe(NO_PROGRESS_EXCHANGES - 1);

  s = noteProgress(s);
  expect(s.exchangesSinceProgress).toBe(0);
  expect(noteProgress(s)).toBe(s);

  // Progress never lifts a halt already tripped — only a human does.
  const halted = haltedState();
  const stillHalted = noteProgress(halted);
  expect(stillHalted.haltedAt).toBe(halted.haltedAt);
});

test("only a human clear — clearHalt — lifts a halt; nothing else does", () => {
  const halted = haltedState();
  expect(checkHalt(halted)).not.toBeNull();

  const lifted = clearHalt(halted);
  expect(lifted.haltedAt).toBeNull();
  expect(lifted.exchangesSinceProgress).toBe(0);
  expect(checkHalt(lifted)).toBeNull();

  // Nothing to lift is not an error, and returns the same object.
  expect(clearHalt(lifted)).toBe(lifted);
  const neverHalted = emptyPairBudget(KEY);
  expect(clearHalt(neverHalted)).toBe(neverHalted);
});

test("expireNotifies drops what the rolling window has forgotten and leaves a halt untouched", () => {
  const s: PairBudgetState = { ...haltedState(T0), notifiesAtMs: [T0, T0 + 50] };

  const pruned = expireNotifies(s, T0 + HOUR_MS + 51);

  expect(pruned.notifiesAtMs).toEqual([]);
  expect(pruned.haltedAt).toBe(s.haltedAt);
  expect(expireNotifies(pruned, T0 + HOUR_MS + 1)).toBe(pruned);
});

test("budgetFor and upsertPairBudget round-trip a session's per-peer records in memory", () => {
  const empty = budgetFor([], KEY);
  expect(empty).toEqual(emptyPairBudget(KEY));

  const touched = noteExchange(empty, T0);
  const records = upsertPairBudget([], touched);

  expect(budgetFor(records, KEY)).toEqual(touched);
});

test("a halt survives a process restart — the one thing an unpersisted guard could not make true", () => {
  const abDir = tmpAbDir();
  try {
    const halted = haltedState(T0);
    savePairBudgets(abDir, "p1", "s1", [halted]);

    const reloaded = budgetFor(loadPairBudgets(abDir, "p1", "s1", T0 + 1), KEY);
    expect(reloaded.haltedAt).toBe(T0);
    expect(checkHalt(reloaded)).not.toBeNull();
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("persisted records are scoped per session, and stale notify timestamps do not survive a reload", () => {
  const abDir = tmpAbDir();
  try {
    savePairBudgets(abDir, "p1", "s1", [withNotifies(MAX_NOTIFIES_PER_PAIR_HOUR, T0)]);
    savePairBudgets(abDir, "p1", "s2", [emptyPairBudget(pairKey(B, A))]);

    // Loaded soon after: the ceiling is still spent.
    const soon = budgetFor(loadPairBudgets(abDir, "p1", "s1", T0 + 1), KEY);
    expect(checkNotify(soon, T0 + 1)).not.toBeNull();

    // Loaded an hour and a second later: the window has forgotten every one of
    // them, so the persisted record itself comes back pruned.
    const later = budgetFor(loadPairBudgets(abDir, "p1", "s1", T0 + HOUR_MS + 1), KEY);
    expect(later.notifiesAtMs).toEqual([]);

    // The other session's scope is untouched.
    expect(loadPairBudgets(abDir, "p1", "s2", T0 + 1)).toHaveLength(1);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

// -- the gate, driven through the one seam every send takes ------------------
//
// Everything above proves the arithmetic. None of it can prove there is a
// caller: a ceiling with no producer reads exactly the same in a report as one
// that refuses, which is how the module this replaced stayed green for a year
// while enforcing nothing. These drive `SessionBusCoordinator.message` and
// assert on what it returns.

function gatedCoordinator(abDir: string): { bus: SessionBusCoordinator; rows: Map<string, PairBudgetState[]> } {
  const rows = new Map<string, PairBudgetState[]>();
  let now = T0;
  const bus = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => "p1",
    self: (sessionId) =>
      sessionId === A.sessionId
        ? { key: { machineId: A.machineId, projectId: "p1", sessionId }, ref: { machineId: A.machineId, projectId: "p1", sessionId } }
        : null,
    send: () => true,
    pairBudget: {
      recordsFor: (sessionId) => rows.get(sessionId) ?? [],
      write: (sessionId, next) => rows.set(sessionId, upsertPairBudget(rows.get(sessionId) ?? [], next)),
    },
    now: () => (now += 1),
  });
  return { bus, rows };
}

const TO = { machineId: B.machineId, projectId: "p2", sessionId: B.sessionId };

function send(bus: SessionBusCoordinator, verb: "post" | "notify", over: { threadId?: string | null; artifact?: boolean } = {}) {
  return bus.message({
    sessionId: A.sessionId,
    verb,
    threadId: over.threadId === undefined ? null : over.threadId,
    to: TO,
    summary: "s",
    parts: over.artifact
      ? [{
        kind: "artifact" as const,
        artifactId: "a1",
        name: "log.txt",
        mediaType: "text/plain",
        bytes: 4,
        sha256: "0".repeat(64),
        summary: "the failing run",
      }]
      : [{ kind: "text", text: "t" }],
  });
}

function withGate(run: (bus: SessionBusCoordinator, rows: Map<string, PairBudgetState[]>) => void): void {
  const abDir = tmpAbDir();
  const { bus, rows } = gatedCoordinator(abDir);
  try {
    run(bus, rows);
  } finally {
    bus.stop();
    rmSync(abDir, { recursive: true, force: true });
  }
}

test("the notify ceiling refuses a real send, and post on the same pair still reaches", () => {
  withGate((bus) => {
    for (let i = 0; i < MAX_NOTIFIES_PER_PAIR_HOUR; i += 1) {
      expect(send(bus, "notify")).toMatchObject({ ok: true });
    }
    const refused = send(bus, "notify");
    expect(refused).toMatchObject({ ok: false, code: "NOTIFY_RATE" });
    // Named in the refusal AND true in fact: the verb the reader is sent to
    // has to actually work, or the advice is worse than no advice.
    expect((refused as { error: string }).error).toContain("post");
    expect(send(bus, "post")).toMatchObject({ ok: true });
  });
});

test("a refused send leaves no trace of the message it refused", () => {
  withGate((bus) => {
    for (let i = 0; i < MAX_NOTIFIES_PER_PAIR_HOUR; i += 1) send(bus, "notify");
    const before = bus.messages(A.sessionId).entries.length;
    expect(send(bus, "notify")).toMatchObject({ ok: false });
    // A refusal that had already stamped and logged would leave a thread row a
    // reply could later be routed on for an exchange that never happened.
    expect(bus.messages(A.sessionId).entries).toHaveLength(before);
  });
});

test("a pair that talks without publishing or opening a thread is halted, and the halt refuses post too", () => {
  withGate((bus) => {
    const opening = send(bus, "post");
    if (!("ok" in opening) || !opening.ok) throw new Error("first send refused");
    const thread = opening.threadId;
    // Replies on the SAME thread: no artifact, no new thread, which is exactly
    // what 7.4 counts as nothing moving.
    for (let i = 1; i < NO_PROGRESS_EXCHANGES; i += 1) {
      expect(send(bus, "post", { threadId: thread })).toMatchObject({ ok: true });
    }
    const halted = send(bus, "post", { threadId: thread });
    expect(halted).toMatchObject({ ok: false, code: "NO_PROGRESS" });
    // The halt is not the notify ceiling wearing another name: post is the
    // unbudgeted verb and it is refused here all the same.
    expect(send(bus, "notify", { threadId: thread })).toMatchObject({ ok: false, code: "NO_PROGRESS" });
  });
});

test("a new thread and a published artifact each keep the counter from ever reaching the halt", () => {
  withGate((bus) => {
    for (let i = 0; i < NO_PROGRESS_EXCHANGES * 2; i += 1) {
      expect(send(bus, "post")).toMatchObject({ ok: true });
    }
  });
  withGate((bus) => {
    const opening = send(bus, "post");
    if (!("ok" in opening) || !opening.ok) throw new Error("first send refused");
    for (let i = 0; i < NO_PROGRESS_EXCHANGES * 2; i += 1) {
      expect(send(bus, "post", { threadId: opening.threadId, artifact: true })).toMatchObject({ ok: true });
    }
  });
});

test("only a human clears a halt the gate tripped", () => {
  withGate((bus, rows) => {
    const opening = send(bus, "post");
    if (!("ok" in opening) || !opening.ok) throw new Error("first send refused");
    for (let i = 1; i < NO_PROGRESS_EXCHANGES; i += 1) send(bus, "post", { threadId: opening.threadId });
    expect(send(bus, "post", { threadId: opening.threadId })).toMatchObject({ ok: false, code: "NO_PROGRESS" });

    // The coordinator delegates clearing to whoever holds the store, which is
    // the host in production; here that is the same map the gate reads.
    rows.set(A.sessionId, (rows.get(A.sessionId) ?? []).map(clearHalt));
    expect(send(bus, "post", { threadId: opening.threadId })).toMatchObject({ ok: true });
  });
});

// -- the read-only probe ----------------------------------------------------
//
// `pairRefusal` exists so a verb layer can put the halt ABOVE its liveness
// check. That makes it a second reader of the same counters, and the failure it
// can introduce is silent: a probe that charged what it read would halt a
// healthy pair in half the exchanges §7.4 allows, and every test above would
// still pass.

test("pairRefusal answers null for a pair that has never spent anything", () => {
  withGate((bus) => {
    expect(bus.pairRefusal(A.sessionId, TO, "post")).toBeNull();
    expect(bus.pairRefusal(A.sessionId, TO, "notify")).toBeNull();
  });
});

test("pairRefusal reports the halt for BOTH verbs — the ordering it exists to enable", () => {
  withGate((bus) => {
    const opening = send(bus, "post");
    if (!("ok" in opening) || !opening.ok) throw new Error("first send refused");
    for (let i = 1; i < NO_PROGRESS_EXCHANGES; i += 1) send(bus, "post", { threadId: opening.threadId });

    expect(bus.pairRefusal(A.sessionId, TO, "post")?.code).toBe("NO_PROGRESS");
    expect(bus.pairRefusal(A.sessionId, TO, "notify")?.code).toBe("NO_PROGRESS");
  });
});

test("pairRefusal reports the notify ceiling for notify only; post still reads as reachable", () => {
  withGate((bus) => {
    for (let i = 0; i < MAX_NOTIFIES_PER_PAIR_HOUR; i += 1) send(bus, "notify");

    expect(bus.pairRefusal(A.sessionId, TO, "notify")?.code).toBe("NOTIFY_RATE");
    expect(bus.pairRefusal(A.sessionId, TO, "post")).toBeNull();
  });
});

test("a session with no address answers null rather than a refusal about the pair", () => {
  withGate((bus) => {
    expect(bus.pairRefusal("not-held", TO, "notify")).toBeNull();
  });
});

test("asking does not spend: pairRefusal leaves the store untouched and the send still lands", () => {
  withGate((bus, rows) => {
    const opening = send(bus, "post");
    if (!("ok" in opening) || !opening.ok) throw new Error("first send refused");
    const spent = structuredClone(rows.get(A.sessionId));

    // Far more asks than the no-progress counter has room for: if any of them
    // charged, the pair would be halted before the send below.
    for (let i = 0; i < NO_PROGRESS_EXCHANGES * 4; i += 1) {
      expect(bus.pairRefusal(A.sessionId, TO, i % 2 === 0 ? "post" : "notify")).toBeNull();
    }

    expect(rows.get(A.sessionId)).toEqual(spent);
    expect(send(bus, "post", { threadId: opening.threadId })).toMatchObject({ ok: true });
  });
});

// -- the pair's two mirrors, kept in lockstep by charging BOTH halves --------
//
// The record is per END, not per pair: two machines cannot share a row. What
// makes the two copies agree is that every message is charged where it was sent
// AND where it landed. These drive a real exchange between two sessions one
// coordinator holds and assert on both rows at once — charging only the
// outbound half leaves each side counting its own traffic, which is the
// ping-pong `pairKey`'s doc says cannot happen.

const LOCAL = "m1";
const KEY_LOCAL = pairKey({ machineId: LOCAL, sessionId: "s1" }, { machineId: LOCAL, sessionId: "s2" });

function pairedCoordinator(abDir: string): { bus: SessionBusCoordinator; rows: Map<string, PairBudgetState[]> } {
  const rows = new Map<string, PairBudgetState[]>();
  let now = T0;
  let self: SessionBusCoordinator;
  const keyFor = (sessionId: string) => ({ machineId: LOCAL, projectId: "p1", sessionId });
  const bus = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => "p1",
    self: (sessionId) =>
      sessionId === "s1" || sessionId === "s2" ? { key: keyFor(sessionId), ref: keyFor(sessionId) } : null,
    // Both ends live in one coordinator, so the local hand-off IS the delivery:
    // this is what turns a `message` call into the inbound fold its peer sees.
    deliverLocal: (frame) => self.handleInbound(frame) === "applied",
    send: () => true,
    pairBudget: {
      recordsFor: (sessionId) => rows.get(sessionId) ?? [],
      write: (sessionId, next) => rows.set(sessionId, upsertPairBudget(rows.get(sessionId) ?? [], next)),
    },
    now: () => (now += 1),
  });
  self = bus;
  return { bus, rows };
}

function post(bus: SessionBusCoordinator, from: string, to: string, threadId: string | null) {
  return bus.message({
    sessionId: from,
    verb: "post",
    threadId,
    to: { machineId: LOCAL, projectId: "p1", sessionId: to },
    summary: "s",
    parts: [{ kind: "text", text: "t" }],
  });
}

function withPair(run: (bus: SessionBusCoordinator, rows: Map<string, PairBudgetState[]>) => void): void {
  const abDir = tmpAbDir();
  const { bus, rows } = pairedCoordinator(abDir);
  try {
    run(bus, rows);
  } finally {
    bus.stop();
    rmSync(abDir, { recursive: true, force: true });
  }
}

test("pairEnds is the inverse of pairKey, and refuses a key it cannot read", () => {
  const ends = pairEnds(pairKey(A, B))!;
  expect(ends.map((e) => e.sessionId).sort()).toEqual([A.sessionId, B.sessionId]);
  expect(ends.map((e) => e.machineId).sort()).toEqual([A.machineId, B.machineId]);

  expect(pairEnds("nothing-here")).toBeNull();
  expect(pairEnds("m1/s1|m2/s2|m3/s3")).toBeNull();
});

test("an arriving message charges the RECEIVER's mirror, not only the sender's", () => {
  withPair((bus, rows) => {
    const opening = post(bus, "s1", "s2", null);
    if (!("ok" in opening) || !opening.ok) throw new Error("send refused");

    // Both ends now hold a record for the same unordered pair, and both have
    // counted the one message that has crossed it.
    for (const sessionId of ["s1", "s2"]) {
      const record = budgetFor(rows.get(sessionId) ?? [], KEY_LOCAL);
      expect(record.pairKey).toBe(KEY_LOCAL);
      expect(record.exchangesSinceProgress).toBe(1);
    }
  });
});

test("an alternating pair reaches the halt in NO_PROGRESS_EXCHANGES messages, not twice that, and both ends halt", () => {
  withPair((bus, rows) => {
    const opening = post(bus, "s1", "s2", null);
    if (!("ok" in opening) || !opening.ok) throw new Error("send refused");
    const thread = opening.threadId;

    // Alternating replies on the thread already open: nothing published, no new
    // thread. Counted at both ends, so the pair — not either sender — is what
    // runs out.
    let sender = "s2";
    for (let i = 1; i < NO_PROGRESS_EXCHANGES; i += 1) {
      const answer = post(bus, sender, sender === "s1" ? "s2" : "s1", thread);
      expect(answer).toMatchObject({ ok: true });
      sender = sender === "s1" ? "s2" : "s1";
    }

    // Charging only the outbound half would leave each side at three here, and
    // both of these sends would land.
    expect(post(bus, "s1", "s2", thread)).toMatchObject({ ok: false, code: "NO_PROGRESS" });
    expect(post(bus, "s2", "s1", thread)).toMatchObject({ ok: false, code: "NO_PROGRESS" });
    for (const sessionId of ["s1", "s2"]) {
      expect(budgetFor(rows.get(sessionId) ?? [], KEY_LOCAL).haltedAt).not.toBeNull();
    }
  });
});

test("the notify ceiling is spent by the pair, not by each sender in turn", () => {
  withPair((bus, rows) => {
    const notify = (from: string, to: string) =>
      bus.message({
        sessionId: from,
        verb: "notify",
        threadId: null,
        to: { machineId: LOCAL, projectId: "p1", sessionId: to },
        summary: "s",
        parts: [{ kind: "text", text: "t" }],
      });

    for (let i = 0; i < MAX_NOTIFIES_PER_PAIR_HOUR; i += 1) {
      expect(notify(i % 2 === 0 ? "s1" : "s2", i % 2 === 0 ? "s2" : "s1")).toMatchObject({ ok: true });
    }
    // Each session sent only half of them; the ceiling is the pair's.
    expect(notify("s1", "s2")).toMatchObject({ ok: false, code: "NOTIFY_RATE" });
    expect(notify("s2", "s1")).toMatchObject({ ok: false, code: "NOTIFY_RATE" });
    for (const sessionId of ["s1", "s2"]) {
      expect(budgetFor(rows.get(sessionId) ?? [], KEY_LOCAL).notifiesAtMs).toHaveLength(MAX_NOTIFIES_PER_PAIR_HOUR);
    }
  });
});
