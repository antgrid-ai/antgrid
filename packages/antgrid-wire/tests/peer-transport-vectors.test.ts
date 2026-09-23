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
  StreamOpen,
  StreamRefused,
  StreamRefusedCode,
  TRANSFER_TIMEOUT_MS,
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
