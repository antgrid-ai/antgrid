import { describe, it, expect } from "bun:test";
import { buildPairingUri } from "../src/pairing";

describe("buildPairingUri (v1)", () => {
  it("starts with antgrid://pair?v=1 and includes required params, no k=", () => {
    const uri = buildPairingUri({
      relayUrl: "wss://relay.example",
      agentDeviceId: "a1",
      agentEd25519PublicKey: Buffer.alloc(32, 7),
      pairCode: "ABC",
      agentName: "Mac",
    });
    expect(uri).toStartWith("antgrid://pair?v=1&");
    expect(uri).not.toContain("k=");
    expect(uri).toContain("e=");
    expect(uri).toContain("d=a1");
    expect(uri).toContain("p=ABC");
    expect(uri).toContain("r=");
    expect(uri).toContain("n=");
  });

  it("encodes pairCode with URI-encoding (handles special chars)", () => {
    const uri = buildPairingUri({
      relayUrl: "wss://relay.example",
      agentDeviceId: "a1",
      agentEd25519PublicKey: Buffer.alloc(32, 2),
      pairCode: "a/b+c=",
      agentName: "Project",
    });
    const parsed = new URL(uri);
    expect(parsed.searchParams.get("p")).toBe("a/b+c=");
  });

  it("decodes the ed25519 pubkey back to the original 32 bytes", () => {
    const ed = Buffer.alloc(32, 7);
    const uri = buildPairingUri({
      relayUrl: "wss://relay.example",
      agentDeviceId: "a1",
      agentEd25519PublicKey: ed,
      pairCode: "c",
      agentName: "Project",
    });
    const parsed = new URL(uri);
    const eParam = parsed.searchParams.get("e")!;
    const decoded = Buffer.from(eParam, "base64url");
    expect(decoded.equals(ed)).toBe(true);
  });
});
