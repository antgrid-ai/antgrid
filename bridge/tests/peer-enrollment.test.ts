import { expect, test } from "bun:test";
import { EndpointEnrollment } from "../src/peer/enrollment";
import vector from "../../evals/fixtures/endpoint-registration-vectors.json";

test("device and endpoint enrollment signatures match the cross-language vector", async () => {
  const requests: unknown[] = [];
  const request = (async (url: string | URL | Request, init?: RequestInit) => {
    if (String(url).endsWith("/authorization")) return Response.json({
      accountId: vector.challenge.accountId, deviceId: vector.challenge.deviceId, enrollmentId: vector.challenge.enrollmentId,
      policyGeneration: "1", registrationGeneration: vector.challenge.expectedGeneration, allowed: true,
      leaseMs: 60_000, endpoint: null, peers: [], relayUrls: [],
    });
    requests.push(JSON.parse(String(init?.body)));
    if (String(url).endsWith("/endpoint-challenge")) return Response.json(vector.challenge);
    return Response.json({ endpointId: vector.challenge.endpointId,
      generation: (BigInt(vector.challenge.expectedGeneration) + 1n).toString() });
  }) as typeof fetch;
  const enrollment = new EndpointEnrollment(vector.challenge, vector.endpointSeed, vector.deviceSeed,
    "https://backend.invalid", () => "test-only", request);
  try {
    await enrollment.register();
    expect(enrollment.endpointId).toBe(vector.challenge.endpointId);
    expect(requests).toEqual([
      { endpointId: vector.challenge.endpointId, expectedGeneration: vector.challenge.expectedGeneration },
      { challengeId: vector.challenge.challengeId, deviceSignature: vector.deviceSignature, endpointSignature: vector.endpointSignature },
    ]);
  } finally { enrollment.close(); }
});
