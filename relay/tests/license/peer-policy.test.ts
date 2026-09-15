import { expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { handlePeerPolicy, type InternalRouteDeps } from "../../src/license/internal-routes";

const secret = "test-peer-policy-private-secret";
function request(body: unknown, signed = true) {
  const raw = JSON.stringify(body);
  return new Request("https://relay.test/internal/peer-policy", {
    method: "POST", body: raw, headers: {
      "x-antgrid-signature": signed ? createHmac("sha256", secret).update(raw).digest("hex") : "wrong",
    },
  });
}
function setup(result = 1) {
  const sent: { userId: string; value: unknown }[] = [];
  const users = ["owner", "other"];
  const deps = {
    relayInternalSecret: secret,
    connections: {
      getConnectionsForUser: (userId: string) => users.filter((value) => value === userId).map((value) => ({
        ws: { readyState: 1, send: (message: string) => {
          sent.push({ userId: value, value: JSON.parse(message) });
          return result;
        } },
      })),
    },
  } as unknown as InternalRouteDeps;
  return { deps, sent };
}
test("policy push is account scoped and preserves decimal generations", async () => {
  const { deps, sent } = setup();
  const response = await handlePeerPolicy(request({ userId: "owner", generation: "9007199254740993", issuedAt: Date.now() }), deps);
  expect(response.status).toBe(200);
  expect(sent).toEqual([{ userId: "owner", value: { type: "peer-policy-changed", generation: "9007199254740993" } }]);
});
test("bad signatures and stale pushes never dispatch", async () => {
  const { deps, sent } = setup();
  expect((await handlePeerPolicy(request({ userId: "owner", generation: "1", issuedAt: Date.now() }, false), deps)).status).toBe(401);
  expect((await handlePeerPolicy(request({ userId: "owner", generation: "1", issuedAt: Date.now() - 31_000 }), deps)).status).toBe(401);
  expect(sent).toEqual([]);
});
test("dropped pushes remain retryable by the transactional outbox", async () => {
  const { deps } = setup(0);
  expect((await handlePeerPolicy(request({ userId: "owner", generation: "1", issuedAt: Date.now() }), deps)).status).toBe(503);
});
