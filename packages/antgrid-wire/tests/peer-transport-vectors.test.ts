import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { buildPeerTransportVectors } from "../scripts/gen-peer-transport-vectors";
import {
  decodePeerFrame,
  FRAG_DATA_BUDGET,
  FRAG_THRESHOLD,
  FrameKind,
  GLOBAL_REASSEMBLY_BUDGET,
  MAX_FRAGMENT_COUNT,
  MAX_REREQUESTS,
  MAX_TRANSFER_BYTES,
  STREAM_PROJECT_RECORD_MAX_BYTES,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  STREAM_TUNNEL_DATA_MAX_BYTES,
  STREAM_TUNNEL_RECORD_MAX_BYTES,
  STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
  StreamOpen,
  StreamRefused,
  StreamRefusedCode,
  TRANSFER_TIMEOUT_MS,
  TUNNEL_RECORD_TAG_BODY,
  TUNNEL_RECORD_TAG_BODY_GZIP,
  TUNNEL_RECORD_TAG_WS_BINARY,
  TUNNEL_RECORD_TAG_WS_TEXT,
} from "../src/index";

const fixturePath = resolve(
  import.meta.dir,
  "../../../evals/fixtures/peer-transport-vectors.json",
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));

test("peer transport fixture is a clean generator product", () => {
  expect(fixture).toEqual(buildPeerTransportVectors());
});

test("peer transport byte vectors decode with no route identity", () => {
  for (const sample of fixture.framing.samples) {
    const decoded = decodePeerFrame(Buffer.from(sample.frameHex, "hex"));
    expect(decoded.header).toEqual(sample.header);
    expect(decoded.header).not.toHaveProperty("to");
    expect(decoded.header).not.toHaveProperty("from");
    expect(sample.kind).toBe(FrameKind.message);
    expect(Buffer.from(decoded.payload).toString("hex")).toBe(sample.payloadHex);
  }
  expect(fixture.framing.kinds).toEqual(FrameKind);
});

test("peer transport fixture covers every stream-open kind and refusal code", () => {
  const streamOpen = fixture.streamOpen;
  expect(streamOpen.opens.map((o: { name: string }) => o.name)).toEqual([
    "session",
    "project",
    "terminal",
    "terminal-with-checkout",
    "tunnel-http",
    "tunnel-ws",
  ]);
  for (const sample of streamOpen.opens) {
    expect(StreamOpen.parse(sample.json)).toEqual(sample.json);
  }
  expect(streamOpen.refusals.map((r: { name: string }) => r.name)).toEqual([
    "not-ready",
    "update-required",
    "not-allowed",
    "cap-exceeded",
    "invalid",
  ]);
  for (const sample of streamOpen.refusals) {
    expect(StreamRefused.parse(sample.json)).toEqual(sample.json);
  }
  // Derived from the schema, not a hand list: a kind or code added to
  // stream-open.ts without a vector must fail here, since the fixture is the
  // Dart mirror's only cross-check.
  const kinds = StreamOpen.options.map((o) => o.shape.kind.value);
  expect(
    new Set(streamOpen.opens.map((o: { json: { kind: string } }) => o.json.kind)),
  ).toEqual(new Set(kinds));
  expect(
    streamOpen.refusals.map((r: { json: { code: string } }) => r.json.code),
  ).toEqual(StreamRefusedCode.options);
});

test("peer transport fixture's projectRecords equals STREAM_PROJECT_RECORD_MAX_BYTES (A4)", () => {
  // The Dart mirror (kStreamProjectRecordMaxBytes) has no import to
  // cross-check against, only this JSON.
  expect(fixture.streamOpen.projectRecords).toEqual({
    maxRecordBytes: STREAM_PROJECT_RECORD_MAX_BYTES,
  });
});

test("peer transport fixture's terminalRecords and tunnelRecords equal the wire package's own constants", () => {
  // The generator imports these constants directly, so this mostly guards
  // against the fixture going stale relative to a regenerate — the Dart
  // mirror has no import to cross-check against, only this JSON.
  expect(fixture.streamOpen.terminalRecords).toEqual({
    appMaxRecordBytes: STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
    bridgeMaxRecordBytes: STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  });
  expect(fixture.streamOpen.tunnelRecords).toEqual({
    maxDataBytes: STREAM_TUNNEL_DATA_MAX_BYTES,
    maxRecordBytes: STREAM_TUNNEL_RECORD_MAX_BYTES,
    requestBodyMaxBytes: STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
    tags: {
      body: TUNNEL_RECORD_TAG_BODY,
      bodyGzip: TUNNEL_RECORD_TAG_BODY_GZIP,
      wsText: TUNNEL_RECORD_TAG_WS_TEXT,
      wsBinary: TUNNEL_RECORD_TAG_WS_BINARY,
    },
  });
});

test("peer transport fixture's rejected stream-open frames are rejected", () => {
  const streamOpen = fixture.streamOpen;
  expect(streamOpen.rejectedOpens.length).toBeGreaterThan(0);
  for (const sample of streamOpen.rejectedOpens) {
    expect(StreamOpen.safeParse(sample.json).success, sample.name).toBe(false);
  }
  expect(streamOpen.rejectedRefusals.length).toBeGreaterThan(0);
  for (const sample of streamOpen.rejectedRefusals) {
    expect(StreamRefused.safeParse(sample.json).success, sample.name).toBe(false);
  }
});

test("peer transport fixture covers every mirrored fragmentation bound", () => {
  expect(fixture.fragmentation).toEqual({
    thresholdBytes: FRAG_THRESHOLD,
    dataBudgetBytes: FRAG_DATA_BUDGET,
    maxTransferBytes: MAX_TRANSFER_BYTES,
    transferTimeoutMs: TRANSFER_TIMEOUT_MS,
    globalReassemblyBudgetBytes: GLOBAL_REASSEMBLY_BUDGET,
    maxRerequests: MAX_REREQUESTS,
    maxFragmentCount: MAX_FRAGMENT_COUNT,
  });
});
