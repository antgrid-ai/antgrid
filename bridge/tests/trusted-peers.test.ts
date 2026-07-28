import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TrustedPeersProvider } from "../src/trusted-peers";

function fakeFetch(
  devices: { deviceId: string; ed25519Pub: string }[],
  calls: { n: number; lastUrl?: string; lastHeaders?: HeadersInit },
) {
  return (async (url: RequestInfo | URL, init?: RequestInit) => {
    calls.n++;
    calls.lastUrl = String(url);
    calls.lastHeaders = init?.headers;
    return new Response(JSON.stringify({ keys: [], devices }), { status: 200 });
  }) as unknown as typeof fetch;
}

function makeProvider(opts: Partial<ConstructorParameters<typeof TrustedPeersProvider>[0]> = {}) {
  const dir = mkdtempSync(join(tmpdir(), "tp-"));
  return new TrustedPeersProvider({
    licenseApiUrl: "http://web.test",
    getToken: () => "t",
    filePath: join(dir, "trusted-peers.json"),
    ...opts,
  });
}

describe("TrustedPeersProvider", () => {
  test("refresh populates lookup and persists; a new instance reads the disk cache", async () => {
    const calls = { n: 0 };
    const p = makeProvider({ fetchFn: fakeFetch([{ deviceId: "d1", ed25519Pub: "k1" }], calls) });
    expect(p.lookup("d1")).toBeUndefined();
    await p.refresh();
    expect(p.lookup("d1")).toBe("k1");
    // durable: a fresh provider on the same file answers without any fetch
    const p2 = new TrustedPeersProvider({
      licenseApiUrl: "http://web.test",
      getToken: () => "t",
      filePath: (p as unknown as { opts: { filePath: string } }).opts.filePath,
    });
    expect(p2.lookup("d1")).toBe("k1");
  });

  test("refresh requests the account-peers URL with a Bearer token from getToken()", async () => {
    const calls: { n: number; lastUrl?: string; lastHeaders?: HeadersInit } = { n: 0 };
    const p = makeProvider({
      licenseApiUrl: "http://web.test",
      getToken: () => "secret-token",
      fetchFn: fakeFetch([{ deviceId: "d1", ed25519Pub: "k1" }], calls),
    });
    await p.refresh();
    expect(calls.lastUrl).toBe("http://web.test/account/devices/me/peers");
    expect(calls.lastHeaders).toEqual({ authorization: "Bearer secret-token" });
  });

  test("noteMiss refreshes at most once per cooldown", async () => {
    const calls = { n: 0 };
    const p = makeProvider({
      fetchFn: fakeFetch([], calls),
      missRefreshCooldownMs: 60_000,
    });
    p.noteMiss();
    p.noteMiss();
    p.noteMiss();
    await Bun.sleep(10);
    expect(calls.n).toBe(1);
  });

  test("failed refresh keeps the previous cache", async () => {
    const calls = { n: 0 };
    const good = fakeFetch([{ deviceId: "d1", ed25519Pub: "k1" }], calls);
    let fail = false;
    const p = makeProvider({
      fetchFn: (async (...args: Parameters<typeof fetch>) => {
        if (fail) return new Response("nope", { status: 500 });
        return good(...args);
      }) as typeof fetch,
    });
    await p.refresh();
    fail = true;
    await p.refresh();
    expect(p.lookup("d1")).toBe("k1");
  });

  test("concurrent refresh() calls collapse into a single fetch (single-flight)", async () => {
    const calls = { n: 0 };
    const p = makeProvider({ fetchFn: fakeFetch([{ deviceId: "d1", ed25519Pub: "k1" }], calls) });
    await Promise.all([p.refresh(), p.refresh()]);
    expect(calls.n).toBe(1);
    expect(p.lookup("d1")).toBe("k1");
  });

  test("a refresh with no devices field keeps the previous cache", async () => {
    const calls = { n: 0 };
    const withDevices = fakeFetch([{ deviceId: "d1", ed25519Pub: "k1" }], calls);
    let ready = false;
    const p = makeProvider({
      fetchFn: (async (...args: Parameters<typeof fetch>) => {
        if (!ready) return withDevices(...args);
        calls.n++;
        return new Response(JSON.stringify({ keys: [] }), { status: 200 });
      }) as typeof fetch,
    });
    await p.refresh();
    expect(p.lookup("d1")).toBe("k1");
    ready = true;
    await p.refresh();
    expect(p.lookup("d1")).toBe("k1");
  });
});
