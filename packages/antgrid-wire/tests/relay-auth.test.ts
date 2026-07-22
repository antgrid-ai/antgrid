import { describe, it, expect } from "bun:test";
import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
import { buildHelloSigBody, normalizeRelayHost, RELAY_AUTH_DOMAIN, type HelloSigFields } from "../src/index";
import fixture from "../../../evals/fixtures/relay-hello-vector.json";

const fixtureFields = fixture.fields as HelloSigFields;

// DER prefixes for raw 32-byte Ed25519 keys (RFC 8410 SubjectPublicKeyInfo /
// PKCS8), needed because node:crypto has no raw-key constructor for Ed25519.
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");

describe("RELAY_AUTH_DOMAIN", () => {
  it("is the v3 domain string", () => {
    expect(RELAY_AUTH_DOMAIN).toBe("antgrid.relay-auth.v3");
  });
});

describe("buildHelloSigBody", () => {
  it("matches the checked-in cross-language vector", () => {
    const body = Buffer.from(buildHelloSigBody(fixtureFields)).toString("hex");
    expect(body).toBe(fixture.sigBodyHex);
  });
});

describe("normalizeRelayHost", () => {
  it("matches the relayHost signed in the fixture", () => {
    expect(normalizeRelayHost(fixture.relayUrl)).toBe(fixture.fields.relayHost);
  });

  it("drops the default wss port 443", () => {
    expect(normalizeRelayHost("wss://relay.antgrid.ai/ws")).toBe("relay.antgrid.ai");
  });

  it("keeps a non-default port", () => {
    expect(normalizeRelayHost("ws://localhost:3000")).toBe("localhost:3000");
  });

  it("drops the default ws port 80 and lowercases the host", () => {
    expect(normalizeRelayHost("ws://LOCALHOST:80")).toBe("localhost");
  });
});

describe("fixture Ed25519 signature", () => {
  const pubKeyDer = Buffer.concat([SPKI_PREFIX, Buffer.from(fixture.ed25519.publicKeyB64, "base64")]);
  const publicKey = createPublicKey({ key: pubKeyDer, format: "der", type: "spki" });
  const body = Buffer.from(fixture.sigBodyHex, "hex");
  const sig = Buffer.from(fixture.sigB64, "base64");

  it("verifies against the fixture public key", () => {
    expect(verify(null, body, publicKey, sig)).toBe(true);
  });

  it("re-signing with the fixture seed reproduces the identical signature (Ed25519 is deterministic)", () => {
    const seed = Buffer.from(fixture.ed25519.seedHex, "hex");
    const privKeyDer = Buffer.concat([PKCS8_PREFIX, seed]);
    const privateKey = createPrivateKey({ key: privKeyDer, format: "der", type: "pkcs8" });
    const resigned = sign(null, body, privateKey);
    expect(resigned.equals(sig)).toBe(true);
  });
});
