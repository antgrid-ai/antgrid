import { expect, test } from "bun:test";
import { PEER_MAX_RECORD_BYTES } from "antgrid-wire";
import { PeerRecords } from "../src/peer/records";

test("invalid prefix is refused before allocating or requesting a body", async () => {
  const reads: number[] = [];
  const failures: string[] = [];
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(PEER_MAX_RECORD_BYTES + 1);
  const records = new PeerRecords({ send: { writeAll: async () => {} }, recv: {
    readExact: async (size) => { reads.push(size); return Array.from(prefix); },
  } }, () => true, (reason) => failures.push(reason));
  await expect(records.read()).rejects.toThrow("protocol-violation");
  expect(reads).toEqual([4]);
  expect(failures).toEqual(["protocol-violation"]);
});

test("a stalled native writer has a bounded outcome and closes the owner", async () => {
  const failures: string[] = [];
  const records = new PeerRecords({ send: { writeAll: () => new Promise(() => {}) },
    recv: { readExact: async () => [] } }, () => true, (reason) => failures.push(reason), 100, 5);
  expect(await records.send(new Uint8Array(4))).toBe("dropped");
  expect(failures).toEqual(["connection-lost"]);
});

test("revocation settles queued and active writes without waiting for native completion", async () => {
  const writing = Promise.withResolvers<void>();
  const writes: number[][] = [];
  const records = new PeerRecords({ send: { writeAll: async (bytes) => { writes.push(bytes); await writing.promise; } },
    recv: { readExact: async () => [] } }, () => true, () => {});
  const first = records.send(new Uint8Array([1, 2, 3, 4]));
  const second = records.send(new Uint8Array([5, 6, 7, 8]));
  records.close("unauthorized");
  expect(await first).toBe("dropped");
  expect(await second).toBe("dropped");
  writing.resolve();
  await Promise.resolve();
  expect(writes).toHaveLength(1);
});

test("authorization is rechecked when a queued record reaches the native writer", async () => {
  let allowed = true;
  const writing = Promise.withResolvers<void>();
  let calls = 0;
  const records = new PeerRecords({ send: { writeAll: async () => { calls++; await writing.promise; } },
    recv: { readExact: async () => [] } }, () => allowed, () => {});
  const first = records.send(new Uint8Array(4));
  const second = records.send(new Uint8Array(4));
  allowed = false;
  writing.resolve();
  await first;
  expect(await second).toBe("dropped");
  expect(calls).toBe(1);
});

test("a retired E2E generation cancels its queued native record without closing a healthy peer", async () => {
  let current = true;
  const writing = Promise.withResolvers<void>();
  let calls = 0;
  const failures: string[] = [];
  const records = new PeerRecords({ send: { writeAll: async () => { calls++; await writing.promise; } },
    recv: { readExact: async () => [] } }, () => true, (reason) => failures.push(reason));
  const first = records.send(new Uint8Array(4));
  const retired = records.send(new Uint8Array(4), () => current);
  current = false;
  writing.resolve();
  expect(await first).toBe("sent");
  expect(await retired).toBe("dropped");
  expect(calls).toBe(1);
  expect(failures).toEqual([]);
  records.close();
});
