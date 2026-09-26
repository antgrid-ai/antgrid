import {
  mkdirSync, existsSync, writeFileSync, openSync, writeSync, closeSync,
  renameSync, rmSync, readdirSync, statSync,
} from "node:fs";
import { copyFile as copyFileAsync, lstat } from "node:fs/promises";
import { isAbsolute, join, relative } from "node:path";
import { renderableBinaryMime } from "./file-tree";
import { logger } from "./logger";
const log = logger.child({ component: "file-upload" });

export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;
const MAX_CONCURRENT_UPLOADS = 4;
const INACTIVITY_MS = 60_000;
const STALE_MS = 24 * 60 * 60 * 1000;
const SWEEP_INTERVAL_MS = 60 * 60 * 1000;
const MAX_NAME_LENGTH = 128;

export type UploadErrorCode = "TOO_LARGE" | "INVALID_NAME" | "INVALID_SOURCE" | "NOT_ALLOWED"
  | "WRITE_FAILED" | "TIMEOUT" | "BUSY" | "INCOMPLETE";

export interface UploadResultFields {
  uploadId?: string;
  ok: boolean;
  path?: string;
  relPath?: string;
  mimeType?: string;
  error?: UploadErrorCode;
  message?: string;
}

export type StreamUploadWrite = "ok" | "oversize" | "failed";

/** One file's write side over the `upload` stream — `peer/upload-streams.ts`
 *  is the only caller. */
export interface StreamUpload {
  readonly uploadId: string;
  /** `"oversize"`: the partial is already removed and no result is reported
   *  — the caller resets the stream itself, since a written result would race
   *  the bytes still arriving on it.
   *  `"failed"`: a `WRITE_FAILED` result has already gone through `onResult`,
   *  partial removed. Touches the inactivity timer on `"ok"`. */
  write(bytes: Uint8Array): StreamUploadWrite;
  /** The app FIN'd: reports `ok`, `INCOMPLETE` or `WRITE_FAILED` through
   *  `onResult`, exactly once. */
  end(): void;
  /** Partial removed, `onResult` never called. Idempotent; a no-op once a
   *  result was already reported. */
  cancel(): void;
}

export type UploadAdmission =
  | { ok: false; refusal: { code: "UPDATE_REQUIRED" | "NOT_ALLOWED"; message: string } }
  | { ok: true; manager: FileUploadManager };

/** What a project's core exposes to the upload registry; `AgentCore`
 *  implements it (`agent-core.ts`). Never rejects. */
export interface UploadStreamServer {
  admit(peerId: string, checkoutId: string): Promise<UploadAdmission>;
}

// The phone never chooses the destination path: only a filename crosses the
// wire, and everything the sanitizer can't vouch for is collapsed. Traversal
// (`../`), absolute paths, and drive letters all reduce to their basename.
export function sanitizeUploadFileName(raw: string): string | null {
  const base = raw.split(/[\\/]/).pop() ?? "";
  const cleaned = base
    .replace(/^\.+/, "")
    .replace(/[^A-Za-z0-9._ -]/g, "_")
    .trim();
  if (cleaned.length === 0) return null;
  return cleaned.slice(0, MAX_NAME_LENGTH);
}

type UploadSession = {
  uploadId: string;
  requestId: string;
  fileName: string;
  declaredSize: number;
  received: number;
  nextSeq: number;
  partPath: string;
  // Held open for the upload's lifetime so each chunk is one write, not an
  // open/append/close cycle. Closed before any rename/unlink (Windows refuses
  // to move or delete a file with a live handle).
  fd: number;
  timer: ReturnType<typeof setTimeout>;
  onResult: (result: UploadResultFields) => void;
};

export class FileUploadManager {
  private uploads = new Map<string, UploadSession>();
  /** `copyLocal` calls in flight, counted against the same concurrency cap as
   *  `uploads` — a loopback copy and a stream upload draw from one pool. */
  private copiesInFlight = 0;
  private sweepTimer?: ReturnType<typeof setInterval>;

  constructor(
    private opts: { projectId: string; projectPath: string },
  ) {}

  private get stagingDir(): string {
    return join(this.opts.projectPath, ".antgrid", "uploads");
  }

  private ensureStagingDir(): void {
    mkdirSync(this.stagingDir, { recursive: true });
    // Self-ignoring dir: keeps staged uploads out of the user's git status
    // even when the repo's own .gitignore doesn't know about .antgrid.
    const gi = join(this.opts.projectPath, ".antgrid", ".gitignore");
    if (!existsSync(gi)) writeFileSync(gi, "*\n");
  }

  private closeFd(u: UploadSession): void {
    try {
      closeSync(u.fd);
    } catch {
      // already closed — nothing to do
    }
  }

