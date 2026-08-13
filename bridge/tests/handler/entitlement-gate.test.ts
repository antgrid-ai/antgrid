// bridge/tests/handler/entitlement-gate.test.ts
//
// The gate at the real Handler entry points, through the real predicate. The
// registry's own behaviour is covered in ../entitlement.test.ts; what is proved
// here is that arm() and handleEvent() actually consult it, and that a refusal
// lands on the SAME not-armed state the bridge already has for Handler-off
// rather than on a new failure mode.
import { describe, it, expect } from "bun:test";
import { HandlerEngine } from "../../src/handler/engine";
import { createEntitlementReader, type TierClaim } from "../../src/entitlement";
import { __setRootForTest } from "../../src/logger";
import type { AbMessage } from "../../src/protocol";
import type { HandlerDecision } from "../../src/handler/decision";
import type { HandlerSessionRecord } from "../../src/handler/session-store";
import type { StoredSnapshot } from "../../src/handler/snapshot-store";
import { planSnapshots, type SnapshotOutcome } from "../../src/handler/snapshot";

const GOAL = "Migrate auth";

// A judge verdict that produces an OBSERVABLE side effect (a terminal
// injection), so "the gate let this through" is asserted on the agent actually
// being driven rather than on the absence of a log line.
const handleDecision = {
  decision: "handle", confidence: 0.9, reason: "r", reply: "carry on",
} as unknown as HandlerDecision;

interface Harness {
  engine: HandlerEngine;
  sent: AbMessage[];
  saved: HandlerSessionRecord[];
  activity: unknown[];
  injected: Array<[string, string]>;
}

// Deliberately built through createEntitlementReader rather than a stub verdict:
// a hand-written `entitlement: () => ({allowed:false})` would still pass if the
// registry were bypassed, which is the thing under test.
function makeEngine(claim?: () => TierClaim, over: Record<string, unknown> = {}): Harness {
  const sent: AbMessage[] = [];
  const saved: HandlerSessionRecord[] = [];
  const activity: unknown[] = [];
  const injected: Array<[string, string]> = [];
  let stored: StoredSnapshot[] = [];
  const engine = new HandlerEngine({
    projectId: "proj", projectPath: () => "/proj", tool: () => "claude-code", abDir: "/tmp/unused",
    adapter: {
      injectReply: (id: string, t: string) => injected.push([id, t]),
      recentOutput: () => "pty-tail",
      transcriptPath: () => "/t.jsonl",
      outputKind: () => "pty",
      supportsSlashCommands: () => true,
    },
    sendAb: (m: AbMessage) => sent.push(m),
    sendPush: () => {},
    runExtractionFn: async () => null,
    takeSnapshotsFn: async ({ text }: { text: string }): Promise<SnapshotOutcome[]> =>
      planSnapshots(text).map((p) => ({ status: "nothing", action: p.action, trigger: p.trigger, detail: "stub" })),
    clearTrashFn: async () => {},
    loadSnapshotsFn: () => stored,
    saveSnapshotsFn: (e: StoredSnapshot[]) => { stored = e; },
    loadConfigFn: () => ({ version: 2, defaultNotifyOnly: false }),
    appendActivityFn: (r: unknown) => activity.push(r),
    loadSessionFn: () => null,
    saveSessionFn: (r: HandlerSessionRecord) => saved.push(r),
    now: () => 1000,
    schedule: () => () => {},
    entitlement: createEntitlementReader(claim),
    ...over,
  } as never);
  return { engine, sent, saved, activity, injected };
}

function credentialed(tier: string | null): () => TierClaim {
  return () => ({ credentialed: true, tier });
}

interface StatusFrame { sessions: Array<{ terminalId: string; state: string }> }
function lastStatus(sent: AbMessage[]): StatusFrame {
  return sent.filter((m) => m.type === "handler:status").at(-1) as never as StatusFrame;
}

// A refusal's only trace is the warn line, so reading it is how "refused for
// this reason" is distinguished from "happened not to arm".
async function capturingWarnings(fn: () => Promise<void> | void): Promise<string> {
  const lines: string[] = [];
  __setRootForTest({ write: (m: string) => { lines.push(m); } }, "warn");
  try { await fn(); } finally { __setRootForTest(process.stdout, "info"); }
  return lines.join("");
}

