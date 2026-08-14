#!/usr/bin/env bun
// v3-phase-R: this script still speaks the deleted v2 register/challenge
// handshake and v2 RelayConfig shape (maxQueueMessages, stalePairTimeoutHours,
// ...) — it will not run against the v3 relay. It's a manual perf harness, not
// part of `bun test`, so R10 left it unconverted; port it to `hello` +
// epoch/stream-open when someone next needs to load-test the relay. Routing
// under v3 is account-derived (`mayRoute`) — there is no pairing step to port.
/**
 * Load test for the relay server.
 * Usage: bun run tests/load.ts [--pairs N] [--duration S]
 */

import { startServer } from "../src/server.js";
import type { RelayConfig } from "../src/config.js";

const args = process.argv.slice(2);
function getArg(name: string, defaultVal: number): number {
  const idx = args.indexOf(`--${name}`);
  if (idx !== -1 && args[idx + 1]) return parseInt(args[idx + 1], 10);
  return defaultVal;
}

const NUM_PAIRS = getArg("pairs", 100);
const DURATION_S = getArg("duration", 10);
const MSG_INTERVAL_MS = 100; // each pair sends a message every 100ms

console.log(`Load test: ${NUM_PAIRS} pairs, ${DURATION_S}s duration`);

const config: RelayConfig = {
  port: 0,
  maxConnections: NUM_PAIRS * 2 + 10,
  rateLimitConnPerIp: NUM_PAIRS * 2 + 10,
  rateLimitMsgPerSec: 10000,
  rateLimitMsgBurst: 10000,
  pushRateLimitPerSec: 10000,
  jsonRateLimitPerSec: 10000,
  jsonRateLimitBurst: 10000,
  maxStreamsPerConnection: 1024,
  clockSkewMs: 120000,
  replayTtlMs: 300000,
  pingIntervalMs: 0,
  pongTimeoutMs: 10000,
  trustedProxyIps: [],
  logLevel: "error" as const,
  licenseApiUrl: "http://localhost:8787",
  relayInternalSecret: "x".repeat(16),
  licenseCacheMaxEntries: 100000,
};

const relay = startServer(config);
const baseUrl = `ws://localhost:${relay.server.port}/ws`;
const httpUrl = `http://localhost:${relay.server.port}`;

async function generateKeyPair() {
  const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const publicKeyRaw = await crypto.subtle.exportKey("raw", keyPair.publicKey);
  return {
    keyPair,
    publicKeyBase64: Buffer.from(publicKeyRaw).toString("base64"),
  };
}

function waitForMessage(ws: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    ws.onmessage = (e) => {
      resolve(JSON.parse(typeof e.data === "string" ? e.data : ""));
    };
  });
}

function waitForMessages(ws: WebSocket, n: number): Promise<Record<string, unknown>[]> {
  return new Promise((resolve) => {
    const messages: Record<string, unknown>[] = [];
    ws.onmessage = (e) => {
      messages.push(JSON.parse(typeof e.data === "string" ? e.data : ""));
      if (messages.length >= n) resolve(messages);
    };
  });
}

async function connectWs(): Promise<WebSocket> {
  const ws = new WebSocket(baseUrl);
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error("WebSocket connection failed"));
  });
  return ws;
}

async function signNonce(privateKey: CryptoKey, nonceBase64: string): Promise<string> {
  const nonce = Buffer.from(nonceBase64, "base64");
  const signature = await crypto.subtle.sign("Ed25519", privateKey, nonce);
  return Buffer.from(signature).toString("base64");
}

async function authenticateWs(
  ws: WebSocket,
  deviceId: string,
  keyPair: CryptoKeyPair,
  publicKeyBase64: string,
  deviceType: "agent" | "app",
): Promise<void> {
  const challengePromise = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "register", deviceId, deviceType, name: deviceId, publicKey: publicKeyBase64 }));
  const challenge = await challengePromise;

  const authPromise = waitForMessage(ws);
  ws.send(JSON.stringify({
    type: "challenge-response",
    challengeId: challenge.challengeId,
    signature: await signNonce(keyPair.privateKey, challenge.nonce as string),
  }));
  await authPromise;
}

interface PairConn {
  agentWs: WebSocket;
  appWs: WebSocket;
  agentId: string;
  appId: string;
}

