import { describe, expect, it, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionError, SessionManager } from "../src/session-manager";
import { MAX_SESSION_MEMBERS, type SessionMemberRef } from "../src/protocol";
import type { CheckoutRecord } from "../src/worktrees/checkout-types";
import { WorktreeError, type WorktreeManager } from "../src/worktrees/worktree-manager";

function fakeTerminal() {
  const live = new Set<string>();
  return {
    spawn: (cfg: { terminalId: string }) => { live.add(cfg.terminalId); return cfg.terminalId; },
    kill: (id: string) => { live.delete(id); },
    forget: (id: string) => { live.delete(id); },
    treeKilled: () => Promise.resolve(),
    has: (id: string) => live.has(id),
  };
}

function makeManager(dir: string, extra: Record<string, unknown> = {}) {
  return new SessionManager({
    projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
    agentSpec: { command: "claude", name: "claude-code" },
    sendMessage: () => {},
    ...extra,
  } as any);
}

function peerRef(n: number): SessionMemberRef {
  return {
    machineId: `machine-${n}`,
    projectId: `project-${n}`,
    sessionId: `session-${n}`,
    machineLabel: `Machine ${n}`,
    projectLabel: `Project ${n}`,
    sessionName: `Peer ${n}`,
  };
}

const lead: SessionMemberRef = {
  machineId: "lead-machine", projectId: "lead-project", sessionId: "lead-session",
  machineLabel: "Laptop", projectLabel: "api", sessionName: "Investigation",
};

function persistedRows(dir: string): any[] {
  const raw = readFileSync(join(dir, "agents", "p1", "sessions.json"), "utf8");
  return JSON.parse(raw).sessions;
}

