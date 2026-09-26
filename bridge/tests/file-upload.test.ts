import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync, mkdirSync, utimesSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  FileUploadManager, sanitizeUploadFileName, MAX_UPLOAD_BYTES,
  type UploadResultFields,
} from "../src/file-upload";
import { createMessage, type AbMessage, type FileUploadReady } from "../src/protocol";
import { loadIgnoreRules } from "../src/file-tree";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

function lastOfType<T extends AbMessage["type"]>(sent: AbMessage[], type: T) {
  return [...sent].reverse().find((m) => m.type === type) as Extract<AbMessage, { type: T }> | undefined;
}

describe("sanitizeUploadFileName", () => {
  it("passes ordinary names through", () => {
    expect(sanitizeUploadFileName("photo 1.png")).toBe("photo 1.png");
  });
  it("strips path components (posix, windows, traversal)", () => {
    expect(sanitizeUploadFileName("../../etc/passwd")).toBe("passwd");
    expect(sanitizeUploadFileName("C:\\Users\\x\\evil.exe")).toBe("evil.exe");
    expect(sanitizeUploadFileName("/abs/path/a.txt")).toBe("a.txt");
  });
  it("strips leading dots and collapses disallowed chars", () => {
    expect(sanitizeUploadFileName("..hidden")).toBe("hidden");
    expect(sanitizeUploadFileName("a#b?.txt")).toBe("a_b_.txt");
  });
  it("rejects names that sanitize to nothing", () => {
    expect(sanitizeUploadFileName("...")).toBeNull();
    expect(sanitizeUploadFileName("///")).toBeNull();
    expect(sanitizeUploadFileName("")).toBeNull();
  });
});

