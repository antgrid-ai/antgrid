// Generates evals/fixtures/relay-hello-vector.json from fixed inputs.
// Cross-language pin for buildHelloSigBody: the TS test
// (tests/relay-auth.test.ts) and the Dart test
// (packages/antgrid_relay_client/test/relay_auth_vector_test.dart) both
// assert against this fixture, so the two implementations cannot drift.
// Run: cd packages/antgrid-wire && bun run scripts/gen-hello-vector.ts
import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { buildHelloSigBody, normalizeRelayHost } from "../src/relay-auth";

const ED_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

const seed = Buffer.from("e0".repeat(32), "hex");
const priv = createPrivateKey({
  key: Buffer.concat([ED_PKCS8_PREFIX, seed]), format: "der", type: "pkcs8",
});
const pubDer = createPublicKey(priv).export({ type: "spki", format: "der" });
const pubB64 = Buffer.from(pubDer.subarray(pubDer.length - 32)).toString("base64");

// Non-default port on purpose: pins the host:port normalization branch too.
const relayUrl = "wss://Relay.Antgrid.ai:8443/ws";

const fields = {
  relayHost: normalizeRelayHost(relayUrl),
  deviceType: "agent" as const,
  deviceId: "agent-deterministic",
  publicKey: pubB64,
  epoch: 1752624000,
  licenseToken: "test-license-token.deterministic.payload",
  ts: "2026-07-16T00:00:00.000Z",
  nonce: Buffer.alloc(16, 7).toString("base64"),
};

const sigBody = buildHelloSigBody(fields);
const sigB64 = sign(null, sigBody, priv).toString("base64");

const out = {
  relayUrl,
  fields,
  ed25519: { seedHex: seed.toString("hex"), publicKeyB64: pubB64 },
  sigBodyHex: Buffer.from(sigBody).toString("hex"),
  sigB64,
};

await Bun.write(
  new URL("../../../evals/fixtures/relay-hello-vector.json", import.meta.url),
  JSON.stringify(out, null, 2) + "\n",
);
console.log("wrote evals/fixtures/relay-hello-vector.json");
