import { describe, test, expect } from "bun:test";
import { buildPairingUri, generateShortCode } from "../src/pairing";

describe("pairing", () => {
  test("short code matches ANTGRID-XXXX format", () => {
    const pubkey = Buffer.from("abcdefghijklmnopqrstuvwxyz012345");
    const code = generateShortCode(pubkey);
    expect(code).toMatch(/^ANTGRID-[A-Z0-9]{4}$/);
  });

  test("short code is deterministic for same pubkey", () => {
    const pubkey = Buffer.from("test-key-pad-to-32-bytes!!!!!!!!");
    expect(generateShortCode(pubkey)).toBe(generateShortCode(pubkey));
  });

  test("buildPairingUri appends h= when hostMachineName provided", () => {
    const uri = buildPairingUri({
      relayUrl: "wss://r", agentDeviceId: "dev.proj",
      agentEd25519PublicKey: Buffer.alloc(32),
      pairCode: "abc", agentName: "antgrid", hostMachineName: "Mac Studio",
    });
    const h = new URL(uri).searchParams.get("h");
    expect(h).not.toBeNull();
    expect(Buffer.from(h!, "base64url").toString("utf8")).toBe("Mac Studio");
  });

  test("buildPairingUri omits h= when hostMachineName absent", () => {
    const uri = buildPairingUri({
      relayUrl: "wss://r", agentDeviceId: "dev.proj",
      agentEd25519PublicKey: Buffer.alloc(32),
      pairCode: "abc", agentName: "antgrid",
    });
    expect(new URL(uri).searchParams.get("h")).toBeNull();
  });
});
