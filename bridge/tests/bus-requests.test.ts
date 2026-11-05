import { expect, test } from "bun:test";
import { AbMessageSchema, createMessage, type AbMessage } from "../src/protocol";
import { BusRequests } from "../src/session-bus/bus-requests";
import type { BusSendInput, BusSendResult } from "../src/session-bus/relay-transport";

const PEER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";

/** A clock and a scheduler the test advances by hand. */
function rig(sendResult: (i: BusSendInput, n: number) => BusSendResult = () => ({ sent: true })) {
  let t = 1_000_000;
  const timers: { at: number; fn: () => void; live: boolean }[] = [];
  const sent: BusSendInput[] = [];
  const requests = new BusRequests({
    transport: {
      send: (i) => {
        sent.push(i);
        return sendResult(i, sent.length);
      },
    },
    selfRole: () => "agent",
    now: () => t,
    schedule: (fn, ms) => {
      const e = { at: t + ms, fn, live: true };
      timers.push(e);
      return () => { e.live = false; };
    },
  });
  const advance = (ms: number) => {
    const to = t + ms;
    for (;;) {
      const next = timers.filter((x) => x.live && x.at <= to).sort((a, b) => a.at - b.at)[0];
      if (!next) break;
      next.live = false;
      t = Math.max(t, next.at);
      next.fn();
    }
    t = to;
  };
  return { requests, sent, advance, now: () => t };
}

const response = (requestId: string, over: Record<string, unknown> = {}): AbMessage =>
  createMessage("response", { requestId, ok: true, result: { hello: 1 }, ...over });

test("a response from the machine asked resolves the request, with the result", async () => {
  const { requests, sent } = rig();
  const p = requests.request({ to: PEER, method: "machine.capability-card", params: { a: 1 }, timeoutMs: 30_000 });
  const id = sent[0]!.id;
  expect(sent[0]).toMatchObject({ to: PEER, kind: "request", role: "agent" });
  expect(sent[0]!.body).toMatchObject({ type: "request", requestId: id, method: "machine.capability-card", params: { a: 1 } });

  expect(requests.onResponse(PEER, id, response(id))).toBe(true);
  expect(await p).toEqual({ ok: true, result: { hello: 1 } });
});

test("the request body is a well-formed message, so the responder's schema accepts it", () => {
  const { requests, sent } = rig();
  void requests.request({ to: PEER, method: "machine.capability-card", params: { includeSessions: true }, timeoutMs: 30_000 }).catch(() => {});
  expect(AbMessageSchema.safeParse(JSON.parse(JSON.stringify(sent[0]!.body))).success).toBe(true);
  requests.stop();
});

test("an error response resolves with its code", async () => {
  const { requests, sent } = rig();
  const p = requests.request({ to: PEER, method: "m", timeoutMs: 30_000 });
  const id = sent[0]!.id;
  requests.onResponse(PEER, id, response(id, { ok: false, result: undefined, error: { code: "NOT_ALLOWED", message: "x" } }));
  expect(await p).toEqual({ ok: false, code: "NOT_ALLOWED" });
});

test("a response from another machine with the same correlation id is ignored", async () => {
  const { requests, sent, advance } = rig();
  const p = requests.request({ to: PEER, method: "m", timeoutMs: 5_000 });
  const id = sent[0]!.id;

  expect(requests.onResponse(OTHER, id, response(id))).toBe(false);
  advance(5_000);
  expect(await p).toEqual({ ok: false, code: "REQUEST_TIMEOUT" });
});

test("a response for an id nobody asked is not matched", () => {
  const { requests } = rig();
  expect(requests.onResponse(PEER, "never-sent", response("never-sent"))).toBe(false);
});

test("a resend reuses the request id, on a one to eight second backoff", () => {
  const { requests, sent, advance } = rig();
  void requests.request({ to: PEER, method: "m", timeoutMs: 60_000 });
  expect(sent).toHaveLength(1);

  advance(1_000);
  expect(sent).toHaveLength(2);
  advance(2_000);
  expect(sent).toHaveLength(3);
  advance(4_000);
  expect(sent).toHaveLength(4);
  advance(8_000);
  advance(8_000);
  expect(sent).toHaveLength(6);

  expect(new Set(sent.map((s) => s.id)).size).toBe(1);
  // Every copy carries the same lifetime, never a fresh one.
  expect(new Set(sent.map((s) => `${s.sentAt}:${s.expiresAt}`)).size).toBe(1);
});

test("retryNow resends immediately for that machine only", () => {
  const { requests, sent } = rig();
  void requests.request({ to: PEER, method: "m", timeoutMs: 60_000 });
  void requests.request({ to: OTHER, method: "m", timeoutMs: 60_000 });
  expect(sent).toHaveLength(2);

  requests.retryNow(PEER);
  expect(sent).toHaveLength(3);
  expect(sent[2]!.to).toBe(PEER);
});

