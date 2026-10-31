// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, it, expect } from "bun:test";
import { BusQueue, BUS_REDELIVER_AFTER_MS, type BusQueueLimits } from "../src/bus-queue";

const EPK = "A".repeat(43) + "=";

function blob(boxChars = 100) {
  return { epk: EPK, box: "B".repeat(boxChars) };
}

function make(overrides: Partial<BusQueueLimits> = {}) {
  const clock = { t: 1_000_000 };
  const queue = new BusQueue({
    maxMessagesPerRecipient: 4,
    maxBytesPerRecipient: 10_000,
    maxMessagesPerSender: 8,
    maxBytesPerSender: 20_000,
    maxBytesTotal: 100_000,
    maxTtlMs: 60_000,
    now: () => clock.t,
    ...overrides,
  });
  return { queue, clock };
}

let n = 0;
const id = (): string => `id-${++n}`;

function put(queue: BusQueue, o: { uid?: string; from?: string; to?: string; id?: string; boxChars?: number; ttlMs?: number } = {}) {
  return queue.enqueue({
    uid: o.uid ?? "u1",
    from: o.from ?? "a",
    to: o.to ?? "b",
    id: o.id ?? id(),
    blob: blob(o.boxChars),
    ttlMs: o.ttlMs ?? 30_000,
  });
}

describe("BusQueue bounds", () => {
  it("bounds a recipient by message count", () => {
    const { queue } = make();
    for (let i = 0; i < 4; i++) expect(put(queue).result).toBe("queued");
    expect(put(queue).result).toBe("recipient-full");
    expect(put(queue, { to: "c" }).result).toBe("queued");
  });

  it("bounds a recipient by bytes", () => {
    const { queue } = make({ maxMessagesPerRecipient: 100 });
    expect(put(queue, { boxChars: 9_000 }).result).toBe("queued");
    expect(put(queue, { boxChars: 2_000 }).result).toBe("recipient-full");
  });

  it("bounds a sender by count and by bytes across recipients", () => {
    const { queue } = make({ maxMessagesPerSender: 3 });
    for (const to of ["b", "c", "d"]) expect(put(queue, { to }).result).toBe("queued");
    expect(put(queue, { to: "e" }).result).toBe("sender-full");
    expect(put(queue, { from: "other", to: "e" }).result).toBe("queued");

    const bytes = make({ maxBytesPerSender: 5_000, maxBytesPerRecipient: 100_000 });
    expect(put(bytes.queue, { to: "b", boxChars: 3_000 }).result).toBe("queued");
    expect(put(bytes.queue, { to: "c", boxChars: 3_000 }).result).toBe("sender-full");
  });

  it("bounds the whole queue", () => {
    const { queue } = make({ maxBytesTotal: 500 });
    expect(put(queue, { from: "a", to: "b", boxChars: 300 }).result).toBe("queued");
    expect(put(queue, { from: "c", to: "d", boxChars: 300 }).result).toBe("global-full");
  });

  it("frees capacity when an entry is acked", () => {
    const { queue } = make({ maxMessagesPerRecipient: 1 });
    const first = put(queue, { id: "m1" });
    expect(first.result).toBe("queued");
    expect(put(queue).result).toBe("recipient-full");
    queue.ack("u1", "b", "m1");
    expect(put(queue).result).toBe("queued");
    expect(queue.stats().messages).toBe(1);
  });
});

