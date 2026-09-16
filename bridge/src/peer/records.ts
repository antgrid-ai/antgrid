import { PEER_MAX_RECORD_BYTES, SOCKET_INFLIGHT_BYTES } from "antgrid-wire";
import type { SendOutcome } from "../send-scheduler";

export interface NativeRecordStream {
  send: { writeAll(bytes: number[]): Promise<void> };
  recv: { readExact(length: number): Promise<number[]> };
}

export type PeerRecordFailure = "connection-lost" | "protocol-violation" | "queue-full" | "unauthorized";

interface PendingRecord {
  bytes: Buffer;
  settle: (outcome: SendOutcome) => void;
  permitted?: () => boolean;
}

/** The native binding has no observable write buffer; bound retained records here. */
export class PeerRecords {
  private readonly queue: PendingRecord[] = [];
  private readonly pending = new Set<PendingRecord>();
  private writing = false;
  private stopped = false;
  private queuedBytes = 0;

  constructor(
    private readonly stream: NativeRecordStream,
    private readonly authorized: () => boolean,
    private readonly onFailure: (reason: PeerRecordFailure) => void,
    private readonly maxQueuedBytes = SOCKET_INFLIGHT_BYTES,
    private readonly writeTimeoutMs = 5_000,
  ) {}

  send(frame: Uint8Array, permitted?: () => boolean): Promise<SendOutcome> {
    if (this.stopped) return Promise.resolve("dropped");
    if (permitted?.() === false) return Promise.resolve("dropped");
    if (!this.authorized()) {
      this.close("unauthorized");
      return Promise.resolve("dropped");
    }
    if (frame.length < 4 || frame.length > PEER_MAX_RECORD_BYTES) return Promise.resolve("too-large");
    if (this.queuedBytes + frame.length + 4 > this.maxQueuedBytes) {
      this.close("queue-full");
      return Promise.resolve("dropped");
    }
    const bytes = Buffer.allocUnsafe(frame.length + 4);
    bytes.writeUInt32BE(frame.length);
    bytes.set(frame, 4);
    return new Promise((settle) => {
      const record = { bytes, settle, permitted };
      this.queue.push(record);
      this.pending.add(record);
      this.queuedBytes += bytes.length;
      void this.drain();
    });
  }

  private async drain(): Promise<void> {
    if (this.writing) return;
    this.writing = true;
    try {
      while (!this.stopped && this.queue.length) {
        if (!this.authorized()) { this.close("unauthorized"); return; }
        const record = this.queue.shift()!;
        if (record.permitted?.() === false) {
          this.pending.delete(record);
          this.queuedBytes -= record.bytes.length;
          record.bytes.fill(0);
          record.settle("dropped");
          continue;
        }
        let timeout: ReturnType<typeof setTimeout> | undefined;
        try {
          await Promise.race([this.stream.send.writeAll(Array.from(record.bytes)), new Promise<never>((_, reject) => {
            timeout = setTimeout(() => reject(new Error("Native write timed out")), this.writeTimeoutMs);
          })]);
        } finally { if (timeout) clearTimeout(timeout); }
        if (this.stopped) return;
        this.checkAdmission();
        this.pending.delete(record);
        this.queuedBytes -= record.bytes.length;
        record.bytes.fill(0);
        record.settle("sent");
      }
    } catch {
      this.close("connection-lost");
    } finally {
      this.writing = false;
    }
  }

  async read(): Promise<Uint8Array> {
    try {
      this.checkAdmission();
      const prefix = Buffer.from(await this.stream.recv.readExact(4));
      this.checkAdmission();
      if (prefix.length !== 4) throw new Error("protocol-violation");
      const length = prefix.readUInt32BE();
      if (length < 4 || length > PEER_MAX_RECORD_BYTES) throw new Error("protocol-violation");
      const result = Uint8Array.from(await this.stream.recv.readExact(length));
      this.checkAdmission();
      if (result.length !== length) throw new Error("protocol-violation");
      return result;
    } catch (error) {
      const reason = error instanceof Error && error.message === "protocol-violation"
        ? "protocol-violation" : "connection-lost";
      this.close(reason);
      throw error;
    }
  }

  private checkAdmission(): void {
    if (this.stopped) throw new Error("connection-lost");
    if (!this.authorized()) {
      this.close("unauthorized");
      throw new Error("unauthorized");
    }
  }

  close(reason: PeerRecordFailure = "connection-lost"): void {
    if (this.stopped) return;
    this.stopped = true;
    for (const record of this.pending) {
      record.bytes.fill(0);
      record.settle("dropped");
    }
    this.pending.clear();
    this.queue.length = 0;
    this.queuedBytes = 0;
    // The owner must also close the native connection, canceling its active write.
    this.onFailure(reason);
  }
}