// Set up all pairs
console.log("Setting up connections...");
const pairs: PairConn[] = [];

for (let i = 0; i < NUM_PAIRS; i++) {
  const agentKeys = await generateKeyPair();
  const appKeys = await generateKeyPair();
  const agentId = `load-agent-${i}`;
  const appId = `load-app-${i}`;

  const agentWs = await connectWs();
  const appWs = await connectWs();

  await authenticateWs(agentWs, agentId, agentKeys.keyPair, agentKeys.publicKeyBase64, "agent");
  await authenticateWs(appWs, appId, appKeys.keyPair, appKeys.publicKeyBase64, "app");

  pairs.push({ agentWs, appWs, agentId, appId });

  if ((i + 1) % 50 === 0) console.log(`  ${i + 1}/${NUM_PAIRS} pairs connected`);
}

console.log(`All ${NUM_PAIRS} pairs connected. Starting message exchange...`);

// Measure latencies
const latencies: number[] = [];
let totalSent = 0;
let totalReceived = 0;

// Set up message listeners on all agent websockets
for (const pair of pairs) {
  pair.agentWs.onmessage = (e) => {
    const msg = JSON.parse(typeof e.data === "string" ? e.data : "");
    if (msg.type === "message" && msg.payload?.startsWith("ts:")) {
      const sendTs = parseInt(msg.payload.split(":")[1], 10);
      latencies.push(Date.now() - sendTs);
      totalReceived++;
    }
  };
}

// Send messages from all apps at intervals
const startTime = Date.now();
const endTime = startTime + DURATION_S * 1000;

const interval = setInterval(() => {
  const now = Date.now();
  if (now >= endTime) {
    clearInterval(interval);
    return;
  }
  for (const pair of pairs) {
    if (pair.appWs.readyState === WebSocket.OPEN) {
      pair.appWs.send(JSON.stringify({
        type: "message",
        to: pair.agentId,
        channel: "control",
        payload: `ts:${now}`,
      }));
      totalSent++;
    }
  }
}, MSG_INTERVAL_MS);

// Wait for duration + settle time
await new Promise((r) => setTimeout(r, DURATION_S * 1000 + 500));

// Compute stats
latencies.sort((a, b) => a - b);
const p50 = latencies[Math.floor(latencies.length * 0.5)] || 0;
const p95 = latencies[Math.floor(latencies.length * 0.95)] || 0;
const p99 = latencies[Math.floor(latencies.length * 0.99)] || 0;
const elapsed = (Date.now() - startTime) / 1000;
const throughput = totalReceived / elapsed;
const mem = process.memoryUsage();

// Fetch /metrics
const metricsRes = await fetch(`${httpUrl}/metrics`);
const metrics = await metricsRes.json();

console.log("\n=== Load Test Results ===");
console.log(`Pairs: ${NUM_PAIRS}`);
console.log(`Duration: ${elapsed.toFixed(1)}s`);
console.log(`Sent: ${totalSent}, Received: ${totalReceived}`);
console.log(`Throughput: ${throughput.toFixed(1)} msgs/sec`);
console.log(`Latency — p50: ${p50}ms, p95: ${p95}ms, p99: ${p99}ms`);
console.log(`Memory — RSS: ${(mem.rss / 1024 / 1024).toFixed(1)}MB, Heap: ${(mem.heapUsed / 1024 / 1024).toFixed(1)}MB`);
console.log(`\nServer metrics:`, JSON.stringify(metrics, null, 2));

// Clean up
for (const pair of pairs) {
  pair.agentWs.close();
  pair.appWs.close();
}
relay.stop();

// Check targets (for 1000 pairs: <5ms p95, <100MB RSS)
const p95Target = 5;
const rssTargetMB = 100;
if (NUM_PAIRS >= 1000) {
  if (p95 > p95Target) {
    console.log(`\nFAIL: p95 latency ${p95}ms exceeds target ${p95Target}ms`);
    process.exit(1);
  }
  if (mem.rss / 1024 / 1024 > rssTargetMB) {
    console.log(`\nFAIL: RSS ${(mem.rss / 1024 / 1024).toFixed(1)}MB exceeds target ${rssTargetMB}MB`);
    process.exit(1);
  }
}

console.log("\nPASS");
process.exit(0);