test("the deadline reports the last held reason the transport gave", async () => {
  const { requests, advance } = rig(() => ({ sent: false, reason: "central-offline" }));
  const p = requests.request({ to: PEER, method: "m", timeoutMs: 10_000 });
  advance(10_000);
  expect(await p).toEqual({ ok: false, code: "REQUEST_TIMEOUT", held: "central-offline" });
});

test("a held reason the relay reports through an outcome is the one reported", async () => {
  const { requests, sent, advance } = rig();
  const p = requests.request({ to: PEER, method: "m", timeoutMs: 10_000 });
  requests.onTransportOutcome(sent[0]!.id, PEER, { kind: "retry", reason: "relay-queue-full" });
  advance(10_000);
  expect(await p).toEqual({ ok: false, code: "REQUEST_TIMEOUT", held: "relay-queue-full" });
});

test("a send refused because remote access is off resolves at once", async () => {
  const { requests, sent } = rig(() => ({ sent: false, reason: "remote-access-off" }));
  const p = requests.request({ to: PEER, method: "m", timeoutMs: 300_000 });
  expect(await p).toEqual({ ok: false, code: "REMOTE_ACCESS_OFF" });
  expect(sent).toHaveLength(1);
});

test("a terminal refusal from the far side resolves with its code", async () => {
  const { requests, sent } = rig();
  const p = requests.request({ to: PEER, method: "m", timeoutMs: 30_000 });
  requests.onTransportOutcome(sent[0]!.id, PEER, { kind: "refused", code: "METHOD_NOT_ALLOWED" });
  expect(await p).toEqual({ ok: false, code: "METHOD_NOT_ALLOWED" });
});

test("a send the transport can never carry resolves with that code", async () => {
  const { requests } = rig(() => ({ sent: false, refused: "PLAINTEXT_TOO_LARGE" }));
  expect(await requests.request({ to: PEER, method: "m", timeoutMs: 30_000 })).toEqual({ ok: false, code: "PLAINTEXT_TOO_LARGE" });
});

test("stop rejects every waiter and stops resending", async () => {
  const { requests, sent, advance } = rig();
  const p = requests.request({ to: PEER, method: "m", timeoutMs: 60_000 });
  requests.stop();
  await expect(p).rejects.toThrow("stopped");
  advance(30_000);
  expect(sent).toHaveLength(1);
  await expect(requests.request({ to: PEER, method: "m", timeoutMs: 1_000 })).rejects.toThrow("stopped");
});

test("respond sends a response correlated to the request and resends until acknowledged", () => {
  const { requests, sent, advance, now } = rig();
  const body = response("req-1");
  requests.respond(PEER, "req-1", body, now() + 60_000);
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({ to: PEER, kind: "response", correlationId: "req-1", body });
  const frameId = sent[0]!.id;
  expect(frameId).not.toBe("req-1");

  advance(2_000);
  expect(sent).toHaveLength(2);
  expect(sent[1]!.id).toBe(frameId);

  requests.onTransportOutcome(frameId, PEER, { kind: "applied" });
  advance(30_000);
  expect(sent).toHaveLength(2);
});

test("respond stops at the request's own expiry, and while remote access is off", () => {
  const a = rig();
  a.requests.respond(PEER, "req-1", response("req-1"), a.now() + 3_000);
  a.advance(60_000);
  expect(a.sent).toHaveLength(2);

  const b = rig((_i, n) => (n === 1 ? { sent: true } : { sent: false, reason: "remote-access-off" }));
  b.requests.respond(PEER, "req-1", response("req-1"), b.now() + 60_000);
  b.advance(60_000);
  expect(b.sent).toHaveLength(2);
});

test("a duplicate respond for the same request does not start a second retry loop", () => {
  const { requests, sent, advance, now } = rig();
  requests.respond(PEER, "req-1", response("req-1"), now() + 60_000);
  requests.respond(PEER, "req-1", response("req-1"), now() + 60_000);
  expect(sent).toHaveLength(2);
  expect(sent[0]!.id).toBe(sent[1]!.id);

  advance(2_000);
  expect(sent).toHaveLength(3);
});

test("a response the transport cannot seal is replaced by a short RESPONSE_TOO_LARGE for the same request", () => {
  const { requests, sent } = rig((i) => (i.kind === "response" && (i.body as { ok?: boolean }).ok === true
    ? { sent: false, refused: "PLAINTEXT_TOO_LARGE" }
    : { sent: true }));
  requests.respond(PEER, "req-1", response("req-body-1"), 2_000_000);
  expect(sent).toHaveLength(2);
  expect(sent[1]!.body).toMatchObject({ type: "response", requestId: "req-body-1", ok: false, error: { code: "RESPONSE_TOO_LARGE" } });
  expect(sent[1]).toMatchObject({ to: PEER, kind: "response", correlationId: "req-1" });
});