describe("session membership", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-member-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it("persists a peer's memberOf and held brief across a reload", async () => {
    const sm = makeManager(dir);
    const created = await sm.create("Peer", { memberOf: lead, brief: "Own the backend." });
    expect(created.memberOf).toMatchObject({ machineId: "lead-machine", role: "lead", state: "active" });
    expect(created.members).toBeUndefined();
    // Persisted-only: a client that could read the brief off the wire could
    // render or re-send it outside the bridge-authored wrapper.
    expect((created as any).pendingBrief).toBeUndefined();

    const reloaded = makeManager(dir);
    const row = reloaded.get(created.id);
    expect(row?.memberOf).toMatchObject({ machineId: "lead-machine", state: "active" });
    expect(reloaded.pendingBriefFor(created.id)).toBe("Own the backend.");
  });

  it("persists a lead's members across a reload", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    const wire = await sm.recordMember(led.id, peerRef(1));
    expect(wire.members).toHaveLength(1);
    expect(wire.memberOf).toBeUndefined();

    const reloaded = makeManager(dir);
    expect(reloaded.membersOf(led.id)).toEqual([
      expect.objectContaining({ machineId: "machine-1", role: "peer", state: "active" }),
    ]);
  });

  it("refuses a peer session on an isolated worktree", () => {
    const sm = makeManager(dir);
    expect(() => sm.create("Peer", { memberOf: lead, isolation: "worktree" } as any))
      .toThrow("a peer session cannot use worktree isolation");
  });

  it("refuses a brief with no lead to attribute it to", () => {
    const sm = makeManager(dir);
    expect(() => sm.create("Solo", { brief: "do the thing" } as any))
      .toThrow("brief is only valid for a peer session");
  });

  it("re-recording the same member refreshes labels and keeps joinedAt", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    const first = await sm.recordMember(led.id, peerRef(1));
    const joinedAt = first.members![0]!.joinedAt;
    const again = await sm.recordMember(led.id, { ...peerRef(1), sessionName: "Renamed" });
    expect(again.members).toHaveLength(1);
    expect(again.members![0]!.sessionName).toBe("Renamed");
    expect(again.members![0]!.joinedAt).toBe(joinedAt);
  });

  it("re-recording revives a released member and drops its release detail", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    await sm.recordMember(led.id, peerRef(1));
    await sm.releaseMember(led.id, peerRef(1), { deleteRefused: true, reason: "WORKTREE_DIRTY" });
    const revived = await sm.recordMember(led.id, peerRef(1));
    expect(revived.members![0]).toMatchObject({ state: "active" });
    expect(revived.members![0]!.releasedAt).toBeUndefined();
    expect(revived.members![0]!.releaseReason).toBeUndefined();
  });

  // A membership write is a transaction: memory is mutated first so the flush
  // has something to serialize, so a flush that fails has to put memory back. It
  // otherwise reports failure to the caller and then persists anyway on the next
  // unrelated write — the one state nothing in the system ever reconciles.
  function failNextFlush(sm: SessionManager): () => void {
    const real = (sm as any).flushNowOrThrow.bind(sm);
    let failing = true;
    (sm as any).flushNowOrThrow = async () => {
      if (!failing) return real();
      failing = false;
      throw new Error("disk full");
    };
    return () => { (sm as any).flushNowOrThrow = real; };
  }

  it("rolls back a recorded member when the flush fails", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    await sm.recordMember(led.id, peerRef(1));
    failNextFlush(sm);

    await expect(sm.recordMember(led.id, peerRef(2))).rejects.toThrow("disk full");

    expect(sm.membersOf(led.id).map((m) => m.machineId)).toEqual(["machine-1"]);
    expect(sm.get(led.id)?.members).toHaveLength(1);
    // The next successful write must not carry the rejected one with it.
    await sm.recordMember(led.id, peerRef(3));
    const row = persistedRows(dir).find((r: any) => r.id === led.id);
    expect(row.members.map((m: any) => m.machineId)).toEqual(["machine-1", "machine-3"]);
  });

  it("rolls back a release when the flush fails", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    await sm.recordMember(led.id, peerRef(1));
    failNextFlush(sm);

    await expect(sm.releaseMember(led.id, peerRef(1))).rejects.toThrow("disk full");

    expect(sm.membersOf(led.id)[0]).toMatchObject({ state: "active" });
    expect(sm.membersOf(led.id)[0]!.releasedAt).toBeUndefined();
  });

  it("rolls back an orphan mark when the flush fails", async () => {
    const sm = makeManager(dir);
    const peer = await sm.create("Peer", { memberOf: lead });
    failNextFlush(sm);

    await expect(sm.setMemberOfOrphaned(peer.id, true)).rejects.toThrow("disk full");

    expect(sm.memberOfFor(peer.id)).toMatchObject({ state: "active" });
    expect(sm.memberOfFor(peer.id)?.orphanedAt).toBeUndefined();
  });

  it("refuses to make a member session lead another", async () => {
    const sm = makeManager(dir);
    const peer = await sm.create("Peer", { memberOf: lead });
    const err = await sm.recordMember(peer.id, peerRef(1)).catch((e) => e);
    expect(err).toBeInstanceOf(SessionError);
    expect((err as SessionError).code).toBe("SESSION_MEMBER_CONFLICT");
  });

  it("evicts a departed member at the ceiling, and refuses when all are active", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    for (let i = 0; i < MAX_SESSION_MEMBERS; i++) await sm.recordMember(led.id, peerRef(i));
    const err = await sm.recordMember(led.id, peerRef(999)).catch((e) => e);
    expect(err).toBeInstanceOf(SessionError);
    expect((err as SessionError).code).toBe("SESSION_MEMBER_LIMIT");

    await sm.releaseMember(led.id, peerRef(0));
    const after = await sm.recordMember(led.id, peerRef(999));
    expect(after.members).toHaveLength(MAX_SESSION_MEMBERS);
    expect(after.members!.some((m) => m.machineId === "machine-0")).toBe(false);
    expect(after.members!.some((m) => m.machineId === "machine-999")).toBe(true);
  });

  it("releasing a member this row never held succeeds and changes nothing", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    await sm.recordMember(led.id, peerRef(1));
    const wire = await sm.releaseMember(led.id, peerRef(2));
    expect(wire.members).toHaveLength(1);
    expect(wire.members![0]!.state).toBe("active");
  });

  it("records a refused peer delete as released-delete-refused with its reason", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    await sm.recordMember(led.id, peerRef(1));
    const released = await sm.releaseMember(led.id, peerRef(1), {
      deleteRefused: true, reason: "WORKTREE_DIRTY",
    });
    expect(released.members![0]).toMatchObject({
      state: "released-delete-refused", releaseReason: "WORKTREE_DIRTY",
    });
    // The refusal usually follows a plain release; whichever the app sends last
    // is the outcome it just observed, so the later call wins.
    const again = await sm.releaseMember(led.id, peerRef(1));
    expect(again.members).toHaveLength(1);
    expect(again.members![0]!.state).toBe("released");
  });

  it("marks and clears a peer's orphaned lead without deleting anything", async () => {
    const sm = makeManager(dir);
    const peer = await sm.create("Peer", { memberOf: lead });
    const orphaned = await sm.setMemberOfOrphaned(peer.id, true);
    expect(orphaned.memberOf).toMatchObject({ state: "orphaned" });
    expect(orphaned.memberOf!.orphanedAt).toBeNumber();
    expect(sm.list()).toHaveLength(1);

    const restored = await sm.setMemberOfOrphaned(peer.id, false);
    expect(restored.memberOf).toMatchObject({ state: "active" });
    expect(restored.memberOf!.orphanedAt).toBeUndefined();
    expect(persistedRows(dir)[0].memberOf.state).toBe("active");
  });

  it("refuses to orphan a session that has no lead", async () => {
    const sm = makeManager(dir);
    const solo = sm.create("Solo");
    const err = await sm.setMemberOfOrphaned(solo.id, true).catch((e) => e);
    expect(err).toBeInstanceOf(SessionError);
    expect((err as SessionError).code).toBe("SESSION_MEMBER_CONFLICT");
  });

  it("leaves an ordinary session's wire shape untouched", () => {
    const sm = makeManager(dir);
    const solo = sm.create("Solo");
    expect(solo.members).toBeUndefined();
    expect(solo.memberOf).toBeUndefined();
  });

  it("carries both halves through the cold peek but never the brief", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    await sm.recordMember(led.id, peerRef(1));
    const peer = await sm.create("Peer", { memberOf: lead, brief: "Own the backend." });

    const peeked = await SessionManager.readPersisted(dir, "p1");
    const peekedLead = peeked.find((s) => s.id === led.id)!;
    const peekedPeer = peeked.find((s) => s.id === peer.id)!;
    expect(peekedLead.members).toHaveLength(1);
    expect(peekedPeer.memberOf).toMatchObject({ machineId: "lead-machine" });
    expect((peekedPeer as any).pendingBrief).toBeUndefined();
  });

  it("clears a delivered brief durably and leaves the membership alone", async () => {
    const sm = makeManager(dir);
    const peer = await sm.create("Peer", { memberOf: lead, brief: "Own the backend." });
    await sm.clearPendingBrief(peer.id);
    expect(sm.pendingBriefFor(peer.id)).toBeUndefined();
    expect(persistedRows(dir)[0].pendingBrief).toBeUndefined();
    expect(persistedRows(dir)[0].memberOf.machineId).toBe("lead-machine");
    // Idempotent: the deliver-then-clear order can run this twice after a crash.
    await sm.clearPendingBrief(peer.id);
    expect(sm.pendingBriefFor(peer.id)).toBeUndefined();
  });
});

