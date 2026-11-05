// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { BusBlob } from "antgrid-wire";

/**
 * How long an unacked entry may sit on one socket before the relay hands it to
 * that recipient again. The recipient acks over the same JSON bucket as every
 * other control frame, which can drop the ack; redelivery lets the recipient's
 * own dedup re-ack instead of leaving the sender to expire a message that was
 * applied.
 */
export const BUS_REDELIVER_AFTER_MS = 60_000;

export interface BusQueueLimits {
  maxMessagesPerRecipient: number;
  maxBytesPerRecipient: number;
  maxMessagesPerSender: number;
  maxBytesPerSender: number;
  maxBytesTotal: number;
  maxTtlMs: number;
  now: () => number;
}

export interface BusEntry {
  uid: string;
  from: string;
  to: string;
  id: string;
  blob: BusBlob;
  /** epk + box characters: the only part of a blob whose size the sender controls. */
  bytes: number;
  expiresAt: number;
  deliveredConn: string | null;
  deliveredAt: number | null;
}

export type EnqueueResult =
  | { result: "queued" | "duplicate"; entry: BusEntry }
  | { result: "recipient-full" | "sender-full" | "global-full" };

interface Tally {
  count: number;
  bytes: number;
}

// Account id first because a deviceId is unique per account, not globally.
const NUL = "\0";
const recipientKey = (uid: string, to: string): string => uid + NUL + to;
const senderKey = (uid: string, from: string): string => uid + NUL + from;
const entryKey = (uid: string, from: string, to: string, id: string): string =>
  uid + NUL + from + NUL + to + NUL + id;

/**
 * Holds sealed bus blobs for agents that are offline or have not acked. The
 * relay cannot open a blob, so every bound here is on size and count: a
 * recipient is bounded so a sleeping machine cannot pin memory, a sender is
 * bounded because the relay has no account roster to tell a real recipient from
 * a made-up one, and the total bounds the process. An entry leaves on the
 * recipient's ack, its TTL, or a revoke/expire purge; nothing is persisted.
 */
export class BusQueue {
  private readonly byRecipient = new Map<string, BusEntry[]>();
  private readonly byKey = new Map<string, BusEntry>();
  private readonly recipientTally = new Map<string, Tally>();
  private readonly senderTally = new Map<string, Tally>();
  private totalBytes = 0;

  constructor(private readonly limits: BusQueueLimits) {}

  enqueue(input: {
    uid: string;
    from: string;
    to: string;
    id: string;
    blob: BusBlob;
    ttlMs: number;
  }): EnqueueResult {
    const { uid, from, to, id, blob } = input;
    const existing = this.byKey.get(entryKey(uid, from, to, id));
    // A resend must not re-count or push the expiry out, or a sender could keep
    // an entry alive forever by resending it.
    if (existing) return { result: "duplicate", entry: existing };

    const bytes = blob.epk.length + blob.box.length;
    const rKey = recipientKey(uid, to);
    const sKey = senderKey(uid, from);
    const r = this.recipientTally.get(rKey);
    if (
      (r?.count ?? 0) + 1 > this.limits.maxMessagesPerRecipient ||
      (r?.bytes ?? 0) + bytes > this.limits.maxBytesPerRecipient
    ) {
      return { result: "recipient-full" };
    }
    const s = this.senderTally.get(sKey);
    if (
      (s?.count ?? 0) + 1 > this.limits.maxMessagesPerSender ||
      (s?.bytes ?? 0) + bytes > this.limits.maxBytesPerSender
    ) {
      return { result: "sender-full" };
    }
    if (this.totalBytes + bytes > this.limits.maxBytesTotal) return { result: "global-full" };

    const entry: BusEntry = {
      uid,
      from,
      to,
      id,
      blob,
      bytes,
      expiresAt: this.limits.now() + Math.min(input.ttlMs, this.limits.maxTtlMs),
      deliveredConn: null,
      deliveredAt: null,
    };
    let list = this.byRecipient.get(rKey);
    if (!list) {
      list = [];
      this.byRecipient.set(rKey, list);
    }
    list.push(entry);
    this.byKey.set(entryKey(uid, from, to, id), entry);
    this.bump(this.recipientTally, rKey, 1, bytes);
    this.bump(this.senderTally, sKey, 1, bytes);
    this.totalBytes += bytes;
    return { result: "queued", entry };
  }

  /** Oldest first; per-(from,to) order is the order the sender's frames arrived. */
  pending(uid: string, to: string): readonly BusEntry[] {
    return this.byRecipient.get(recipientKey(uid, to)) ?? [];
  }

  markDelivered(entry: BusEntry, connectionId: string, now: number): void {
    entry.deliveredConn = connectionId;
    entry.deliveredAt = now;
  }

  redeliverable(entry: BusEntry, liveConnectionId: string, now: number): boolean {
    if (entry.deliveredConn !== liveConnectionId || entry.deliveredAt === null) return true;
    return now - entry.deliveredAt >= BUS_REDELIVER_AFTER_MS;
  }

  /**
   * Looked up only among the acker's own entries, so no other device (even in
   * the same account) can clear a message addressed to someone else.
   */
  ack(uid: string, ackerDeviceId: string, id: string): BusEntry | null {
    const entry = this.pending(uid, ackerDeviceId).find((e) => e.id === id);
    if (!entry) return null;
    this.remove(entry);
    return entry;
  }

  sweep(): BusEntry[] {
    const now = this.limits.now();
    const expired: BusEntry[] = [];
    for (const entry of this.byKey.values()) {
      if (entry.expiresAt <= now) expired.push(entry);
    }
    for (const entry of expired) this.remove(entry);
    return expired;
  }

  /** Both directions: mail to the device and mail it sent. A missing uid purges every account that holds the id. */
  purgeDevice(uid: string | undefined, deviceId: string): void {
    this.removeWhere((e) => (uid === undefined || e.uid === uid) && (e.to === deviceId || e.from === deviceId));
  }

  purgeUser(uid: string): void {
    this.removeWhere((e) => e.uid === uid);
  }

  stats(): { messages: number; bytes: number } {
    return { messages: this.byKey.size, bytes: this.totalBytes };
  }

  clear(): void {
    this.byRecipient.clear();
    this.byKey.clear();
    this.recipientTally.clear();
    this.senderTally.clear();
    this.totalBytes = 0;
  }

  private removeWhere(match: (entry: BusEntry) => boolean): void {
    const doomed: BusEntry[] = [];
    for (const entry of this.byKey.values()) {
      if (match(entry)) doomed.push(entry);
    }
    for (const entry of doomed) this.remove(entry);
  }

  private remove(entry: BusEntry): void {
    const rKey = recipientKey(entry.uid, entry.to);
    const list = this.byRecipient.get(rKey);
    if (list) {
      const i = list.indexOf(entry);
      if (i >= 0) list.splice(i, 1);
      if (list.length === 0) this.byRecipient.delete(rKey);
    }
    if (!this.byKey.delete(entryKey(entry.uid, entry.from, entry.to, entry.id))) return;
    this.bump(this.recipientTally, rKey, -1, -entry.bytes);
    this.bump(this.senderTally, senderKey(entry.uid, entry.from), -1, -entry.bytes);
    this.totalBytes -= entry.bytes;
  }

  private bump(map: Map<string, Tally>, key: string, count: number, bytes: number): void {
    const tally = map.get(key) ?? { count: 0, bytes: 0 };
    tally.count += count;
    tally.bytes += bytes;
    if (tally.count <= 0) map.delete(key);
    else map.set(key, tally);
  }
}
