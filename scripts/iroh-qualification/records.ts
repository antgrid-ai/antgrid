import { MAX_FRAME_PAYLOAD, SOCKET_INFLIGHT_BYTES } from "../../packages/antgrid-wire/src/index";

export interface NativeStream {
  send: { writeAll(bytes: number[]): Promise<void> };
  recv: { readExact(length: number): Promise<number[]> };
}

export class Records {
  private tail = Promise.resolve();
  private queued = 0;
  private stopped = false;
  sent = 0;
  received = 0;
  peakQueuedBytes = 0;

  constructor(private readonly stream: NativeStream, private readonly fail: (error: unknown) => void) {}

  send(frame: Uint8Array): void {
    if (this.stopped) throw new Error("CONNECTION_LOST");
    if (frame.length < 4 || frame.length > MAX_FRAME_PAYLOAD) throw new Error("INVALID_RECORD_LENGTH");
    if (this.queued + frame.length + 4 > SOCKET_INFLIGHT_BYTES) {
      this.close();
      this.fail(new Error("SEND_QUEUE_FULL"));
      throw new Error("SEND_QUEUE_FULL");
    }
    const record = Buffer.alloc(frame.length + 4);
    record.writeUInt32BE(frame.length);
    record.set(frame, 4);
    this.queued += record.length;
    this.peakQueuedBytes = Math.max(this.peakQueuedBytes, this.queued);
    this.tail = this.tail.then(async () => {
      try {
        if (this.stopped) return;
        await this.stream.send.writeAll(Array.from(record));
        this.sent++;
      } finally {
        this.queued -= record.length;
      }
    }).catch((error) => {
      this.close();
      this.fail(error);
    });
  }

  async read(): Promise<Uint8Array> {
    if (this.stopped) throw new Error("CONNECTION_LOST");
    const prefix = Buffer.from(await this.stream.recv.readExact(4));
    if (prefix.length !== 4) throw new Error("TRUNCATED_RECORD");
    const length = prefix.readUInt32BE();
    if (length < 4 || length > MAX_FRAME_PAYLOAD) throw new Error("INVALID_RECORD_LENGTH");
    const frame = Uint8Array.from(await this.stream.recv.readExact(length));
    if (frame.length !== length) throw new Error("TRUNCATED_RECORD");
    if (this.stopped) throw new Error("CONNECTION_LOST");
    this.received++;
    return frame;
  }

  close(): void { this.stopped = true; }
  async drained(): Promise<void> { await this.tail; }
}
