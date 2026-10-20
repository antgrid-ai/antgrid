import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, open, type FileHandle } from "node:fs/promises";
import { resolve, sep } from "node:path";
import {
  HANDOFF_FILE_NAME,
  HandoffSnapshotError,
  MAX_HANDOFF_SNAPSHOT_BYTES,
  type HandoffFile,
} from "./types";

// Every adapter writes through these helpers and nothing else. They stream, so a
// multi-hundred-MB transcript never sits in one buffer and nothing hashes or
// decompresses synchronously on the bridge loop, which also forwards every PTY
// and relay frame.

const READ_CHUNK = 256 * 1024;
const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/;
const LOCK_CODES = new Set(["EBUSY", "EPERM", "EACCES"]);

/** One counter shared across a snapshot. `signal` rides along so that every
 * chunk written is also a deadline check, without threading a signal through
 * each helper. */
export class ByteBudget {
  private written = 0;
  constructor(private readonly max = MAX_HANDOFF_SNAPSHOT_BYTES, private readonly signal?: AbortSignal) {}

  /** Throws when the deadline passed; called on the read side as well. */
  check(): void {
    if (this.signal?.aborted) throw new HandoffSnapshotError("UNREADABLE", "The handoff snapshot ran past its deadline.");
  }

  take(n: number): void {
    this.check();
    this.written += n;
    if (this.written > this.max) {
      throw new HandoffSnapshotError("TOO_LARGE", `The snapshot exceeds ${this.max} bytes.`);
    }
  }

  get total(): number {
    return this.written;
  }
}

/** A rollout that can be re-read from the start, plain or zstd. */
export interface RolloutSource {
  path: string;
  compressed: boolean;
  /** Decompressed bytes, restarting from offset 0 on each call. */
  open(): AsyncIterable<Uint8Array>;
}

function unreadable(error: unknown, what: string, kind: "UNREADABLE" | "WRITE" = "UNREADABLE"): HandoffSnapshotError {
  if (error instanceof HandoffSnapshotError) return error;
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  const detail = error instanceof Error ? error.message : String(error);
  return new HandoffSnapshotError(kind, `${what}${code ? ` (${code})` : ""}: ${detail}`, code);
}

/** One retry for a Windows share lock (an agent mid-write, an AV scan), then UNREADABLE. */
async function retryLocked<T>(what: string, run: () => Promise<T>, kind: "UNREADABLE" | "WRITE" = "UNREADABLE"): Promise<T> {
  try {
    return await run();
  } catch (error) {
    const code = (error as NodeJS.ErrnoException | undefined)?.code;
    if (code === undefined || !LOCK_CODES.has(code)) throw unreadable(error, what, kind);
  }
  await Bun.sleep(50);
  try {
    return await run();
  } catch (error) {
    throw unreadable(error, what, kind);
  }
}

export function safeJoin(outDir: string, name: string): string {
  const stem = name.split(".")[0] ?? "";
  if (
    !HANDOFF_FILE_NAME.test(name)
    || WINDOWS_RESERVED.test(stem)
    || name.endsWith(".")
  ) {
    throw new HandoffSnapshotError("UNREADABLE", `Refusing unsafe handoff file name ${JSON.stringify(name)}.`);
  }
  const root = resolve(outDir);
  const joined = resolve(root, name);
  if (!joined.startsWith(root + sep)) {
    throw new HandoffSnapshotError("UNREADABLE", `Handoff file name ${JSON.stringify(name)} escapes its directory.`);
  }
  return joined;
}

/** Accounts, hashes and writes in one place so no helper can forget one of them. */
class Sink {
  private readonly hash = createHash("sha256");
  private bytes = 0;
  private constructor(private readonly handle: FileHandle, private readonly budget: ByteBudget) {}

  static async create(path: string, budget: ByteBudget): Promise<Sink> {
    // "wx": the bridge hands over an empty directory, so an existing file means two writers.
    const handle = await retryLocked("open handoff output", () => open(path, "wx"), "WRITE");
    return new Sink(handle, budget);
  }

  async write(chunk: Uint8Array): Promise<void> {
    if (chunk.length === 0) return;
    this.budget.take(chunk.length);
    this.hash.update(chunk);
    this.bytes += chunk.length;
    try {
      await this.handle.writeFile(chunk);
    } catch (error) {
      throw unreadable(error, "write handoff output", "WRITE");
    }
  }

  async finish(): Promise<{ bytes: number; sha256: string }> {
    await this.handle.close().catch((error) => {
      throw unreadable(error, "close handoff output", "WRITE");
    });
    return { bytes: this.bytes, sha256: this.hash.digest("hex") };
  }

  async abandon(): Promise<void> {
    await this.handle.close().catch(() => {});
  }
}

async function* chunksOf(stream: AsyncIterable<Uint8Array> | ReadableStream<Uint8Array>, what: string): AsyncGenerator<Uint8Array> {
  try {
    if (Symbol.asyncIterator in stream) {
      yield* stream as AsyncIterable<Uint8Array>;
      return;
    }
    const reader = (stream as ReadableStream<Uint8Array>).getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) return;
        yield value;
      }
    } finally {
      await reader.cancel().catch(() => {});
    }
  } catch (error) {
    throw unreadable(error, what);
  }
}

