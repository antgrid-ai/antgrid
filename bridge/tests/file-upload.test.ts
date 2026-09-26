import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import {
  mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync, mkdirSync,
  utimesSync, readdirSync, openSync, ftruncateSync, closeSync, symlinkSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  FileUploadManager, sanitizeUploadFileName, MAX_UPLOAD_BYTES,
  type UploadResultFields,
} from "../src/file-upload";
import { loadIgnoreRules } from "../src/file-tree";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

function partFilesIn(dir: string): string[] {
  return existsSync(dir) ? readdirSync(dir).filter((f: string) => f.endsWith(".part")) : [];
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
  let mgr: FileUploadManager;

  beforeEach(() => {
    projectDir = mkdtempSync(join(tmpdir(), "antgrid-upload-test-"));
    mgr = new FileUploadManager({ projectId: "p", projectPath: projectDir });
  });

  afterEach(() => {
    mgr.stop();
    rmSync(projectDir, { recursive: true, force: true });
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
      expect(partFilesIn(join(projectDir, ".antgrid", "uploads")).length).toBe(0);
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
      expect(partFilesIn(join(projectDir, ".antgrid", "uploads")).length).toBe(0);
    });

    it("cancel() removes the partial without ever calling onResult, and is idempotent", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "s.bin", size: 10 }, onResult);
      expect(begun.ok).toBe(true);
      if (!begun.ok) return;
      begun.upload.write(Buffer.from("abc"));
      begun.upload.cancel();
      expect(results().length).toBe(0);
      expect(partFilesIn(join(projectDir, ".antgrid", "uploads")).length).toBe(0);
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
      expect(partFilesIn(join(projectDir, ".antgrid", "uploads")).length).toBe(0);
    });

    it("rejects an over-cap declared size the same way copyLocal does", () => {
      const begun = mgr.begin({ requestId: "s1", fileName: "big.bin", size: MAX_UPLOAD_BYTES + 1 }, onResult);
      expect(begun.ok).toBe(false);
      if (begun.ok) return;
      expect(begun.result.error).toBe("TOO_LARGE");
    });
  });

  describe("copyLocal() (the loopback file:upload-local path)", () => {
    let sourceDir: string;

    beforeEach(() => {
      sourceDir = mkdtempSync(join(tmpdir(), "antgrid-upload-source-"));
    });

    afterEach(() => {
      rmSync(sourceDir, { recursive: true, force: true });
    });

    it("happy path: copies the source byte-identical, finalizes it, and leaves no .part behind", async () => {
      const payload = Buffer.from("hello from the desktop's own disk");
      const src = join(sourceDir, "note.txt");
      writeFileSync(src, payload);
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "note.txt", sourcePath: src });
      expect(result.ok).toBe(true);
      expect(result.path).toBeDefined();
      expect(result.path!.startsWith(join(projectDir, ".antgrid", "uploads"))).toBe(true);
      expect(readFileSync(result.path!).equals(payload)).toBe(true);
      expect(existsSync(result.path! + ".part")).toBe(false);
    });

    it("a directory source is refused INVALID_SOURCE", async () => {
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "dir.bin", sourcePath: sourceDir });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("INVALID_SOURCE");
      expect(partFilesIn(join(projectDir, ".antgrid", "uploads")).length).toBe(0);
    });

    it("a missing source is refused INVALID_SOURCE", async () => {
      const result = await mgr.copyLocal({
        requestId: "r1", fileName: "gone.bin", sourcePath: join(sourceDir, "does-not-exist.bin"),
      });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("INVALID_SOURCE");
    });

    it("a relative path is refused INVALID_SOURCE before any filesystem check", async () => {
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "rel.bin", sourcePath: "relative/path.bin" });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("INVALID_SOURCE");
    });

    it("a symlink source is refused INVALID_SOURCE", async () => {
      const target = join(sourceDir, "target.bin");
      writeFileSync(target, "x");
      const link = join(sourceDir, "link.bin");
      try {
        symlinkSync(target, link, "file");
      } catch {
        // Creating a file symlink on Windows needs Developer Mode or an
        // elevated shell — nothing to assert if this sandbox can't grant it.
        return;
      }
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "link.bin", sourcePath: link });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("INVALID_SOURCE");
    });

    it("a source over MAX_UPLOAD_BYTES is refused TOO_LARGE and leaves no .part behind", async () => {
      // A sparse file: ftruncate declares the size without writing real bytes,
      // so the assertion is on the declared (lstat'd) size, not on content —
      // exactly what the size check reads before anything is copied.
      const src = join(sourceDir, "big.bin");
      const fd = openSync(src, "w");
      ftruncateSync(fd, MAX_UPLOAD_BYTES + 1);
      closeSync(fd);
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "big.bin", sourcePath: src });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("TOO_LARGE");
      expect(partFilesIn(join(projectDir, ".antgrid", "uploads")).length).toBe(0);
    });

    // The loopback verb is parsed by `parseMessageFast`, which checks `type`
    // alone — every field reaches copyLocal unvalidated, and a rejection
    // escaping it reaches index.ts's `unhandledRejection` shutdown.
    it("never rejects: a staging directory that cannot be created answers WRITE_FAILED", async () => {
      const src = join(sourceDir, "note.txt");
      writeFileSync(src, "x");
      // A plain file where the `.antgrid` directory belongs makes the mkdir fail.
      writeFileSync(join(projectDir, ".antgrid"), "not a directory");
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "note.txt", sourcePath: src });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("WRITE_FAILED");
    });

    it("never rejects: non-string fields answer INVALID_SOURCE / INVALID_NAME", async () => {
      const src = join(sourceDir, "note.txt");
      writeFileSync(src, "x");
      const badSource = await mgr.copyLocal({ requestId: "r1", fileName: "a.txt", sourcePath: 42 as unknown as string });
      expect(badSource.error).toBe("INVALID_SOURCE");
      const badName = await mgr.copyLocal({ requestId: "r1", fileName: null as unknown as string, sourcePath: src });
      expect(badName.error).toBe("INVALID_NAME");
    });

    it("the size cap is read from the source's stat before staging or copying anything", async () => {
      const src = join(sourceDir, "big.bin");
      const fd = openSync(src, "w");
      ftruncateSync(fd, MAX_UPLOAD_BYTES + 1);
      closeSync(fd);
      // Staging is made impossible: only a refusal that runs before any
      // staging/copy step can still answer TOO_LARGE rather than WRITE_FAILED.
      writeFileSync(join(projectDir, ".antgrid"), "not a directory");
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "big.bin", sourcePath: src });
      expect(result.error).toBe("TOO_LARGE");
    });

    it("a name that sanitizes to nothing is refused INVALID_NAME", async () => {
      const src = join(sourceDir, "note.txt");
      writeFileSync(src, "x");
      const result = await mgr.copyLocal({ requestId: "r1", fileName: "...", sourcePath: src });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("INVALID_NAME");
    });

    it("BUSY beyond the concurrency limit, shared with the stream path", async () => {
      // Fill the cap (4) with open stream uploads first — deterministic,
      // unlike racing copyLocal's own async lstat against itself — then prove
      // copyLocal reads the same counter: one call over the shared cap.
      const collected: UploadResultFields[] = [];
      // MAX_CONCURRENT_UPLOADS (file-upload.ts) is private; keep 4 in step
      // with it.
      for (let i = 0; i < 4; i++) {
        const begun = mgr.begin({ requestId: `s${i}`, fileName: `f${i}.bin`, size: 10 }, (r) => collected.push(r));
        expect(begun.ok).toBe(true);
      }
      const src = join(sourceDir, "c.bin");
      writeFileSync(src, "x");
      const result = await mgr.copyLocal({ requestId: "r5", fileName: "c.bin", sourcePath: src });
      expect(result.ok).toBe(false);
      expect(result.error).toBe("BUSY");
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