describe("arm()", () => {
  it("arms normally when the token's tier grants Handler", () => {
    const { engine, sent, saved, activity } = makeEngine(credentialed("pro"));
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    expect(lastStatus(sent).sessions).toHaveLength(1);
    expect(lastStatus(sent).sessions[0]!.state).toBe("watching");
    expect(saved.at(-1)?.armed).toBe(true);
    expect((activity[0] as { decision: string }).decision).toBe("armed");
  });

  it("refuses an arm whose tier does not grant Handler, via the Handler-off path", async () => {
    const { engine, sent, saved, activity } = makeEngine(credentialed("free"));
    const warned = await capturingWarnings(() => { engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false }); });
    expect(warned).toContain("entitlement not_entitled");

    // The refusal IS the not-armed state, byte-for-byte: no session row, so the
    // app renders exactly what it renders for a project whose Handler was never
    // armed. Nothing here invents a new state for the app to learn.
    expect(lastStatus(sent).sessions).toEqual([]);
    // And it leaves nothing behind — no persisted record to rehydrate from and
    // no feed row claiming supervision that is not running.
    expect(saved).toEqual([]);
    expect(activity).toEqual([]);
  });

  it("still emits status on a refusal, so a sender's optimistic UI resyncs", () => {
    const { engine, sent } = makeEngine(credentialed("free"));
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    expect(sent.filter((m) => m.type === "handler:status")).toHaveLength(1);
  });

  it("fails closed when a credentialed machine has no readable claim", async () => {
    // The token is missing, malformed or expired — every one of those reaches
    // the engine as `tier: null`, and a paid capability must not open on it.
    const { engine, sent, saved } = makeEngine(credentialed(null));
    const warned = await capturingWarnings(() => { engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false }); });
    expect(warned).toContain("entitlement unreadable");
    expect(lastStatus(sent).sessions).toEqual([]);
    expect(saved).toEqual([]);
  });

  it("refuses a persisted armed record too, so a restart cannot resurrect past the gate", () => {
    // arm() is also the rehydration path (`loadSessionFn` → resumed record), and
    // it is the only sessions.set in the engine. A downgrade that happened while
    // the bridge was down must not be undone by the restart itself.
    const { engine, sent, saved } = makeEngine(credentialed("free"), {
      loadSessionFn: (): HandlerSessionRecord => ({
        version: 2, terminalId: "t1", armed: true, suspended: true, goal: GOAL,
        backlog: [], notifyOnly: false, armedAt: 1, escalations: [],
      }),
    });
    engine.arm({ terminalId: "t1", notifyOnly: false });
    expect(lastStatus(sent).sessions).toEqual([]);
    expect(saved).toEqual([]);
  });
});

describe("handleEvent()", () => {
  it("lets an entitled session act on its events", async () => {
    const { engine, injected } = makeEngine(credentialed("pro"), {
      runDecisionFn: async () => handleDecision,
    });
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(injected).toEqual([["t1", "carry on"]]);
  });

  it("suspends an armed session the moment its tier stops granting Handler", async () => {
    // The second read is what bounds a downgrade to one token lifetime instead
    // of the armed session's lifetime — an hour, not a week.
    let tier = "pro";
    const { engine, saved, injected } = makeEngine(() => ({ credentialed: true, tier }), {
      runDecisionFn: async () => handleDecision,
    });
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    expect(saved.at(-1)?.armed).toBe(true);

    tier = "free";
    await capturingWarnings(() => engine.handleEvent({ terminalId: "t1", event: "turn_end" }));

    // Nothing was injected into the agent's terminal on the refused event.
    expect(injected).toEqual([]);
    // Suspended, not plainly disarmed: the goal and backlog survive for a re-arm
    // once the subscription is back, exactly as a host shutdown leaves them.
    expect(saved.at(-1)?.armed).toBe(false);
    expect(saved.at(-1)?.suspended).toBe(true);
    expect(saved.at(-1)?.goal).toBe(GOAL);
  });

  it("leaves no session row behind after a mid-session downgrade", async () => {
    let tier = "pro";
    const { engine, sent } = makeEngine(() => ({ credentialed: true, tier }));
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    tier = "free";
    await capturingWarnings(() => engine.handleEvent({ terminalId: "t1", event: "turn_end" }));
    expect(lastStatus(sent).sessions).toEqual([]);
  });

  it("stays a no-op for an unarmed terminal, gate or no gate", async () => {
    // The pre-existing Handler-off path must not start warning about
    // entitlement for every event on every unsupervised session.
    const { engine } = makeEngine(credentialed("free"));
    const warned = await capturingWarnings(() => engine.handleEvent({ terminalId: "nope", event: "turn_end" }));
    expect(warned).toBe("");
  });
});

describe("the local/offline developer flow", () => {
  // Asserted at the ENGINE, not only at the predicate, because this is the
  // carve-out someone "fixes" while making the gate stricter — and the failure
  // mode is a bricked offline developer, not a leaked feature.
  it("arms and acts with no credential source wired at all", async () => {
    const { engine, sent, injected } = makeEngine(undefined, {
      runDecisionFn: async () => handleDecision,
    });
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    expect(lastStatus(sent).sessions).toHaveLength(1);
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(injected).toEqual([["t1", "carry on"]]);
  });

  it("arms and acts on a runtime that holds no device credentials", async () => {
    // A bare `antgrid agent`, or a desktop nobody has signed into: it never had
    // a token, so there is no claim to fail closed on.
    const { engine, sent, injected } = makeEngine(() => ({ credentialed: false, tier: null }), {
      runDecisionFn: async () => handleDecision,
    });
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    expect(lastStatus(sent).sessions).toHaveLength(1);
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(injected).toEqual([["t1", "carry on"]]);
  });

  it("keeps working when the engine is built with no entitlement dep", async () => {
    // The default the constructor installs. A HandlerEngine assembled without a
    // host — which is every unit test in this directory — must still arm.
    const { engine, sent } = makeEngine(undefined, { entitlement: undefined });
    engine.arm({ terminalId: "t1", goal: GOAL, notifyOnly: false });
    expect(lastStatus(sent).sessions).toHaveLength(1);
  });
});
