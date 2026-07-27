import { describe, it, expect } from "bun:test";
import { buildConnectUri } from "../src/connect-uri";

describe("buildConnectUri (v1)", () => {
  it("starts with antgrid://pair?v=1 and includes required params, no k=, no p=", () => {
    const uri = buildConnectUri({
      relayUrl: "wss://relay.example",
      agentDeviceId: "a1",
      agentEd25519PublicKey: Buffer.alloc(32, 7),
      agentName: "Mac",
    });
    expect(uri).toStartWith("antgrid://pair?v=1&");
    expect(uri).not.toContain("k=");
    expect(uri).not.toContain("p=");
    expect(uri).toContain("e=");
    expect(uri).toContain("d=a1");
    expect(uri).toContain("r=");
    expect(uri).toContain("n=");
  });

  it("decodes the ed25519 pubkey back to the original 32 bytes", () => {
    const ed = Buffer.alloc(32, 7);
    const uri = buildConnectUri({
      relayUrl: "wss://relay.example",
      agentDeviceId: "a1",
      agentEd25519PublicKey: ed,
      agentName: "Project",
    });
    const parsed = new URL(uri);
    const eParam = parsed.searchParams.get("e")!;
    const decoded = Buffer.from(eParam, "base64url");
    expect(decoded.equals(ed)).toBe(true);
  });
});