describe("BusQueue ttl", () => {
  it("clamps a sender TTL to the relay maximum and sweeps at expiry", () => {
    const { queue, clock } = make();
    const r = put(queue, { ttlMs: 10 * 60_000 });
    if (r.result !== "queued") throw new Error("expected queued");
    expect(r.entry.expiresAt).toBe(clock.t + 60_000);

    clock.t += 59_999;
    expect(queue.sweep()).toEqual([]);
    clock.t += 1;
    expect(queue.sweep().map((e) => e.id)).toEqual([r.entry.id]);
    expect(queue.stats()).toEqual({ messages: 0, bytes: 0 });
    expect(queue.pending("u1", "b")).toEqual([]);
  });

  it("a duplicate neither re-counts nor extends the expiry", () => {
    const { queue, clock } = make();
    const first = put(queue, { id: "dup", ttlMs: 10_000 });
    const before = queue.stats();
    clock.t += 5_000;
    const again = put(queue, { id: "dup", ttlMs: 50_000 });
    expect(again.result).toBe("duplicate");
    if (first.result !== "queued" || again.result !== "duplicate") throw new Error("unexpected");
    expect(again.entry).toBe(first.entry);
    expect(again.entry.expiresAt).toBe(first.entry.expiresAt);
    expect(queue.stats()).toEqual(before);
  });
});

describe("BusQueue ack", () => {
  it("is accepted only from the recipient", () => {
    const { queue } = make();
    put(queue, { id: "m", from: "a", to: "b" });
    expect(queue.ack("u1", "a", "m")).toBeNull();
    expect(queue.ack("u1", "c", "m")).toBeNull();
    expect(queue.ack("u1", "b", "m")?.from).toBe("a");
    expect(queue.ack("u1", "b", "m")).toBeNull();
  });

  it("keys by account, so a device id shared by two accounts never crosses", () => {
    const { queue } = make();
    put(queue, { uid: "u1", id: "m" });
    put(queue, { uid: "u2", id: "m" });
    expect(queue.stats().messages).toBe(2);
    expect(queue.pending("u1", "b")).toHaveLength(1);
    expect(queue.ack("u3", "b", "m")).toBeNull();
    expect(queue.ack("u2", "b", "m")?.uid).toBe("u2");
    expect(queue.pending("u1", "b")).toHaveLength(1);
  });
});

describe("BusQueue redelivery", () => {
  it("is due for a new connection immediately and for the same one after the interval", () => {
    const { queue, clock } = make();
    const r = put(queue);
    if (r.result !== "queued") throw new Error("expected queued");
    const entry = r.entry;

    expect(queue.redeliverable(entry, "c1", clock.t)).toBe(true);
    queue.markDelivered(entry, "c1", clock.t);
    expect(queue.redeliverable(entry, "c1", clock.t)).toBe(false);
    expect(queue.redeliverable(entry, "c1", clock.t + BUS_REDELIVER_AFTER_MS - 1)).toBe(false);
    expect(queue.redeliverable(entry, "c1", clock.t + BUS_REDELIVER_AFTER_MS)).toBe(true);
    expect(queue.redeliverable(entry, "c2", clock.t)).toBe(true);
  });
});

describe("BusQueue purge", () => {
  it("purgeDevice removes both directions and nothing else", () => {
    const { queue } = make();
    put(queue, { from: "a", to: "b" });
    put(queue, { from: "b", to: "c" });
    put(queue, { from: "c", to: "d" });
    put(queue, { uid: "u2", from: "a", to: "b" });
    queue.purgeDevice("u1", "b");
    expect(queue.pending("u1", "b")).toEqual([]);
    expect(queue.pending("u1", "c")).toEqual([]);
    expect(queue.pending("u1", "d")).toHaveLength(1);
    expect(queue.pending("u2", "b")).toHaveLength(1);
    expect(queue.stats().messages).toBe(2);
  });

  it("purgeDevice without an account clears every account's copy", () => {
    const { queue } = make();
    put(queue, { uid: "u1" });
    put(queue, { uid: "u2" });
    queue.purgeDevice(undefined, "b");
    expect(queue.stats()).toEqual({ messages: 0, bytes: 0 });
  });

  it("purgeUser removes one account and keeps the counters consistent", () => {
    const { queue } = make();
    put(queue, { uid: "u1" });
    put(queue, { uid: "u2" });
    queue.purgeUser("u1");
    expect(queue.stats().messages).toBe(1);
    for (let i = 0; i < 4; i++) expect(put(queue, { uid: "u1" }).result).toBe("queued");
    queue.clear();
    expect(queue.stats()).toEqual({ messages: 0, bytes: 0 });
  });
});
