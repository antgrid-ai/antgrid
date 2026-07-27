import { expect, test } from "bun:test";
import { buildConnectUri } from "../src/connect-uri";

test("the connect URI carries coordinates only — no pair code", () => {
  const uri = buildConnectUri({
    relayUrl: "wss://relay.example",
    agentDeviceId: "dev-1",
    agentEd25519PublicKey: Buffer.alloc(32, 7),
    agentName: "box",
  });
  const q = new URL(uri.replace("antgrid://", "https://")).searchParams;
  expect(q.get("p")).toBeNull();
  expect(q.get("d")).toBe("dev-1");
  expect(q.get("v")).toBe("1");
});

test("appends h= when hostMachineName provided", () => {
  const uri = buildConnectUri({
    relayUrl: "wss://r", agentDeviceId: "dev.proj",
    agentEd25519PublicKey: Buffer.alloc(32),
    agentName: "antgrid", hostMachineName: "Mac Studio",
  });
  const h = new URL(uri).searchParams.get("h");
  expect(h).not.toBeNull();
  expect(Buffer.from(h!, "base64url").toString("utf8")).toBe("Mac Studio");
});

test("omits h= when hostMachineName absent", () => {
  const uri = buildConnectUri({
    relayUrl: "wss://r", agentDeviceId: "dev.proj",
    agentEd25519PublicKey: Buffer.alloc(32),
    agentName: "antgrid",
  });
  expect(new URL(uri).searchParams.get("h")).toBeNull();
});
