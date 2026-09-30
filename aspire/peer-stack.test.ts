import { afterAll, expect, test } from "bun:test";
import { TOML } from "bun";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { preparePeerStack, relayToml } from "./peer-stack.js";

// The stock relay ignores unknown keys and defaults `access` to Everyone, so a
// misplaced or misspelt key here yields an open relay with no startup error.
// These assertions pin the exact key set rather than probing for presence.

const ROOT_KEYS = ["access", "enable_quic_addr_discovery", "http_bind_addr", "limits", "metrics_bind_addr"];
const LOOPBACK = /^127\.0\.0\.1:\d+$/;

// A scratch root: preparePeerStack writes `.tmp/aspire-iroh/relay.toml` under
// it, and the real checkout's copy is the running dev stack's config.
const scratch = mkdtempSync(join(tmpdir(), "peer-stack-test-"));
mkdirSync(join(scratch, "web"));
writeFileSync(join(scratch, "web/.env"), `RELAY_INTERNAL_SECRET=${"s".repeat(64)}\n`);
afterAll(() => rmSync(scratch, { recursive: true, force: true }));

function rootKeysBeforeFirstTable(content: string) {
  const lines = content.split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  const firstTable = lines.findIndex((l) => l.startsWith("["));
  expect(firstTable).toBeGreaterThan(0);
  return { before: lines.slice(0, firstTable).map((l) => l.split("=")[0]!.trim()) };
}

function relayQuery(parsed: any) {
  const access = new URL(parsed.access.http.url);
  expect(`${access.origin}${access.pathname}`).toBe("http://127.0.0.1:8787/internal/iroh-access");
  expect([...access.searchParams.keys()]).toEqual(["relay"]);
  return access.searchParams.get("relay");
}

test("cleartext: the file the stack writes is loopback-only, gated by access.http, and holds no token", () => {
  const stack = preparePeerStack(scratch, { ANTGRID_DEV_INSECURE_RELAY: "true" }, "192.168.1.5");
  const content = readFileSync(stack.config, "utf8");
  const parsed = TOML.parse(content) as any;

  expect(Object.keys(parsed).sort()).toEqual(ROOT_KEYS);
  const { before } = rootKeysBeforeFirstTable(content);
  expect(before.sort()).toEqual(["enable_quic_addr_discovery", "http_bind_addr", "metrics_bind_addr"]);
  expect(Object.keys(parsed.access)).toEqual(["http"]);
  expect(Object.keys(parsed.access.http)).toEqual(["url"]);

  expect(parsed.http_bind_addr).toBe(`127.0.0.1:${stack.nativePort}`);
  expect(parsed.metrics_bind_addr).toMatch(LOOPBACK);
  expect(parsed.metrics_bind_addr).not.toBe("127.0.0.1:9090");
  expect(parsed.enable_quic_addr_discovery).toBe(false);
  expect(parsed.tls).toBeUndefined();
  expect(parsed.limits.accept_conn_limit).toBeGreaterThan(0);
  expect(parsed.limits.client.rx.bytes_per_second).toBeGreaterThan(0);

  expect(stack.url).toBe("http://192.168.1.5:3000/");
  expect(relayQuery(parsed)).toBe(stack.url);

  expect(stack.accessToken).toMatch(/^[0-9a-f]{64}$/);
  expect(content.includes(stack.accessToken)).toBe(false);
  expect(content.includes(stack.internalSecret)).toBe(false);
  expect(JSON.parse(stack.policyTargets)).toEqual([
    { url: "http://127.0.0.1:3001/internal/peer-policy", secret: stack.internalSecret },
  ]);
});

test("each run mints a fresh access token", () => {
  const a = preparePeerStack(scratch, { ANTGRID_DEV_INSECURE_RELAY: "true" }, "192.168.1.5");
  const b = preparePeerStack(scratch, { ANTGRID_DEV_INSECURE_RELAY: "true" }, "192.168.1.5");
  expect(a.accessToken).not.toBe(b.accessToken);
});

test("TLS: https on loopback 443, a non-80 loopback captive portal, and Manual certificates", () => {
  const url = "https://dev-relay.example:3000/";
  const content = relayToml({ url, tls: { cert: "C:\\private\\dev relay\\fullchain.pem", key: "/etc/relay/privkey.pem" } });
  const parsed = TOML.parse(content) as any;

  expect(Object.keys(parsed).sort()).toEqual([...ROOT_KEYS, "tls"].sort());
  const { before } = rootKeysBeforeFirstTable(content);
  expect(before.sort()).toEqual(["enable_quic_addr_discovery", "http_bind_addr", "metrics_bind_addr"]);

  expect(parsed.http_bind_addr).toMatch(LOOPBACK);
  expect(parsed.http_bind_addr).not.toBe("127.0.0.1:80");
  expect(parsed.metrics_bind_addr).toMatch(LOOPBACK);
  expect(parsed.tls).toEqual({
    cert_mode: "Manual",
    https_bind_addr: "127.0.0.1:443",
    manual_cert_path: "C:\\private\\dev relay\\fullchain.pem",
    manual_key_path: "/etc/relay/privkey.pem",
  });
  expect(parsed.http_bind_addr).not.toBe(parsed.tls.https_bind_addr);
  expect(relayQuery(parsed)).toBe(url);
});

test("the relay query survives characters that would otherwise split or truncate it", () => {
  for (const url of ["http://[fd00::5]:3000/", "https://relay.example:3000/?x=1&relay=evil#frag"]) {
    expect(relayQuery(TOML.parse(relayToml({ url })))).toBe(url);
  }
});
