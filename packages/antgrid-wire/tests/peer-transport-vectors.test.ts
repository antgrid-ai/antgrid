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
    expect(decoded.kind).toBe(sample.kind);
    expect(Buffer.from(decoded.payload).toString("hex")).toBe(sample.payloadHex);
  }
  expect(fixture.framing.kinds).toEqual(FrameKind);
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
