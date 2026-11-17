// Generates evals/fixtures/relay-envelope-vectors.json — golden samples for
// every relay control-envelope variant (ClientMessage/ServerMessage unions).
// Cross-language pin for the hand-mirrored Dart schemas: the TS test
// (tests/relay-envelope-vectors.test.ts) asserts every union variant and
// ErrorCode has a vector that parses, and the Dart test
// (packages/antgrid_relay_client/test/relay_envelope_vectors_test.dart)
// parses/emits the same JSON through the mirror — so a wire-schema change
// that isn't mirrored fails a test instead of failing at runtime on a device.
//
// The pin is SHAPE-level: field names, types, and required/optional-ness.
// Field values (incl. each error's `retryable`) are realistic samples, not
// relay behavior — the relay remains the authority on the error contract.
// Run: cd packages/antgrid-wire && bun run scripts/gen-envelope-vectors.ts
import { ClientMessage, ErrorCode, ServerMessage } from "../src/relay-protocol";

const TS = "2026-07-16T00:00:00.000Z";
const SLOT = "11111111-1111-4111-8111-111111111111#22222222-2222-4222-8222-222222222222";
const AGENT_ID = "33333333-3333-4333-8333-333333333333";
const BUS_ID = "44444444-4444-4444-8444-444444444444";
const BLOB = { epk: "n/YgTWG1mp5hr91k/fKUv+ihZoe6BTiCO6Wdtst7If8=", box: "A".repeat(44) };
const SIG = "ORt1T7qaueHx0g0ap3NMClaJ9w8PNPExKuLAdj/7vyM4NWy4hPKZHTnjyrAjl9g0++0HxsOTD2QowObKBZlNBg==";

// Sample retryable flags only — realistic, but the relay decides for real.
const RETRYABLE_SAMPLE = new Set([
  "MESSAGE_RATE_LIMITED",
  "LICENSE_UNAVAILABLE",
]);

// `dart` records what the Dart mirror does with each server frame:
// "parsed" — parseRelayMessage returns the typed message; "tolerated" —
// falls through to null (agent-only frames the app must ignore, not fatal).
const server: Array<{ name: string; dart: "parsed" | "tolerated"; json: unknown }> = [
  {
    name: "welcome",
    dart: "parsed",
    json: { type: "welcome", deviceId: SLOT, epoch: 1752624000, serverTime: TS },
  },
  // Agents get `bus`; Dart ignores unknown keys, so the mirror must still parse it.
  {
    name: "welcome:bus",
    dart: "parsed",
    json: { type: "welcome", deviceId: AGENT_ID, epoch: 1752624000, serverTime: TS, bus: 1 },
  },
  ...ErrorCode.options.map((code) => ({
    name: `error:${code}`,
    dart: "parsed" as const,
    json: {
      type: "error",
      code,
      message: `sample ${code}`,
      retryable: RETRYABLE_SAMPLE.has(code),
      // Optional fields pinned on their documented carriers.
      ...(code === "AUTH_FAILED" ? { serverTime: TS } : {}),
    },
  })),
  { name: "peer-online", dart: "parsed", json: { type: "peer-online", peerId: AGENT_ID } },
  { name: "peer-offline", dart: "parsed", json: { type: "peer-offline", peerId: AGENT_ID } },
  { name: "pong", dart: "parsed", json: { type: "pong" } },
  { name: "peer-policy-changed", dart: "parsed", json: { type: "peer-policy-changed", generation: "9007199254740993" } },
  {
    name: "push:result",
    dart: "tolerated",
    json: { type: "push:result", pushToken: "tok-1", ok: false, reason: "unregistered" },
  },
  { name: "bus:receipt", dart: "tolerated", json: { type: "bus:receipt", id: BUS_ID, to: AGENT_ID, state: "queued" } },
  { name: "bus:deliver", dart: "tolerated", json: { type: "bus:deliver", id: BUS_ID, from: AGENT_ID, blob: BLOB } },
  { name: "bus:acked", dart: "tolerated", json: { type: "bus:acked", id: BUS_ID, to: AGENT_ID, outcome: "applied", sig: SIG } },
  {
    name: "bus:acked:refused",
    dart: "tolerated",
    json: { type: "bus:acked", id: BUS_ID, to: AGENT_ID, outcome: "refused", code: "STALE", sig: SIG },
  },
  {
    name: "bus:refused",
    dart: "tolerated",
    json: { type: "bus:refused", id: BUS_ID, to: AGENT_ID, reason: "queue-full", retryable: true },
  },
];

