import {
  mkdirSync, existsSync, writeFileSync, openSync, writeSync, closeSync,
  renameSync, rmSync, readdirSync, statSync,
} from "node:fs";
import { join } from "node:path";
import {
  createMessage, type AbMessage,
  type FileUploadStart, type FileUploadChunk, type FileUploadDone,
} from "./protocol";
import { logger } from "./logger";
const log = logger.child({ component: "file-upload" });

export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;
const MAX_CONCURRENT_UPLOADS = 4;
const INACTIVITY_MS = 60_000;
const STALE_MS = 24 * 60 * 60 * 1000;
const SWEEP_INTERVAL_MS = 60 * 60 * 1000;
const MAX_NAME_LENGTH = 128;

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
};

export class FileUploadManager {
  private uploads = new Map<string, UploadSession>();
  private sweepTimer?: ReturnType<typeof setInterval>;

  constructor(
    private opts: {
      projectId: string;
      projectPath: string;
      send: (msg: AbMessage) => void;
    },
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

  private sendResult(requestId: string, fields: {
    uploadId?: string; ok: boolean; path?: string; error?: string; message?: string;
  }): void {
    this.opts.send(createMessage("file:upload-result", { requestId, ...fields }));
  }

  private closeFd(u: UploadSession): void {
    try {
      closeSync(u.fd);
    } catch {
      // already closed — nothing to do
    }
  }

  private abort(u: UploadSession, error: string, message: string): void {
    clearTimeout(u.timer);
    this.uploads.delete(u.uploadId);
    this.closeFd(u);
    rmSync(u.partPath, { force: true });
    this.sendResult(u.requestId, { uploadId: u.uploadId, ok: false, error, message });
  }

  private touch(u: UploadSession): void {
    clearTimeout(u.timer);
    u.timer = setTimeout(() => {
      log.warn("Upload %s timed out after %dms of inactivity", u.uploadId, INACTIVITY_MS);
      this.abort(u, "TIMEOUT", "Upload timed out");
    }, INACTIVITY_MS);
  }

  handleStart(msg: FileUploadStart): void {
    if (this.uploads.size >= MAX_CONCURRENT_UPLOADS) {
      this.sendResult(msg.requestId, { ok: false, error: "BUSY", message: "Too many concurrent uploads" });
      return;
    }
    if (msg.size > MAX_UPLOAD_BYTES) {
      this.sendResult(msg.requestId, { ok: false, error: "TOO_LARGE", message: "File exceeds 20 MB limit" });
      return;
    }
    const fileName = sanitizeUploadFileName(msg.fileName);
    if (!fileName) {
      this.sendResult(msg.requestId, { ok: false, error: "INVALID_NAME", message: "Invalid file name" });
      return;
    }
    try {
      this.ensureStagingDir();
      const uploadId = crypto.randomUUID();
      const partPath = join(this.stagingDir, `${uploadId}.part`);
      const fd = openSync(partPath, "w");
      const session: UploadSession = {
        uploadId, requestId: msg.requestId, fileName,
        declaredSize: msg.size, received: 0, nextSeq: 0, partPath, fd,
        timer: setTimeout(() => {}, 0),
      };
      this.uploads.set(uploadId, session);
      this.touch(session);
      this.opts.send(createMessage("file:upload-ready", { requestId: msg.requestId, uploadId }));
    } catch (err) {
      log.error("upload start failed: %s", err);
      this.sendResult(msg.requestId, { ok: false, error: "WRITE_FAILED", message: "Could not create staging file" });
    }
  }

  handleChunk(msg: FileUploadChunk): void {
    const u = this.uploads.get(msg.uploadId);
    if (!u) {
      // requestId is unknown for a dead upload; reply keyed by uploadId so the
      // app can still fail its pending ack.
      this.opts.send(createMessage("file:upload-result", {
        requestId: "", uploadId: msg.uploadId, ok: false,
        error: "UPLOAD_NOT_FOUND", message: "Unknown or expired upload",
      }));
      return;
    }
    if (msg.seq !== u.nextSeq) {
      this.abort(u, "BAD_SEQUENCE", `Expected chunk ${u.nextSeq}, got ${msg.seq}`);
      return;
    }
    // An empty chunk makes no progress but still resets the inactivity timer and
    // draws an ack — a stream of them would pin an upload slot open forever. The
    // app never sends one (a 0-byte file skips straight to done), so reject it.
    if (msg.data.length === 0) {
      this.abort(u, "WRITE_FAILED", "Empty chunk");
      return;
    }
    // Buffer.from(str, "base64") never throws — it decodes leniently, silently
    // dropping invalid characters — so malformed input must be rejected up front.
    if (msg.data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(msg.data)) {
      this.abort(u, "WRITE_FAILED", "Chunk is not valid base64");
      return;
    }
    // Bound the decoded size from the (already length-capped) base64 string
    // BEFORE allocating, so an oversized chunk can't force a large allocation
    // just to be rejected afterward. For valid base64 this equals buf.length.
    const padding = msg.data.endsWith("==") ? 2 : msg.data.endsWith("=") ? 1 : 0;
    const decodedLen = (msg.data.length / 4) * 3 - padding;
    if (u.received + decodedLen > u.declaredSize) {
      this.abort(u, "SIZE_MISMATCH", "Received more bytes than declared");
      return;
    }
    const buf = Buffer.from(msg.data, "base64");
    try {
      writeSync(u.fd, buf);
    } catch (err) {
      log.error("upload chunk write failed: %s", err);
      this.abort(u, "WRITE_FAILED", "Could not write to staging file");
      return;
    }
    u.received += buf.length;
    u.nextSeq += 1;
    this.touch(u);
    this.opts.send(createMessage("file:upload-ack", { uploadId: u.uploadId, seq: msg.seq }));
  }

  handleDone(msg: FileUploadDone): void {
    const u = this.uploads.get(msg.uploadId);
    if (!u) {
      this.opts.send(createMessage("file:upload-result", {
        requestId: "", uploadId: msg.uploadId, ok: false,
        error: "UPLOAD_NOT_FOUND", message: "Unknown or expired upload",
      }));
      return;
    }
    if (u.received !== u.declaredSize) {
      this.abort(u, "SIZE_MISMATCH", `Declared ${u.declaredSize} bytes, received ${u.received}`);
      return;
    }
    clearTimeout(u.timer);
    this.uploads.delete(u.uploadId);
    this.closeFd(u);
    // Short uploadId prefix keeps names unique without hiding the original name.
    const finalPath = join(this.stagingDir, `${u.uploadId.slice(0, 8)}-${u.fileName}`);
    try {
      renameSync(u.partPath, finalPath);
    } catch (err) {
      log.error("upload finalize failed: %s", err);
      rmSync(u.partPath, { force: true });
      this.sendResult(u.requestId, { uploadId: u.uploadId, ok: false, error: "WRITE_FAILED", message: "Could not finalize upload" });
      return;
    }
    this.sendResult(u.requestId, { uploadId: u.uploadId, ok: true, path: finalPath });
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
    }
    this.uploads.clear();
  }
}
