import { describe, it, expect } from "bun:test";
import { generateKeyPairSync, createPublicKey } from "node:crypto";
import { loadBusKey } from "../src/session-bus/bus-key";
import { x25519PrivateKeyFromRaw, x25519RawPublicKey, generateEphemeralKeypair } from "../src/key-exchange";
import { registerBusKey } from "../src/heartbeat";

function pair() {
  const kp = generateEphemeralKeypair();
  return { pub: kp.publicKey.toString("base64"), priv: kp.privateKey.toString("base64") };
}

describe("loadBusKey", () => {
  it("accepts a matching pair", () => {
    const { pub, priv } = pair();
    expect(loadBusKey(pub, priv)).toEqual({ publicKey: pub, privateKey: priv });
  });

  it("rejects a 31-byte key", () => {
    const { pub, priv } = pair();
    expect(loadBusKey(Buffer.alloc(31, 1).toString("base64"), priv)).toBeNull();
    expect(loadBusKey(pub, Buffer.alloc(31, 1).toString("base64"))).toBeNull();
  });

  it("rejects halves from different pairs", () => {
    expect(loadBusKey(pair().pub, pair().priv)).toBeNull();
  });

  it("rejects filler that is the right length but not the key", () => {
    const { priv } = pair();
    expect(loadBusKey(Buffer.alloc(32, 1).toString("base64"), priv)).toBeNull();
  });

  it("rejects garbage and missing input", () => {
    expect(loadBusKey("not base64!!", "also not")).toBeNull();
    expect(loadBusKey(undefined, undefined)).toBeNull();
    expect(loadBusKey("", "")).toBeNull();
  });
});

describe("key-exchange raw helpers", () => {
  it("round-trips a raw private key to its raw public key", () => {
    const { publicKey, privateKey } = generateEphemeralKeypair();
    const priv = x25519PrivateKeyFromRaw(privateKey);
    expect(x25519RawPublicKey(createPublicKey(priv)).equals(publicKey)).toBe(true);
  });

  it("reads the raw bytes of a generated public key", () => {
    const { publicKey } = generateKeyPairSync("x25519");
    expect(x25519RawPublicKey(publicKey).length).toBe(32);
  });
});

describe("registerBusKey", () => {
  it("POSTs the key with a bearer token", async () => {
    let url = "";
    let init: RequestInit | undefined;
    const fetchFn = (async (u: string, i?: RequestInit) => {
      url = u;
      init = i;
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;
    const key = pair().pub;
    const ok = await registerBusKey({
      licenseApiUrl: "https://api.example.com",
      getToken: async () => "tok",
      busPublicKey: key,
      fetchFn,
    });
    expect(ok).toBe(true);
    expect(url).toBe("https://api.example.com/account/devices/me/bus-key");
    expect(init?.method).toBe("POST");
    expect((init?.headers as Record<string, string>).authorization).toBe("Bearer tok");
    expect(JSON.parse(init?.body as string)).toEqual({ busPublicKey: key });
  });

  it("reports non-2xx and network failure as false", async () => {
    const base = { licenseApiUrl: "https://x", getToken: () => "t", busPublicKey: pair().pub };
    const refused = (async () => new Response("", { status: 403 })) as unknown as typeof fetch;
    const down = (async () => {
      throw new Error("down");
    }) as unknown as typeof fetch;
    expect(await registerBusKey({ ...base, fetchFn: refused })).toBe(false);
    expect(await registerBusKey({ ...base, fetchFn: down })).toBe(false);
  });
});
