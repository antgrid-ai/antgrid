import { describe, test, expect } from "bun:test";
import { pushRevoke, pushExpire } from "../src/relay/push.js";

describe("relay push", () => {
  test("no-op when baseUrl unset", async () => {
    let called = 0;
    const fetchImpl = (async () => { called++; return new Response(); }) as any;
    await pushRevoke({}, "dev-1", "user-1", fetchImpl);
    expect(called).toBe(0);
  });

  test("POSTs with signed body to /internal/revoke", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response();
    }) as any;
    await pushRevoke({ baseUrl: "http://relay.local", secret: "s" }, "dev-1", "user-1", fetchImpl);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("http://relay.local/internal/revoke");
    expect((calls[0].init.headers as any)["x-antgrid-signature"]).toMatch(/^[0-9a-f]{64}$/);
    // The account scope is load-bearing: the same deviceId exists under other
    // users, and the relay closes sockets by what this body says.
    expect(calls[0].init.body).toBe('{"deviceId":"dev-1","userId":"user-1"}');
  });

  test("POSTs to /internal/expire", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response();
    }) as any;
    await pushExpire({ baseUrl: "http://relay.local", secret: "s" }, "user-1", fetchImpl);
    expect(calls[0].url).toBe("http://relay.local/internal/expire");
    expect(calls[0].init.body).toBe('{"userId":"user-1"}');
  });

  test("swallows fetch errors", async () => {
    const fetchImpl = (async () => { throw new Error("network"); }) as any;
    await pushRevoke({ baseUrl: "http://relay.local", secret: "s" }, "dev-1", "user-1", fetchImpl);
    expect(true).toBe(true);
  });

  test("fetchUserConnections POSTs issuedAt + userId, signed", async () => {
    const { fetchUserConnections } = await import("../src/relay/push.js");
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ connections: [] }), {
        headers: { "content-type": "application/json" },
      });
    }) as any;

    const out = await fetchUserConnections(
      { baseUrl: "http://relay.local", secret: "s" },
      "user-1",
      fetchImpl,
    );
    expect(out).toEqual([]);
    expect(calls[0].url).toBe("http://relay.local/internal/connections");
    expect((calls[0].init.headers as any)["x-antgrid-signature"]).toMatch(/^[0-9a-f]{64}$/);
    const sent = JSON.parse(calls[0].init.body as string) as { issuedAt: number; userId: string };
    expect(sent.userId).toBe("user-1");
    expect(typeof sent.issuedAt).toBe("number");
  });

  test("fetchUserConnections throws when relay config is missing", async () => {
    const { fetchUserConnections } = await import("../src/relay/push.js");
    await expect(fetchUserConnections({}, "user-1")).rejects.toThrow();
  });
});