describe("session membership deletion (spec 5.4)", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-member-del-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  // Rows 1-3: the multi-machine session ends, the user removes the machine, or
  // the lead reports no such session. All three are an ordinary session delete
  // issued against the peer's own bridge.
  it("deletes a peer session and its membership with it", async () => {
    const sm = makeManager(dir);
    const peer = await sm.create("Peer", { memberOf: lead, brief: "Own the backend." });
    expect(await sm.delete(peer.id)).toBe(true);
    expect(sm.list()).toEqual([]);
    sm.flushNow();
    expect(persistedRows(dir)).toEqual([]);
    expect(sm.pendingBriefFor(peer.id)).toBeUndefined();
  });

  it("never refuses a lead's delete for holding members", async () => {
    const sm = makeManager(dir);
    const led = sm.create("Lead");
    await sm.recordMember(led.id, peerRef(1));
    expect(await sm.delete(led.id)).toBe(true);
    sm.flushNow();
    expect(persistedRows(dir)).toEqual([]);
  });

  // "Each delete is an ordinary session delete and inherits its refusals" — a
  // refused lead keeps its members, so the row the user comes back to still
  // says which machines were on it.
  it("keeps a refused lead's members recorded", async () => {
    const worktreeManager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p1", kind: "managed-worktree", path: join(dir, "wt"),
        branch: "antgrid/session-1", baseRef: "main", managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => {},
      recordFor: async () => ({ id: "checkout-1" } as CheckoutRecord),
      inspect: async () => ({ exists: true, registered: true, dirty: true, unpushedCommits: false, locked: false }),
      remove: async () => {},
    } as unknown as WorktreeManager;
    const sm = makeManager(dir, {
      worktreeSessionsSupported: true,
      isGitRepository: async () => true,
      worktreeManager,
      prepareCheckoutRuntime: async () => {},
      resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
    });
    const led = await sm.create("Lead", { isolation: "worktree" });
    await sm.recordMember(led.id, peerRef(1));
    const err = await Promise.resolve(sm.delete(led.id)).catch((e) => e);
    expect(err).toBeInstanceOf(WorktreeError);
    expect((err as WorktreeError).code).toBe("WORKTREE_DIRTY");
    expect(sm.membersOf(led.id)).toHaveLength(1);
    expect(sm.membersOf(led.id)[0]!.state).toBe("active");
  });
});