async function requireRegularFile(path: string): Promise<void> {
  const info = await retryLocked("stat handoff source", () => lstat(path));
  // lstat, never stat: a symlink or junction in a store must not redirect the copy.
  if (!info.isFile()) throw new HandoffSnapshotError("UNREADABLE", "Handoff source is not a regular file.");
}

export async function copyWholeLines(
  src: string,
  outDir: string,
  name: string,
  role: HandoffFile["role"],
  budget: ByteBudget,
): Promise<HandoffFile> {
  const dest = safeJoin(outDir, name);
  await requireRegularFile(src);
  const sink = await Sink.create(dest, budget);
  try {
    // Bytes after the last newline seen are held back, so a record the agent was
    // still appending is never written torn; they are written once their newline arrives.
    let pending: Uint8Array[] = [];
    for await (const raw of chunksOf(createReadStream(src, { highWaterMark: READ_CHUNK }), "read handoff source")) {
      budget.check();
      const chunk = Buffer.from(raw.buffer, raw.byteOffset, raw.byteLength);
      const newline = chunk.lastIndexOf(0x0a);
      if (newline < 0) {
        pending.push(chunk);
        continue;
      }
      for (const held of pending) await sink.write(held);
      await sink.write(chunk.subarray(0, newline + 1));
      pending = newline + 1 < chunk.length ? [chunk.subarray(newline + 1)] : [];
    }
  } catch (error) {
    await sink.abandon();
    throw error;
  }
  return { name, role, sourcePath: src, ...(await sink.finish()) };
}

/** For documents that are complete as they stand; a transcript still being
 * appended to goes through `copyWholeLines` instead. */
export async function copyWholeFile(
  src: string,
  outDir: string,
  name: string,
  role: HandoffFile["role"],
  budget: ByteBudget,
): Promise<HandoffFile> {
  const dest = safeJoin(outDir, name);
  await requireRegularFile(src);
  const sink = await Sink.create(dest, budget);
  try {
    for await (const raw of chunksOf(createReadStream(src, { highWaterMark: READ_CHUNK }), "read handoff source")) {
      budget.check();
      await sink.write(raw);
    }
  } catch (error) {
    await sink.abandon();
    throw error;
  }
  return { name, role, sourcePath: src, ...(await sink.finish()) };
}

export async function writePrefix(
  source: RolloutSource,
  end: number,
  outDir: string,
  name: string,
  meta: Omit<HandoffFile, "name" | "bytes" | "sha256">,
  budget: ByteBudget,
): Promise<HandoffFile> {
  if (!Number.isSafeInteger(end) || end <= 0) {
    throw new HandoffSnapshotError("UNREADABLE", "Handoff prefix length is not a positive byte count.");
  }
  const dest = safeJoin(outDir, name);
  const sink = await Sink.create(dest, budget);
  try {
    let position = 0;
    for await (const chunk of chunksOf(source.open(), "read handoff source")) {
      budget.check();
      const part = chunk.subarray(0, Math.min(chunk.length, end - position));
      position += part.length;
      // Checked before the last bytes are written so a bad offset leaves no plausible file behind.
      if (position === end && part[part.length - 1] !== 0x0a) {
        throw new HandoffSnapshotError("UNREADABLE", "Handoff prefix does not end on a line boundary.");
      }
      await sink.write(part);
      if (position === end) break;
    }
    if (position < end) throw new HandoffSnapshotError("UNREADABLE", "Handoff source is shorter than the requested prefix.");
  } catch (error) {
    await sink.abandon();
    throw error;
  }
  return { ...meta, name, sourceRange: meta.sourceRange ?? { start: 0, end }, ...(await sink.finish()) };
}

export async function writeText(
  outDir: string,
  name: string,
  text: string,
  role: HandoffFile["role"],
  budget: ByteBudget,
): Promise<HandoffFile> {
  const sink = await Sink.create(safeJoin(outDir, name), budget);
  try {
    await sink.write(Buffer.from(text, "utf8"));
  } catch (error) {
    await sink.abandon();
    throw error;
  }
  return { name, role, ...(await sink.finish()) };
}

/** Bun types lag its runtime: DecompressionStream accepts "zstd" and decodes it
 * incrementally (16 KiB output chunks), which is the only form that keeps a
 * large rollout off the loop. Verified on the pinned Bun in
 * handoff-snapshot-io.test.ts. */
function zstdDecode(path: string): AsyncIterable<Uint8Array> {
  const decoder = new DecompressionStream("zstd" as never) as unknown as ReadableWritablePair<Uint8Array, Uint8Array>;
  return chunksOf(Bun.file(path).stream().pipeThrough(decoder), "decompress handoff source");
}

export async function openMaybeZstd(path: string): Promise<RolloutSource | undefined> {
  const candidates = path.endsWith(".zst") ? [path] : [path, `${path}.zst`];
  for (const candidate of candidates) {
    try {
      await lstat(candidate);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw unreadable(error, "stat handoff source");
    }
    await requireRegularFile(candidate);
    const compressed = candidate.endsWith(".zst");
    return {
      path: candidate,
      compressed,
      open: () => compressed
        ? zstdDecode(candidate)
        : chunksOf(createReadStream(candidate, { highWaterMark: READ_CHUNK }), "read handoff source"),
    };
  }
  return undefined;
}
