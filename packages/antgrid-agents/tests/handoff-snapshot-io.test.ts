import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ByteBudget,
  HandoffSnapshotError,
  copyWholeLines,
  openMaybeZstd,
  safeJoin,
  writePrefix,
  writeText,
} from "../src/agents/handoff";

let root: string;
let out: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "handoff-io-"));
  out = join(root, "out");
  mkdirSync(out);
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

const sha = (buf: Uint8Array | string) => createHash("sha256").update(buf).digest("hex");

async function rejection(promise: Promise<unknown>): Promise<HandoffSnapshotError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(HandoffSnapshotError);
    return error as HandoffSnapshotError;
  }
  throw new Error("expected a rejection");
}

test("copyWholeLines drops a torn final line and never writes a partial record", async () => {
  const src = join(root, "src.jsonl");
  writeFileSync(src, '{"a":1}\n{"b":2}\n{"c":');
  const file = await copyWholeLines(src, out, "t.jsonl", "transcript", new ByteBudget());
  expect(readFileSync(join(out, "t.jsonl"), "utf8")).toBe('{"a":1}\n{"b":2}\n');
  expect(file).toMatchObject({ name: "t.jsonl", role: "transcript", bytes: 16, sha256: sha('{"a":1}\n{"b":2}\n') });
});

test("copyWholeLines streams a file larger than its chunk and hashes it correctly", async () => {
  const src = join(root, "big.jsonl");
  // A single 700 KB line spans several read chunks; it must come through whole.
  const body = `${JSON.stringify({ text: "x".repeat(700_000) })}\n${JSON.stringify({ n: 2 })}\npartial`;
  writeFileSync(src, body);
  const file = await copyWholeLines(src, out, "big.jsonl", "transcript", new ByteBudget());
  const expected = body.slice(0, body.lastIndexOf("\n") + 1);
  expect(readFileSync(join(out, "big.jsonl"), "utf8")).toBe(expected);
  expect(file.sha256).toBe(sha(expected));
  expect(file.bytes).toBe(Buffer.byteLength(expected));
});

test("writePrefix refuses an offset that is not on a line boundary", async () => {
  const src = join(root, "r.jsonl");
  writeFileSync(src, '{"a":1}\n{"b":2}\n');
  const source = (await openMaybeZstd(src))!;
  const meta = { role: "segment" as const };
  const ok = await writePrefix(source, 8, out, "ok.jsonl", meta, new ByteBudget());
  expect(readFileSync(join(out, "ok.jsonl"), "utf8")).toBe('{"a":1}\n');
  expect(ok.sourceRange).toEqual({ start: 0, end: 8 });
  expect((await rejection(writePrefix(source, 5, out, "bad.jsonl", meta, new ByteBudget()))).code).toBe("UNREADABLE");
  expect((await rejection(writePrefix(source, 999, out, "long.jsonl", meta, new ByteBudget()))).code).toBe("UNREADABLE");
});

test("openMaybeZstd reads the .zst spelling when the plain rollout is gone", async () => {
  const plain = join(root, "rollout.jsonl");
  const text = '{"a":1}\n{"b":2}\n';
  writeFileSync(`${plain}.zst`, Bun.zstdCompressSync(Buffer.from(text)));
  const source = await openMaybeZstd(plain);
  expect(source).toMatchObject({ compressed: true, path: `${plain}.zst` });
  let got = "";
  for await (const chunk of source!.open()) got += Buffer.from(chunk).toString("utf8");
  expect(got).toBe(text);
  expect(await openMaybeZstd(join(root, "missing.jsonl"))).toBeUndefined();
});

test("openMaybeZstd decompresses incrementally rather than in one buffer", async () => {
  const text = "line of rollout text\n".repeat(200_000);
  const path = join(root, "big.jsonl.zst");
  writeFileSync(path, Bun.zstdCompressSync(Buffer.from(text)));
  let chunks = 0;
  let bytes = 0;
  for await (const chunk of (await openMaybeZstd(path))!.open()) {
    chunks += 1;
    bytes += chunk.length;
  }
  expect(bytes).toBe(text.length);
  expect(chunks).toBeGreaterThan(10);
});

test("the byte budget counts decompressed bytes, not the .zst size", async () => {
  const path = join(root, "zeros.jsonl.zst");
  const text = `${"0".repeat(9_999)}\n`;
  writeFileSync(path, Bun.zstdCompressSync(Buffer.from(text)));
  const source = (await openMaybeZstd(path))!;
  expect(readFileSync(path).length).toBeLessThan(200);
  const error = await rejection(writePrefix(source, 10_000, out, "z.jsonl", { role: "segment" }, new ByteBudget(1_000)));
  expect(error.code).toBe("TOO_LARGE");
});

test("an aborted deadline stops a copy with UNREADABLE", async () => {
  const src = join(root, "src.jsonl");
  writeFileSync(src, '{"a":1}\n');
  const controller = new AbortController();
  controller.abort();
  const error = await rejection(copyWholeLines(src, out, "t.jsonl", "transcript", new ByteBudget(undefined, controller.signal)));
  expect(error.code).toBe("UNREADABLE");
});

test("a write stopped by the deadline leaves no partial file for a caller that carries on", async () => {
  const controller = new AbortController();
  controller.abort();
  await rejection(writeText(out, "sidecar.txt", "x", "sidecar", new ByteBudget(undefined, controller.signal)));
  expect(readdirSync(out)).toEqual([]);
});

test("an output-side failure is WRITE, not a store-read failure", async () => {
  const src = join(root, "src.jsonl");
  writeFileSync(src, '{"a":1}\n');
  const missing = join(root, "no-such-dir");
  const error = await rejection(copyWholeLines(src, missing, "t.jsonl", "transcript", new ByteBudget()));
  expect(error.code).toBe("WRITE");
  expect(error.errno).toBe("ENOENT");
  expect((await rejection(writeText(missing, "n.txt", "x", "sidecar", new ByteBudget()))).code).toBe("WRITE");
});

test("writeText writes and hashes the text", async () => {
  const file = await writeText(out, "note.txt", "héllo\n", "sidecar", new ByteBudget());
  expect(file).toEqual({ name: "note.txt", role: "sidecar", bytes: 7, sha256: sha("héllo\n") });
});

test("safeJoin rejects traversal, absolute, subdirectory, uppercase, reserved device and trailing-dot names", () => {
  for (const bad of ["../x", "/etc/passwd", "C:\\x", "a/b", "A.jsonl", "con", "NUL.txt", "com1.log", "lpt9", "name.", "", ".hidden", "a b"]) {
    expect(() => safeJoin(out, bad)).toThrow(HandoffSnapshotError);
  }
  expect(safeJoin(out, "codex-rollout-01.jsonl")).toBe(join(out, "codex-rollout-01.jsonl"));
  expect(safeJoin(out, "console.txt")).toBe(join(out, "console.txt"));
});

test("copy refuses a symlinked source", async () => {
  const target = join(root, "real.jsonl");
  writeFileSync(target, '{"a":1}\n');
  const link = join(root, "link.jsonl");
  try {
    symlinkSync(target, link);
  } catch {
    return; // Windows without symlink privilege cannot build the fixture.
  }
  expect((await rejection(copyWholeLines(link, out, "t.jsonl", "transcript", new ByteBudget()))).code).toBe("UNREADABLE");
  expect((await rejection(openMaybeZstd(link))).code).toBe("UNREADABLE");
});