// `dartEmits` — true when the Dart client constructs and sends this frame;
// the Dart test asserts its toJson() equals the vector byte-for-byte.
// push:deliver is bridge-only (TS both ends).
const client: Array<{ name: string; dartEmits: boolean; json: unknown }> = [
  {
    name: "hello",
    dartEmits: true,
    json: {
      type: "hello",
      protocolVersion: 3,
      deviceType: "app",
      deviceId: SLOT,
      name: "Deterministic Phone",
      publicKey: "n/YgTWG1mp5hr91k/fKUv+ihZoe6BTiCO6Wdtst7If8=",
      epoch: 1752624000,
      licenseToken: "test-license-token.deterministic.payload",
      ts: TS,
      nonce: "BwcHBwcHBwcHBwcHBwcHBw==",
      sig: "ORt1T7qaueHx0g0ap3NMClaJ9w8PNPExKuLAdj/7vyM4NWy4hPKZHTnjyrAjl9g0++0HxsOTD2QowObKBZlNBg==",
    },
  },
  { name: "ping", dartEmits: true, json: { type: "ping" } },
  {
    name: "push:deliver",
    dartEmits: false,
    json: {
      type: "push:deliver",
      pushToken: "tok-1",
      provider: "fcm",
      blob: { epk: "n/YgTWG1mp5hr91k/fKUv+ihZoe6BTiCO6Wdtst7If8=", box: "BwcHBwcHBwcHBwcHBwcHBw==" },
    },
  },
  {
    name: "hello:bus",
    dartEmits: false,
    json: {
      type: "hello",
      protocolVersion: 3,
      deviceType: "agent",
      deviceId: AGENT_ID,
      name: "Deterministic Agent",
      publicKey: "n/YgTWG1mp5hr91k/fKUv+ihZoe6BTiCO6Wdtst7If8=",
      epoch: 1752624000,
      licenseToken: "test-license-token.deterministic.payload",
      ts: TS,
      nonce: "BwcHBwcHBwcHBwcHBwcHBw==",
      sig: SIG,
      bus: 1,
    },
  },
  { name: "bus:send", dartEmits: false, json: { type: "bus:send", id: BUS_ID, to: AGENT_ID, blob: BLOB, ttlMs: 60000 } },
  { name: "bus:ack", dartEmits: false, json: { type: "bus:ack", id: BUS_ID, outcome: "applied", sig: SIG } },
  {
    name: "bus:ack:refused",
    dartEmits: false,
    json: { type: "bus:ack", id: BUS_ID, outcome: "refused", code: "STALE", sig: SIG },
  },
  { name: "bus:drain", dartEmits: false, json: { type: "bus:drain" } },
];

// A fixture that fails its own schema must never be written.
for (const v of server) ServerMessage.parse(v.json);
for (const v of client) ClientMessage.parse(v.json);

const out = {
  comment:
    "Golden control-envelope samples. Shape pin only — values (incl. retryable) are samples, not relay behavior. Regenerate: cd packages/antgrid-wire && bun run scripts/gen-envelope-vectors.ts",
  server,
  client,
};

await Bun.write(
  new URL("../../../evals/fixtures/relay-envelope-vectors.json", import.meta.url),
  JSON.stringify(out, null, 2) + "\n",
);
console.log("wrote evals/fixtures/relay-envelope-vectors.json");