  private abort(u: UploadSession, error: UploadErrorCode, message: string): void {
    clearTimeout(u.timer);
    this.uploads.delete(u.uploadId);
    this.closeFd(u);
    rmSync(u.partPath, { force: true });
    u.onResult({ uploadId: u.uploadId, ok: false, error, message });
  }

  private touch(u: UploadSession): void {
    clearTimeout(u.timer);
    u.timer = setTimeout(() => {
      log.warn("Upload %s timed out after %dms of inactivity", u.uploadId, INACTIVITY_MS);
      this.abort(u, "TIMEOUT", "Upload timed out");
    }, INACTIVITY_MS);
  }

  /** Short uploadId prefix keeps the finalized name unique without hiding the
   *  original one — shared by the stream path and `copyLocal`. */
  private finalName(uploadId: string, fileName: string): string {
    return `${uploadId.slice(0, 8)}-${fileName}`;
  }

  /** Renames `partPath` to its finalized name and builds the success fields,
   *  or reports `WRITE_FAILED` and removes the partial. The only place either
   *  upload path finalizes a staged file. */
  private finalize(uploadId: string, fileName: string, partPath: string): UploadResultFields {
    const finalPath = join(this.stagingDir, this.finalName(uploadId, fileName));
    try {
      renameSync(partPath, finalPath);
    } catch (err) {
      log.error("upload finalize failed: %s", err);
      rmSync(partPath, { force: true });
      return { uploadId, ok: false, error: "WRITE_FAILED", message: "Could not finalize upload" };
    }
    return {
      uploadId,
      ok: true,
      path: finalPath,
      relPath: relative(this.opts.projectPath, finalPath),
      mimeType: renderableBinaryMime(finalPath),
    };
  }

  /** Admits one file onto the `upload` stream, sharing the same concurrency
   *  cap, size limit, sanitizer, staging dir and inactivity timer as
   *  `copyLocal` — a stream upload and a loopback upload both count against
   *  `MAX_CONCURRENT_UPLOADS`. */
  begin(
    start: { requestId: string; fileName: string; size: number },
    onResult: (result: UploadResultFields) => void,
  ): { ok: true; upload: StreamUpload } | { ok: false; result: UploadResultFields } {
    if (this.uploads.size + this.copiesInFlight >= MAX_CONCURRENT_UPLOADS) {
      return { ok: false, result: { ok: false, error: "BUSY", message: "Too many concurrent uploads" } };
    }
    if (start.size > MAX_UPLOAD_BYTES) {
      return { ok: false, result: { ok: false, error: "TOO_LARGE", message: "File exceeds 20 MB limit" } };
    }
    const fileName = sanitizeUploadFileName(start.fileName);
    if (!fileName) {
      return { ok: false, result: { ok: false, error: "INVALID_NAME", message: "Invalid file name" } };
    }
    try {
      this.ensureStagingDir();
      const uploadId = crypto.randomUUID();
      const partPath = join(this.stagingDir, `${uploadId}.part`);
      const fd = openSync(partPath, "w");
      const session: UploadSession = {
        uploadId, requestId: start.requestId, fileName,
        declaredSize: start.size, received: 0, nextSeq: 0, partPath, fd,
        timer: setTimeout(() => {}, 0),
        onResult,
      };
      this.uploads.set(uploadId, session);
      this.touch(session);
      return { ok: true, upload: this.streamUploadFor(session) };
    } catch (err) {
      log.error("upload start failed: %s", err);
      return { ok: false, result: { ok: false, error: "WRITE_FAILED", message: "Could not create staging file" } };
    }
  }

  private streamUploadFor(u: UploadSession): StreamUpload {
    return {
      uploadId: u.uploadId,
      write: (bytes) => this.writeStreamChunk(u, bytes),
      end: () => this.endStreamUpload(u),
      cancel: () => this.cancelStreamUpload(u),
    };
  }

  private writeStreamChunk(u: UploadSession, bytes: Uint8Array): StreamUploadWrite {
    if (!this.uploads.has(u.uploadId)) return "failed"; // already resolved by another path
    if (u.received + bytes.byteLength > u.declaredSize) {
      // The caller resets the stream itself and reports no result (§2.2).
      clearTimeout(u.timer);
      this.uploads.delete(u.uploadId);
      this.closeFd(u);
      rmSync(u.partPath, { force: true });
      return "oversize";
    }
    try {
      writeSync(u.fd, bytes);
    } catch (err) {
      log.error("upload chunk write failed: %s", err);
      this.abort(u, "WRITE_FAILED", "Could not write to staging file");
      return "failed";
    }
    u.received += bytes.byteLength;
    this.touch(u);
    return "ok";
  }

