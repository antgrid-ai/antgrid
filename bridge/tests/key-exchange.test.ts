import { describe, test, expect } from "bun:test";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";

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

  test("each call generates unique keypair", () => {
    const a = generateEphemeralKeypair();
    const b = generateEphemeralKeypair();
    expect(a.publicKey.toString("hex")).not.toBe(b.publicKey.toString("hex"));
    expect(a.privateKey.toString("hex")).not.toBe(b.privateKey.toString("hex"));
  });
});
