import { test, expect } from "bun:test";
import { fetchAccountPeerKeys, cachedAccountPeerKeys } from "../src/account-peers";

test("fetchAccountPeerKeys sends Bearer auth and returns a Set of the keys", async () => {
  let seenAuth = "";
  const set = await fetchAccountPeerKeys({
    licenseApiUrl: "https://web.test",
    getToken: () => "tok-123",
    fetchFn: (async (url: string, init: any) => {
      seenAuth = init.headers.authorization;
      expect(url).toBe("https://web.test/account/devices/me/peers");
      return new Response(JSON.stringify({ keys: ["AAAA", "BBBB"] }), { status: 200 });
    }) as unknown as typeof fetch,
  });
  expect(seenAuth).toBe("Bearer tok-123");
  expect(set.has("AAAA")).toBe(true);
  expect(set.size).toBe(2);
});

test("cachedAccountPeerKeys only calls fetchFn once within the TTL", async () => {
  let callCount = 0;
  const getCached = cachedAccountPeerKeys(
    {
      licenseApiUrl: "https://web.test",
      getToken: () => "tok-cache",
      fetchFn: (async (_url: string, _init: any) => {
        callCount++;
        return new Response(JSON.stringify({ keys: ["CCCC"] }), { status: 200 });
      }) as unknown as typeof fetch,
    },
    60_000,
  );

  const first = await getCached();
  const second = await getCached();

  expect(callCount).toBe(1);
  expect(first.has("CCCC")).toBe(true);
  expect(second.has("CCCC")).toBe(true);
});
