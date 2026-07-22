import { describe, test, expect } from "bun:test";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import { deriveSessionKeys, E2eTransport, buildTranscript } from "../src/e2e";

describe("key-exchange", () => {
  test("generates 32-byte public and private keys", () => {
    const kp = generateEphemeralKeypair();
    expect(kp.publicKey.length).toBe(32);
    expect(kp.privateKey.length).toBe(32);
  });

  test("two keypairs derive the same shared secret", () => {
    const alice = generateEphemeralKeypair();
    const bob = generateEphemeralKeypair();

    const secretA = deriveSharedSecret(alice.privateKey, bob.publicKey);
    const secretB = deriveSharedSecret(bob.privateKey, alice.publicKey);

    expect(secretA.toString("hex")).toBe(secretB.toString("hex"));
  });

  test("wrong keypair derives different secret", () => {
    const alice = generateEphemeralKeypair();
    const bob = generateEphemeralKeypair();
    const eve = generateEphemeralKeypair();

    const correct = deriveSharedSecret(alice.privateKey, bob.publicKey);
    const wrong = deriveSharedSecret(eve.privateKey, bob.publicKey);

    expect(correct.toString("hex")).not.toBe(wrong.toString("hex"));
  });

  test("shared secret works with E2eTransport seal/open (v2 directional keys)", () => {
    const alice = generateEphemeralKeypair();
    const bob = generateEphemeralKeypair();
    const nonce = Buffer.alloc(8, 0x42);

    // Simulate agent = alice, phone = bob
    const transcript = buildTranscript({
      registrationId: "agent.proj",
      role: "agent",
      agentDeviceId: "agent.proj",
      phoneDeviceId: "phone-1",
      agentX25519Pub: alice.publicKey,
      phoneX25519Pub: bob.publicKey,
      nonce,
    });

    // Agent derives keys
    const secretA = deriveSharedSecret(alice.privateKey, bob.publicKey);
    const keysA = deriveSessionKeys(Buffer.from(secretA), transcript);
    const transportA = new E2eTransport({ sendKey: keysA.a2p, recvKey: keysA.p2a });

    // Phone derives keys (must use a fresh copy of transcript for same derivation)
    const transcriptForPhone = buildTranscript({
      registrationId: "agent.proj",
      role: "agent",
      agentDeviceId: "agent.proj",
      phoneDeviceId: "phone-1",
      agentX25519Pub: alice.publicKey,
      phoneX25519Pub: bob.publicKey,
      nonce,
    });
    const secretB = deriveSharedSecret(bob.privateKey, alice.publicKey);
    const keysB = deriveSessionKeys(Buffer.from(secretB), transcriptForPhone);
    const transportB = new E2eTransport({ sendKey: keysB.p2a, recvKey: keysB.a2p });

    const sealed = transportA.seal("hello ephemeral");
    expect(transportB.open(sealed)).toBe("hello ephemeral");
  });

  test("each call generates unique keypair", () => {
    const a = generateEphemeralKeypair();
    const b = generateEphemeralKeypair();
    expect(a.publicKey.toString("hex")).not.toBe(b.publicKey.toString("hex"));
    expect(a.privateKey.toString("hex")).not.toBe(b.privateKey.toString("hex"));
  });
});
