// bridge/tests/session-bus-message-log.test.ts
import { test, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendLog,
  emptyLog,
  entriesForContext,
  loadMessageLog,
  saveMessageLog,
} from "../src/session-bus/message-log";
import { checkEnvelopeSize, envelopeBytes, stampEnvelope } from "../src/session-bus/envelope";
import { busDbPath } from "../src/session-bus/bus-db";
import {
  MAX_ENVELOPE_BYTES,
  MAX_LOGGED_PART_CHARS,
  MAX_LOG_ENTRIES,
} from "../src/session-bus/constants";
import type { SessionMemberKey, SessionMemberRef } from "../src/protocol";

const PEER_KEY: SessionMemberKey = { machineId: "m2", projectId: "p2", sessionId: "s2" };
const PEER: SessionMemberRef = { ...PEER_KEY, machineLabel: "Laptop" };
const T0 = 4_000_000;

function env(over: { taskId?: string | null; contextId?: string; text?: string; messageId?: string } = {}) {
  return stampEnvelope(
    {
      taskId: over.taskId === undefined ? "t1" : over.taskId,
      contextId: over.contextId ?? "c1",
      parts: [{ kind: "text", text: over.text ?? "the suite is green" }],
      summary: "reporting back",
    },
    { messageId: over.messageId ?? "m-1", peer: PEER, now: T0 },
  );
}

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-log-"));
}

test("entries append in order and are addressable by context", () => {
  let s = emptyLog();
  s = appendLog(s, { at: T0, direction: "out", peer: PEER_KEY, envelope: env() });
  s = appendLog(s, { at: T0 + 1, direction: "in", peer: PEER_KEY, envelope: env({ messageId: "m-2" }) });
  s = appendLog(s, {
    at: T0 + 2,
    direction: "in",
    peer: PEER_KEY,
    envelope: env({ taskId: null, contextId: "c2", messageId: "m-3" }),
  });

  expect(s.entries.map((e) => e.direction)).toEqual(["out", "in", "in"]);
  expect(entriesForContext(s, "c2").map((e) => e.envelope.messageId)).toEqual(["m-3"]);
});

test("a long text part is trimmed on the way in", () => {
  const long = "x".repeat(MAX_LOGGED_PART_CHARS * 3);
  const s = appendLog(emptyLog(), { at: T0, direction: "in", peer: PEER_KEY, envelope: env({ text: long }) });
  const part = s.entries[0]!.envelope.parts[0]!;
  expect(part.kind).toBe("text");
  if (part.kind === "text") expect(part.text).toHaveLength(MAX_LOGGED_PART_CHARS);
});

test("the ring drops the oldest past the cap", () => {
  let s = emptyLog();
  for (let i = 0; i < MAX_LOG_ENTRIES + 10; i += 1) {
    s = appendLog(s, { at: T0 + i, direction: "out", peer: PEER_KEY, envelope: env({ messageId: `m-${i}` }) });
  }
  expect(s.entries).toHaveLength(MAX_LOG_ENTRIES);
  expect(s.entries[0]!.envelope.messageId).toBe("m-10");
});

test("the log round-trips, and one unreadable row costs one entry rather than the log", () => {
  const abDir = tmpAbDir();
  try {
    let s = appendLog(emptyLog(), { at: T0, direction: "out", peer: PEER_KEY, envelope: env() });
    s = appendLog(s, { at: T0 + 1, direction: "in", peer: PEER_KEY, envelope: env({ messageId: "m-2" }) });
    saveMessageLog(abDir, "p1", "s1", s);
    const back = loadMessageLog(abDir, "p1", "s1");
    expect(back.entries).toHaveLength(2);
    expect(back.entries[0]!.peer).toEqual(PEER_KEY);
    expect(back.entries[0]!.envelope.metadata.summary).toBe("reporting back");
    // Append order is the ring's order, and it has to survive the round trip:
    // the cap drops from the front, so a log that came back reversed would
    // evict the newest entries first.
    expect(back.entries.map((e) => e.envelope.messageId)).toEqual(["m-1", "m-2"]);

    // A record this bridge cannot read, written the only way one can be. The
    // JSON store this replaced answered a single bad entry by emptying the
    // whole log; this one loses the entry alone.
    const raw = new Database(busDbPath(abDir));
    try {
      raw.query("UPDATE bus_messages SET entry = ? WHERE sessionId = ? AND seq = (SELECT MIN(seq) FROM bus_messages)")
        .run("{half a wri", "s1");
    } finally {
      raw.close();
    }
    expect(loadMessageLog(abDir, "p1", "s1").entries.map((e) => e.envelope.messageId)).toEqual(["m-2"]);

    expect(loadMessageLog(abDir, "p1", "never-written").entries).toEqual([]);
    // Another session's log is not this one's, even under the same project.
    expect(loadMessageLog(abDir, "p-other", "s1").entries).toEqual([]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("stampEnvelope owns every bridge field and the size cap reads the serialized form", () => {
  const e = env();
  expect(e.metadata.peer).toEqual(PEER);
  expect(e.metadata.timestamp).toBe(T0);
  expect(checkEnvelopeSize(e)).toBeNull();

  const huge = env({ text: "y".repeat(MAX_ENVELOPE_BYTES) });
  expect(envelopeBytes(huge)).toBeGreaterThan(MAX_ENVELOPE_BYTES);
  expect(checkEnvelopeSize(huge)).toBe("ENVELOPE_TOO_LARGE");
});