describe("FileUploadManager", () => {
  let projectDir: string;
  let sent: AbMessage[];
  let mgr: FileUploadManager;

  beforeEach(() => {
    projectDir = mkdtempSync(join(tmpdir(), "antgrid-upload-test-"));
    sent = [];
    mgr = new FileUploadManager({
      projectId: "p",
      projectPath: projectDir,
      send: (m) => sent.push(m),
    });
  });

  afterEach(() => {
    mgr.stop();
    rmSync(projectDir, { recursive: true, force: true });
  });

  function start(size: number, fileName = "data.bin", requestId = "r1"): string {
    mgr.handleStart(createMessage("file:upload-start", {
      projectId: "p", requestId, fileName, size,
    }));
    const ready = lastOfType(sent, "file:upload-ready");
    expect(ready).toBeDefined();
    return (ready as FileUploadReady).uploadId;
  }

  it("happy path: start → chunks → done writes the file and returns its absolute path", () => {
    const payload = Buffer.from("hello upload world");
    const uploadId = start(payload.length);

    mgr.handleChunk(createMessage("file:upload-chunk", {
      uploadId, seq: 0, data: payload.subarray(0, 10).toString("base64"),
    }));
    expect(lastOfType(sent, "file:upload-ack")!.seq).toBe(0);
    mgr.handleChunk(createMessage("file:upload-chunk", {
      uploadId, seq: 1, data: payload.subarray(10).toString("base64"),
    }));
    expect(lastOfType(sent, "file:upload-ack")!.seq).toBe(1);

    mgr.handleDone(createMessage("file:upload-done", { uploadId }));
    const result = lastOfType(sent, "file:upload-result")!;
    expect(result.ok).toBe(true);
    expect(result.path).toBeDefined();
    expect(result.path!.startsWith(join(projectDir, ".antgrid", "uploads"))).toBe(true);
    expect(readFileSync(result.path!).equals(payload)).toBe(true);
  });

  it("writes a self-ignoring .antgrid/.gitignore", () => {
    const uploadId = start(1);
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 0, data: Buffer.from("x").toString("base64") }));
    mgr.handleDone(createMessage("file:upload-done", { uploadId }));
    expect(readFileSync(join(projectDir, ".antgrid", ".gitignore"), "utf8")).toContain("*");
  });

  it("rejects over-cap declared size at start", () => {
    mgr.handleStart(createMessage("file:upload-start", {
      projectId: "p", requestId: "r1", fileName: "big.bin", size: MAX_UPLOAD_BYTES + 1,
    }));
    const result = lastOfType(sent, "file:upload-result")!;
    expect(result.ok).toBe(false);
    expect(result.error).toBe("TOO_LARGE");
  });

  it("rejects a name that sanitizes to nothing", () => {
    mgr.handleStart(createMessage("file:upload-start", {
      projectId: "p", requestId: "r1", fileName: "...", size: 10,
    }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("INVALID_NAME");
  });

  it("rejects out-of-order chunk seq and aborts the upload", () => {
    const uploadId = start(20);
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 1, data: Buffer.from("x").toString("base64") }));
    const result = lastOfType(sent, "file:upload-result")!;
    expect(result.ok).toBe(false);
    expect(result.error).toBe("BAD_SEQUENCE");
    // the aborted upload is forgotten — a follow-up chunk gets UPLOAD_NOT_FOUND
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 0, data: "eA==" }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("UPLOAD_NOT_FOUND");
  });

  it("rejects cumulative bytes over the declared size", () => {
    const uploadId = start(4);
    mgr.handleChunk(createMessage("file:upload-chunk", {
      uploadId, seq: 0, data: Buffer.from("12345").toString("base64"),
    }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("SIZE_MISMATCH");
  });

  it("rejects a chunk whose data is not valid base64", () => {
    const uploadId = start(10);
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 0, data: "@@@@" }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("WRITE_FAILED");
  });

  it("rejects an empty chunk and frees the slot (no indefinite slot-hold)", () => {
    const uploadId = start(10);
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 0, data: "" }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("WRITE_FAILED");
    // the aborted upload is forgotten, so its slot no longer counts against the cap
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 1, data: "eA==" }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("UPLOAD_NOT_FOUND");
  });

  it("rejects done when received bytes < declared size", () => {
    const uploadId = start(10);
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 0, data: Buffer.from("123").toString("base64") }));
    mgr.handleDone(createMessage("file:upload-done", { uploadId }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("SIZE_MISMATCH");
  });

  it("unknown uploadId on done → UPLOAD_NOT_FOUND", () => {
    mgr.handleDone(createMessage("file:upload-done", { uploadId: "nope" }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("UPLOAD_NOT_FOUND");
  });

  it("caps concurrent uploads at 4 → BUSY", () => {
    for (let i = 0; i < 4; i++) start(10, `f${i}.bin`, `r${i}`);
    mgr.handleStart(createMessage("file:upload-start", {
      projectId: "p", requestId: "r5", fileName: "f5.bin", size: 10,
    }));
    expect(lastOfType(sent, "file:upload-result")!.error).toBe("BUSY");
  });

  it("sweepStale removes files older than 24h and leaves fresh ones", () => {
    const dir = join(projectDir, ".antgrid", "uploads");
    mkdirSync(dir, { recursive: true });
    const oldFile = join(dir, "old.bin");
    const freshFile = join(dir, "fresh.bin");
    writeFileSync(oldFile, "old");
    writeFileSync(freshFile, "fresh");
    const old = (Date.now() - 25 * 60 * 60 * 1000) / 1000;
    utimesSync(oldFile, old, old);
    mgr.sweepStale();
    expect(existsSync(oldFile)).toBe(false);
    expect(existsSync(freshFile)).toBe(true);
  });

  it("stop() deletes in-flight .part files", () => {
    const uploadId = start(10);
    mgr.handleChunk(createMessage("file:upload-chunk", { uploadId, seq: 0, data: Buffer.from("123").toString("base64") }));
    mgr.stop();
    const dir = join(projectDir, ".antgrid", "uploads");
    const leftovers = existsSync(dir)
      ? readdirSync(dir).filter((f: string) => f.endsWith(".part"))
      : [];
    expect(leftovers.length).toBe(0);
  });

  describe("begin()/StreamUpload (the stream-upload path)", () => {
    function results(): UploadResultFields[] {
      return collected;
    }
    let collected: UploadResultFields[];
    function onResult(r: UploadResultFields) {
      collected.push(r);
    }

    beforeEach(() => {
      collected = [];
    });

    it("happy path: write() then end() finalizes the file and reports ok exactly once", () => {
      const payload = Buffer.from("stream upload bytes");
      const begun = mgr.begin({ requestId: "s1", fileName: "s.bin", size: payload.length }, onResult);
      expect(begun.ok).toBe(true);
      if (!begun.ok) return;
      expect(begun.upload.write(payload.subarray(0, 8))).toBe("ok");
      expect(begun.upload.write(payload.subarray(8))).toBe("ok");
      begun.upload.end();
      expect(results().length).toBe(1);
      const result = results()[0]!;
      expect(result.ok).toBe(true);
      expect(result.path).toBeDefined();
      expect(readFileSync(result.path!).equals(payload)).toBe(true);
      expect(existsSync(result.path! + ".part")).toBe(false);
    });

    it("write() past the declared size returns oversize, removes the partial, and never calls onResult", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "s.bin", size: 2 }, onResult);
      expect(begun.ok).toBe(true);
      if (!begun.ok) return;
      expect(begun.upload.write(Buffer.from("abc"))).toBe("oversize");
      expect(results().length).toBe(0);
      const dir = join(projectDir, ".antgrid", "uploads");
      const leftovers = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".part")) : [];
      expect(leftovers.length).toBe(0);
    });

    it("end() short of the declared size reports INCOMPLETE and removes the partial", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "s.bin", size: 10 }, onResult);
      expect(begun.ok).toBe(true);
      if (!begun.ok) return;
      expect(begun.upload.write(Buffer.from("abc"))).toBe("ok");
      begun.upload.end();
      expect(results().length).toBe(1);
      expect(results()[0]!.ok).toBe(false);
      expect(results()[0]!.error).toBe("INCOMPLETE");
      const dir = join(projectDir, ".antgrid", "uploads");
      const leftovers = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".part")) : [];
      expect(leftovers.length).toBe(0);
    });

    it("cancel() removes the partial without ever calling onResult, and is idempotent", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "s.bin", size: 10 }, onResult);
      expect(begun.ok).toBe(true);
      if (!begun.ok) return;
      begun.upload.write(Buffer.from("abc"));
      begun.upload.cancel();
      expect(results().length).toBe(0);
      const dir = join(projectDir, ".antgrid", "uploads");
      const leftovers = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".part")) : [];
      expect(leftovers.length).toBe(0);
      // idempotent: a second cancel (e.g. a racing stream reset after the app
      // already FIN'd) must not throw or report anything.
      expect(() => begun.upload.cancel()).not.toThrow();
      expect(results().length).toBe(0);
    });

    it("a result already reported by write() is not re-reported by a later end()", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "s.bin", size: 2 }, onResult);
      expect(begun.ok).toBe(true);
      if (!begun.ok) return;
      begun.upload.write(Buffer.from("abc")); // oversize: no result, but the upload is done
      begun.upload.end();
      expect(results().length).toBe(0);
    });

    it("stop() reports WRITE_FAILED for an in-flight stream upload and removes its partial", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "s.bin", size: 10 }, onResult);
      expect(begun.ok).toBe(true);
      if (!begun.ok) return;
      begun.upload.write(Buffer.from("abc"));
      mgr.stop();
      expect(results().length).toBe(1);
      expect(results()[0]!.error).toBe("WRITE_FAILED");
      const dir = join(projectDir, ".antgrid", "uploads");
      const leftovers = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".part")) : [];
      expect(leftovers.length).toBe(0);
    });

    it("rejects an over-cap declared size the same way handleStart does", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "big.bin", size: MAX_UPLOAD_BYTES + 1 }, onResult);
      expect(begun.ok).toBe(false);
      if (begun.ok) return;
      expect(begun.result.error).toBe("TOO_LARGE");
    });

    it("MAX_CONCURRENT_UPLOADS is shared between the socket path and the stream path", () => {
      start(10, "a.bin", "r1");
      start(10, "b.bin", "r2");
      const begun1 = mgr.begin({ requestId: "s1", fileName: "c.bin", size: 10 }, onResult);
      expect(begun1.ok).toBe(true);
      const begun2 = mgr.begin({ requestId: "s2", fileName: "d.bin", size: 10 }, onResult);
      expect(begun2.ok).toBe(true);
      // Cap (4) is now full across both paths.
      const begun3 = mgr.begin({ requestId: "s3", fileName: "e.bin", size: 10 }, onResult);
      expect(begun3.ok).toBe(false);
      if (!begun3.ok) expect(begun3.result.error).toBe("BUSY");
      mgr.handleStart(createMessage("file:upload-start", {
        projectId: "p", requestId: "r5", fileName: "f5.bin", size: 10,
      }));
      expect(lastOfType(sent, "file:upload-result")!.error).toBe("BUSY");
    });
  });
});

describe("watcher exclusion", () => {
  it(".antgrid is in the default ignore rules", () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-ignore-test-"));
    try {
      const ig = loadIgnoreRules(dir, []);
      expect(ig.ignores(".antgrid/uploads/x.bin")).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
