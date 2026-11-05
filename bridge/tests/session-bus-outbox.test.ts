// The sender's side of at-least-once delivery: a message to another machine is
// kept until that machine's signed acknowledgement arrives, and every rung it
// climbs is something the sender can read. The transport is a fake here, so each
// case chooses exactly what the relay would have said.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setLogLevel } from "../src/logger";
import type { AbMessage, SessionMemberRef } from "../src/protocol";
import {
  BUS_RELAYED_RESEND_MS,
  BUS_RETRY_BASE_MS,
  BUS_RETRY_MAX_MS,
  MAX_HELD_MESSAGES,
} from "../src/session-bus/constants";
import { SessionBusCoordinator, type SessionBusSend } from "../src/session-bus/coordinator";
import { HELD_MESSAGE_TTL_MS, loadHeld } from "../src/session-bus/held-store";
import type { BusSendResult } from "../src/session-bus/relay-transport";

setLogLevel("error");

const SELF = { machineId: "m-self", projectId: "p-self", sessionId: "s-self" };
const REMOTE: SessionMemberRef = { machineId: "m-remote", projectId: "p-remote", sessionId: "s-remote" };
const REMOTE_TWO: SessionMemberRef = { machineId: "m-remote-2", projectId: "p-remote", sessionId: "s-remote-2" };
const SIBLING: SessionMemberRef = { machineId: "m-self", projectId: "p-self", sessionId: "s-sibling" };

let abDir: string;
let now: number;
let ids: number;
let sends: { id: string; to: string }[];
let answer: (to: string) => BusSendResult;
let coordinators: SessionBusCoordinator[];

beforeEach(() => {
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-outbox-"));
  now = 1_000_000;
  ids = 0;
  sends = [];
  answer = () => ({ sent: true });
  coordinators = [];
});

afterEach(() => {
  for (const c of coordinators) c.stop();
  try { rmSync(abDir, { recursive: true, force: true }); } catch { /* Windows handle */ }
});

function build(over: { send?: SessionBusSend; deliverLocal?: (frame: AbMessage) => boolean } = {}): SessionBusCoordinator {
  const c = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => "p-self",
    self: (sessionId) => sessionId === SELF.sessionId
      ? { key: SELF, ref: SELF }
      : null,
    send: over.send ?? ((_frame, ctx) => {
      sends.push({ id: ctx.messageId, to: ctx.to.machineId });
      return answer(ctx.to.machineId);
    }),
    ...(over.deliverLocal ? { deliverLocal: over.deliverLocal } : {}),
    now: () => now,
    newId: () => `id-${++ids}`,
  });
  coordinators.push(c);
  return c;
}

function post(c: SessionBusCoordinator, to: SessionMemberRef = REMOTE, text = "hello") {
  const res = c.message({
    sessionId: SELF.sessionId, verb: "post", threadId: null, to, summary: text, parts: [{ kind: "text", text }],
  });
  if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
  return res;
}

const outEntry = (c: SessionBusCoordinator, messageId: string) =>
  c.messages(SELF.sessionId).entries.find((e) => e.direction === "out" && e.envelope.messageId === messageId);
const heldIds = () => loadHeld(abDir, "p-self", SELF.sessionId).held.map((m) => m.messageId);

test("an off-machine send stays held after the transport accepts it, until the recipient acknowledges", () => {
  const c = build();
  const res = post(c);
  expect(res.rung).toBe("held");
  expect(res.sent).toBe(false);
  expect(res.held).toBe(true);
  expect(sends).toHaveLength(1);
  // Accepted by the transport is not arrived: the entry is still in the outbox.
  expect(heldIds()).toEqual([res.messageId]);

  c.onTransportOutcome(res.messageId, REMOTE.machineId, { kind: "applied" });
  expect(heldIds()).toEqual([]);
  expect(outEntry(c, res.messageId)?.deliveredAt).toBe(now);
});