  private endStreamUpload(u: UploadSession): void {
    if (!this.uploads.has(u.uploadId)) return; // already resolved by another path
    if (u.received !== u.declaredSize) {
      this.abort(u, "INCOMPLETE", `Declared ${u.declaredSize} bytes, received ${u.received}`);
      return;
    }
    clearTimeout(u.timer);
    this.uploads.delete(u.uploadId);
    this.closeFd(u);
    u.onResult(this.finalize(u.uploadId, u.fileName, u.partPath));
  }

  private cancelStreamUpload(u: UploadSession): void {
    if (!this.uploads.has(u.uploadId)) return; // idempotent: already resolved
    clearTimeout(u.timer);
    this.uploads.delete(u.uploadId);
    this.closeFd(u);
    rmSync(u.partPath, { force: true });
  }

  /** Loopback-only: copies a file already on this machine into staging. The
   *  caller (agent-core.ts's `file:upload-local` handler) has already refused
   *  every non-loopback source before this runs. `sourcePath` is stat'd before
   *  anything is read, and only the sanitized `fileName` shapes the
   *  destination. */
  async copyLocal(req: { requestId: string; fileName: string; sourcePath: string }): Promise<UploadResultFields> {
    // The loopback socket's parser checks `type` alone, so no field here is
    // schema-checked — and this must resolve, never reject (see the caller).
    if (typeof req.sourcePath !== "string" || !isAbsolute(req.sourcePath)) {
      return { ok: false, error: "INVALID_SOURCE", message: "Source path must be absolute" };
    }
    let sourceSize: number;
    try {
      const st = await lstat(req.sourcePath);
      if (!st.isFile()) throw new Error("not a file");
      sourceSize = st.size;
    } catch {
      return { ok: false, error: "INVALID_SOURCE", message: "Source file is not accessible" };
    }
    if (sourceSize > MAX_UPLOAD_BYTES) {
      return { ok: false, error: "TOO_LARGE", message: "File exceeds 20 MB limit" };
    }
    const fileName = typeof req.fileName === "string" ? sanitizeUploadFileName(req.fileName) : null;
    if (!fileName) {
      return { ok: false, error: "INVALID_NAME", message: "Invalid file name" };
    }
    if (this.uploads.size + this.copiesInFlight >= MAX_CONCURRENT_UPLOADS) {
      return { ok: false, error: "BUSY", message: "Too many concurrent uploads" };
    }
    this.copiesInFlight++;
    try {
      try {
        this.ensureStagingDir();
      } catch (err) {
        log.error("upload staging dir failed: %s", err);
        return { ok: false, error: "WRITE_FAILED", message: "Could not create staging file" };
      }
      const uploadId = crypto.randomUUID();
      const partPath = join(this.stagingDir, `${uploadId}.part`);
      try {
        await copyFileAsync(req.sourcePath, partPath);
      } catch (err) {
        log.error("upload copy failed: %s", err);
        rmSync(partPath, { force: true });
        return { ok: false, error: "WRITE_FAILED", message: "Could not copy the file" };
      }
      // The source can grow between the stat above and the copy completing —
      // re-check the staged bytes before finalizing rather than trusting the
      // earlier size.
      let stagedSize: number;
      try {
        stagedSize = statSync(partPath).size;
      } catch (err) {
        log.error("upload stat failed: %s", err);
        rmSync(partPath, { force: true });
        return { ok: false, error: "WRITE_FAILED", message: "Could not finalize upload" };
      }
      if (stagedSize > MAX_UPLOAD_BYTES) {
        rmSync(partPath, { force: true });
        return { ok: false, error: "TOO_LARGE", message: "File exceeds 20 MB limit" };
      }
      return this.finalize(uploadId, fileName, partPath);
    } finally {
      this.copiesInFlight--;
    }
  }

  // Sweep once now and then on an interval: a long-lived bridge that never
  // re-attaches would otherwise never reclaim finalized files or `.part`
  // orphans left by a crash between write and finalize. `unref` so the timer
  // never keeps the process alive on its own.
  startSweeper(): void {
    this.sweepStale();
    this.sweepTimer ??= setInterval(() => this.sweepStale(), SWEEP_INTERVAL_MS);
    this.sweepTimer.unref?.();
  }

  sweepStale(): void {
    if (!existsSync(this.stagingDir)) return;
    const now = Date.now();
    for (const name of readdirSync(this.stagingDir)) {
      const p = join(this.stagingDir, name);
      try {
        if (now - statSync(p).mtimeMs > STALE_MS) rmSync(p, { force: true });
      } catch {
        // vanished mid-sweep — nothing to do
      }
    }
  }

  stop(): void {
    clearInterval(this.sweepTimer);
    this.sweepTimer = undefined;
    for (const u of this.uploads.values()) {
      clearTimeout(u.timer);
      this.closeFd(u);
      rmSync(u.partPath, { force: true });
      u.onResult({ uploadId: u.uploadId, ok: false, error: "WRITE_FAILED", message: "Upload interrupted" });
    }
    this.uploads.clear();
  }
}
