// bridge/tests/session-bus-artifact-store.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  addArtifact,
  artifactById,
  artifactsFor,
  checkArtifactSize,
  emptyArtifacts,
  loadArtifacts,
  readArtifactContent,
  saveArtifacts,
  sha256Hex,
  writeArtifactContent,
  type ArtifactRecord,
} from "../src/session-bus/artifact-store";
import {
  ARTIFACT_CHUNK_BYTES,
  MAX_ARTIFACTS,
  MAX_ARTIFACT_BYTES,
} from "../src/session-bus/constants";
import { removeSessionBusSession, sessionBusSessionDir } from "../src/session-bus/store-fs";
import type { SessionMemberRef } from "../src/protocol";

const AUTHOR: SessionMemberRef = { machineId: "m2", projectId: "p2", sessionId: "s2", machineLabel: "Laptop" };
const T0 = 3_000_000;

function rec(over: Partial<ArtifactRecord> = {}): ArtifactRecord {
  const bytes = Buffer.from("diff --git a/x b/x\n");
  return {
    artifactId: "a1",
    contextId: "c1",
    taskId: "t1",
    author: AUTHOR,
    name: "fix.patch",
    mediaType: "text/x-diff",
    bytes: bytes.length,
    sha256: sha256Hex(bytes),
    summary: "the patch that made the suite pass",
    createdAt: T0,
    ...over,
  };
}

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-art-"));
}

test("a handle is added once and is addressable by id and by context", () => {
  let s = addArtifact(emptyArtifacts(), rec());
  s = addArtifact(s, rec({ summary: "a redelivered publish" }));
  s = addArtifact(s, rec({ artifactId: "a2", contextId: "c2", taskId: null }));

  expect(s.artifacts).toHaveLength(2);
  expect(artifactById(s, "a1")!.summary).toBe("the patch that made the suite pass");
  expect(artifactById(s, "nope")).toBeNull();
  expect(artifactsFor(s, "c1").map((a) => a.artifactId)).toEqual(["a1"]);
  expect(artifactsFor(s, "c2")[0]!.taskId).toBeNull();
});

test("the size ceiling is a refusal code, never a throw", () => {
  expect(checkArtifactSize(1)).toBeNull();
  expect(checkArtifactSize(MAX_ARTIFACT_BYTES)).toBeNull();
  expect(checkArtifactSize(MAX_ARTIFACT_BYTES + 1)).toBe("ARTIFACT_TOO_LARGE");
});

test("content round-trips and is fetched in slices with a truthful eof", () => {
  const abDir = tmpAbDir();
  try {
    const data = Buffer.alloc(ARTIFACT_CHUNK_BYTES + 17, 7);
    writeArtifactContent(abDir, "p1", "s1", "a1", data);

    const first = readArtifactContent(abDir, "p1", "s1", "a1", 0, ARTIFACT_CHUNK_BYTES)!;
    expect(first.data).toHaveLength(ARTIFACT_CHUNK_BYTES);
    expect(first.eof).toBe(false);

    const second = readArtifactContent(abDir, "p1", "s1", "a1", ARTIFACT_CHUNK_BYTES, ARTIFACT_CHUNK_BYTES)!;
    expect(second.data).toHaveLength(17);
    expect(second.eof).toBe(true);

    const whole = Buffer.concat([Buffer.from(first.data), Buffer.from(second.data)]);
    expect(sha256Hex(whole)).toBe(sha256Hex(data));

    // A read past the end is empty and at eof, never an error.
    const past = readArtifactContent(abDir, "p1", "s1", "a1", data.length + 100, 10)!;
    expect(past.data).toHaveLength(0);
    expect(past.eof).toBe(true);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("bytes that were never stored read as null, not as an empty artifact", () => {
  const abDir = tmpAbDir();
  try {
    expect(readArtifactContent(abDir, "p1", "s1", "missing", 0, 16)).toBeNull();
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("an artifact survives the session ending: only the delete path removes it", () => {
  const abDir = tmpAbDir();
  try {
    const data = Buffer.from("evidence the peer left behind");
    saveArtifacts(abDir, "p1", "s1", addArtifact(emptyArtifacts(), rec({ bytes: data.length, sha256: sha256Hex(data) })));
    writeArtifactContent(abDir, "p1", "s1", "a1", data);

    // Nothing in stop/archive touches the directory, so a fresh read — the shape
    // a later bridge start has — still finds both halves.
    const back = loadArtifacts(abDir, "p1", "s1");
    expect(artifactById(back, "a1")!.name).toBe("fix.patch");
    const content = readArtifactContent(abDir, "p1", "s1", "a1", 0, 1024)!;
    expect(Buffer.from(content.data).toString("utf8")).toBe("evidence the peer left behind");

    removeSessionBusSession(abDir, "p1", "s1");
    expect(loadArtifacts(abDir, "p1", "s1").artifacts).toEqual([]);
    expect(readArtifactContent(abDir, "p1", "s1", "a1", 0, 1024)).toBeNull();
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("one session's delete leaves another session's artifacts alone", () => {
  const abDir = tmpAbDir();
  try {
    saveArtifacts(abDir, "p1", "s1", addArtifact(emptyArtifacts(), rec()));
    saveArtifacts(abDir, "p1", "s2", addArtifact(emptyArtifacts(), rec({ artifactId: "b1" })));
    removeSessionBusSession(abDir, "p1", "s1");
    expect(loadArtifacts(abDir, "p1", "s2").artifacts).toHaveLength(1);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("past the cap the oldest handle is dropped", () => {
  let s = emptyArtifacts();
  for (let i = 0; i < MAX_ARTIFACTS + 5; i += 1) {
    s = addArtifact(s, rec({ artifactId: `a${i}` }));
  }
  expect(s.artifacts).toHaveLength(MAX_ARTIFACTS);
  expect(artifactById(s, "a0")).toBeNull();
  expect(artifactById(s, `a${MAX_ARTIFACTS + 4}`)).not.toBeNull();
});

test("a corrupt or wrong-version artifact file loads as empty", () => {
  const abDir = tmpAbDir();
  try {
    const dir = sessionBusSessionDir(abDir, "p1", "s1");
    mkdirSync(dir, { recursive: true });
    const path = join(dir, "artifacts.json");

    writeFileSync(path, "]not json[");
    expect(loadArtifacts(abDir, "p1", "s1").artifacts).toEqual([]);

    writeFileSync(path, JSON.stringify({ version: 1, artifacts: [{ artifactId: "a1" }] }));
    expect(loadArtifacts(abDir, "p1", "s1").artifacts).toEqual([]);

    writeFileSync(path, JSON.stringify({ version: 99, artifacts: [] }));
    expect(loadArtifacts(abDir, "p1", "s1").artifacts).toEqual([]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});