test("a relay receipt stops the per-tick resend, and the next attempt waits for the slow interval", () => {
  const c = build();
  const res = post(c);
  c.onTransportOutcome(res.messageId, REMOTE.machineId, { kind: "relayed" });
  expect(outEntry(c, res.messageId)?.relayedAt).toBe(now);

  now += BUS_RETRY_MAX_MS * 2;
  c.pump();
  expect(sends).toHaveLength(1);

  now += BUS_RELAYED_RESEND_MS;
  c.pump();
  expect(sends).toHaveLength(2);
  // Still held: the receipt only says the relay has it.
  expect(heldIds()).toEqual([res.messageId]);
});

test("a retry keeps the entry and backs off between attempts", () => {
  answer = () => ({ sent: false, reason: "central-offline" });
  const c = build();
  const res = post(c);
  expect(res).toMatchObject({ rung: "held", heldReason: "central-offline", retryUntil: now + HELD_MESSAGE_TTL_MS });
  expect(res.local).toBeUndefined();
  expect(sends).toHaveLength(1);

  // Not due before the base interval.
  now += BUS_RETRY_BASE_MS - 1;
  c.pump();
  expect(sends).toHaveLength(1);

  now += 1;
  c.pump();
  expect(sends).toHaveLength(2);

  // The second failure doubles the wait.
  now += BUS_RETRY_BASE_MS;
  c.pump();
  expect(sends).toHaveLength(2);
  now += BUS_RETRY_BASE_MS;
  c.pump();
  expect(sends).toHaveLength(3);

  c.onTransportOutcome(res.messageId, REMOTE.machineId, { kind: "retry", reason: "relay-queue-full" });
  expect(heldIds()).toEqual([res.messageId]);
  expect(c.awaitRung(res.messageId, 0)).resolves.toMatchObject({ rung: "held", heldReason: "relay-queue-full" });
});

test("the backoff is capped", () => {
  answer = () => ({ sent: false, reason: "no-transport" });
  const c = build();
  post(c);
  for (let i = 0; i < 12; i++) {
    now += BUS_RETRY_MAX_MS;
    c.pump();
  }
  const before = sends.length;
  now += BUS_RETRY_MAX_MS;
  c.pump();
  expect(sends.length).toBe(before + 1);
});

test("a terminal refusal stamps its code on the entry and releases the message", async () => {
  const c = build();
  const res = post(c);
  c.onTransportOutcome(res.messageId, REMOTE.machineId, { kind: "refused", code: "UNKNOWN_PEER" });
  expect(heldIds()).toEqual([]);
  expect(outEntry(c, res.messageId)).toMatchObject({ refusedCode: "UNKNOWN_PEER" });
  expect(outEntry(c, res.messageId)?.deliveredAt).toBeUndefined();
  expect(await c.awaitRung(res.messageId, 0)).toEqual({ rung: "refused", refusedCode: "UNKNOWN_PEER" });

  now += BUS_RETRY_MAX_MS * 2;
  c.pump();
  expect(sends).toHaveLength(1);
});

test("a send the transport refuses outright is reported refused and never held", () => {
  answer = () => ({ sent: false, refused: "PLAINTEXT_TOO_LARGE" });
  const c = build();
  const res = post(c);
  expect(res).toMatchObject({ rung: "refused", refusedCode: "PLAINTEXT_TOO_LARGE", sent: true, held: false });
  expect(heldIds()).toEqual([]);
});

test("an outcome for an id this machine never sent, or naming another recipient, is ignored", () => {
  const c = build();
  const res = post(c);
  c.onTransportOutcome("never-sent", REMOTE.machineId, { kind: "applied" });
  c.onTransportOutcome(res.messageId, "m-other", { kind: "applied" });
  expect(heldIds()).toEqual([res.messageId]);
  expect(outEntry(c, res.messageId)?.deliveredAt).toBeUndefined();
});

