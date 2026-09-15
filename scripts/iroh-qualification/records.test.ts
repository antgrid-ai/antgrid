import { describe, expect, test } from "bun:test";
import { MAX_FRAME_PAYLOAD } from "../../packages/antgrid-wire/src/index";
import { Records, type NativeStream } from "./records";

describe("Iroh record boundary", () => {
  test.each([0, 3, MAX_FRAME_PAYLOAD + 1, 0xffff_ffff])("rejects length %i before reading its body", async (length) => {
    const reads: number[] = [];
    const prefix = Buffer.alloc(4); prefix.writeUInt32BE(length);
    const records = new Records({ send: { writeAll: async () => {} }, recv: {
      readExact: async (size) => { reads.push(size); return [...prefix]; },
    } }, () => {});
    await expect(records.read()).rejects.toThrow("INVALID_RECORD_LENGTH");
    expect(reads).toEqual([4]);
  });

  test("consumes fragmented and coalesced records without losing boundaries", async () => {
    const wire = Buffer.from([0, 0, 0, 4, 1, 2, 3, 4, 0, 0, 0, 5, 5, 6, 7, 8, 9]);
    const chunks = [[...wire.subarray(0, 1)], [...wire.subarray(1, 7)], [...wire.subarray(7)]];
    const stream: NativeStream = { send: { writeAll: async () => {} }, recv: {
      readExact: async (size) => {
        const out: number[] = [];
        while (out.length < size && chunks.length) {
          out.push(...chunks[0]!.splice(0, size - out.length));
          if (!chunks[0]!.length) chunks.shift();
        }
        return out;
      },
    } };
    const records = new Records(stream, () => {});
    expect([...await records.read()]).toEqual([1, 2, 3, 4]);
    expect([...await records.read()]).toEqual([5, 6, 7, 8, 9]);
    await expect(records.read()).rejects.toThrow("TRUNCATED_RECORD");
  });

  test("queue overflow closes the generation and discards queued writes", async () => {
    const gate = Promise.withResolvers<void>();
    let writes = 0;
    const failures: unknown[] = [];
    const records = new Records({ recv: { readExact: async () => [] }, send: {
      writeAll: async () => { writes++; await gate.promise; },
    } }, (error) => failures.push(error));
    records.send(new Uint8Array(MAX_FRAME_PAYLOAD));
    await Promise.resolve();
    records.send(new Uint8Array(MAX_FRAME_PAYLOAD));
    expect(() => records.send(new Uint8Array(MAX_FRAME_PAYLOAD))).toThrow("SEND_QUEUE_FULL");
    expect(() => records.send(new Uint8Array(4))).toThrow("CONNECTION_LOST");
    gate.resolve(); await records.drained();
    expect(writes).toBe(1);
    expect(failures).toHaveLength(1);
  });

  test("a close fences an in-flight read before dispatch", async () => {
    const gate = Promise.withResolvers<number[]>();
    let calls = 0;
    const records = new Records({ send: { writeAll: async () => {} }, recv: {
      readExact: async () => ++calls === 1 ? [0, 0, 0, 4] : gate.promise,
    } }, () => {});
    const reading = records.read();
    await Promise.resolve(); records.close(); gate.resolve([1, 2, 3, 4]);
    await expect(reading).rejects.toThrow("CONNECTION_LOST");
    expect(records.received).toBe(0);
  });
});