test("the thirty-third unacknowledged message pushes the oldest out, stamped OUTBOX_FULL", () => {
  const c = build();
  const first = post(c, REMOTE, "m-0");
  for (let i = 1; i <= MAX_HELD_MESSAGES; i++) post(c, REMOTE, `m-${i}`);

  expect(heldIds()).toHaveLength(MAX_HELD_MESSAGES);
  expect(heldIds()).not.toContain(first.messageId);
  expect(outEntry(c, first.messageId)).toMatchObject({ refusedCode: "OUTBOX_FULL" });
});

test("a message nobody acknowledged expires, stamped EXPIRED, and is not offered again", async () => {
  const c = build();
  const res = post(c);
  now += HELD_MESSAGE_TTL_MS;
  c.pump();
  expect(heldIds()).toEqual([]);
  expect(outEntry(c, res.messageId)).toMatchObject({ refusedCode: "EXPIRED" });
  expect(await c.awaitRung(res.messageId, 0)).toMatchObject({ rung: "refused", refusedCode: "EXPIRED" });
  expect(sends).toHaveLength(1);
});

test("retryNow makes the named machine's entries due and leaves the others on their schedule", () => {
  answer = () => ({ sent: false, reason: "central-offline" });
  const c = build();
  const toOne = post(c, REMOTE, "one");
  const toTwo = post(c, REMOTE_TWO, "two");
  sends.length = 0;

  c.retryNow({ machineId: REMOTE.machineId });
  expect(sends.map((s) => s.id)).toEqual([toOne.messageId]);

  sends.length = 0;
  c.retryNow();
  expect(sends.map((s) => s.id).sort()).toEqual([toOne.messageId, toTwo.messageId].sort());
});

test("retryNow re-offers a relayed entry, because the relay may have lost its queue", () => {
  const c = build();
  const res = post(c);
  c.onTransportOutcome(res.messageId, REMOTE.machineId, { kind: "relayed" });
  sends.length = 0;
  c.retryNow({ machineId: REMOTE.machineId });
  expect(sends.map((s) => s.id)).toEqual([res.messageId]);
});

test("a failing recipient does not let its later messages overtake the earlier one", () => {
  const order: string[] = [];
  let up = false;
  const c = build({
    send: (_frame, ctx) => {
      if (!up) return { sent: false, reason: "no-transport" };
      order.push(ctx.messageId);
      return { sent: true };
    },
  });
  const a = post(c, REMOTE, "a");
  const b = post(c, REMOTE, "b");
  up = true;
  now += BUS_RETRY_BASE_MS;
  c.pump();
  expect(order).toEqual([a.messageId, b.messageId]);
});

test("awaitRung resolves as soon as a rung above held is reached, and otherwise at its own bound", async () => {
  const c = build();
  const res = post(c);

  const quick = c.awaitRung(res.messageId, 5_000);
  c.onTransportOutcome(res.messageId, REMOTE.machineId, { kind: "relayed" });
  expect(await quick).toEqual({ rung: "relayed" });

  const slow = post(c, REMOTE, "slow");
  const started = Date.now();
  const stuck = await c.awaitRung(slow.messageId, 60);
  expect(stuck.rung).toBe("held");
  expect(Date.now() - started).toBeGreaterThanOrEqual(50);
});

test("a same-machine send is stamped delivered by the local write, with no acknowledgement", () => {
  const delivered: AbMessage[] = [];
  const c = build({ deliverLocal: (frame) => { delivered.push(frame); return true; } });
  const res = post(c, SIBLING);
  expect(res).toMatchObject({ rung: "delivered", sent: true, held: false });
  expect(delivered).toHaveLength(1);
  expect(sends).toHaveLength(0);
  expect(heldIds()).toEqual([]);
  expect(outEntry(c, res.messageId)?.deliveredAt).toBe(now);
});

test("after a restart, resume rebuilds the outbox so a late acknowledgement still lands", () => {
  const first = build();
  const res = post(first);
  expect(heldIds()).toEqual([res.messageId]);
  first.stop();

  const second = build();
  second.resume();
  second.onTransportOutcome(res.messageId, REMOTE.machineId, { kind: "applied" });
  expect(heldIds()).toEqual([]);
  expect(outEntry(second, res.messageId)?.deliveredAt).toBe(now);
});
