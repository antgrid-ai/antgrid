import { verify as edVerify } from "node:crypto";
import type { ServerWebSocket } from "bun";
import type { RelayConfig } from "./config.js";
import { Connections, type WsData, type Connection } from "./connections.js";
import { ReplayCache } from "./replay-cache.js";
import { ClientMessage, HelloMessage } from "./protocol.js";
import { MessageRateLimiter, TokenBucketRateLimiter } from "./rate-limiter.js";
import { logger, setLogLevel } from "./logger.js";
import { ConnectionLivenessTracker } from "./connection-liveness.js";
import { buildHelloSigBody, PEER_MAX_RECORD_BYTES } from "antgrid-wire";
import { JwksCache } from "./license/jwks-cache.js";
import { LicenseCache } from "./license/cache.js";
import { createLicenseGate, type LicenseGate } from "./license/gate.js";
import { deviceTokenIssuer } from "./license/verify.js";
import { handleRevoke, handleExpire, handleListConnections, handlePeerPolicy } from "./license/internal-routes.js";
import { resolveClientIp, type ClientIpDegradation } from "antgrid-wire";
import { SocketAdmissions } from "./socket-admissions.js";

const VERSION = "0.1.0";
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const HELLO_TIMEOUT_MS = 10_000;

export interface RelayServer {
  server: ReturnType<typeof Bun.serve>;
  connections: Connections;
  licenseCache: LicenseCache;
  stop(): void;
}

export interface RelayServerDeps {
  licenseGate?: LicenseGate;
  licenseCache?: LicenseCache;
  fcmSender?: { send(pushToken: string, data: Record<string, string>): Promise<"ok" | "unregistered" | "error"> };
  apnsSender?: { send(pushToken: string, data: Record<string, string>): Promise<"ok" | "unregistered" | "error"> };
}

/**
 * Normalize a raw upgrade-request `Host` header to the `relayHost` the client
 * signed. A raw Host header has no scheme, so we only strip the ws/wss scheme
 * defaults (`:80`/`:443`). Running wss on :80 or ws on :443 would mismatch and
 * is unsupported — those non-standard deployments simply fail the signature.
 */
function normalizeHostHeader(host: string): string {
  const lower = host.toLowerCase().trim();
  if (lower.endsWith(":80") || lower.endsWith(":443")) {
    return lower.slice(0, lower.lastIndexOf(":"));
  }
  return lower;
}

function verifyHelloSig(publicKeyBase64: string, sigBody: Uint8Array, sigBase64: string): boolean {
  const pubRaw = Buffer.from(publicKeyBase64, "base64");
  if (pubRaw.length !== 32) return false;
  const spki = Buffer.concat([ED25519_SPKI_PREFIX, pubRaw]);
  try {
    return edVerify(null, sigBody, { key: spki, format: "der", type: "spki" }, Buffer.from(sigBase64, "base64"));
  } catch {
    return false;
  }
}

export function startServer(config: RelayConfig, deps: RelayServerDeps = {}): RelayServer {
  setLogLevel(config.logLevel);
  // licenseApiUrl may be an internal address (docker DNS) used only to fetch
  // JWKS efficiently; the token issuer must match web's PUBLIC BETTER_AUTH_URL
  // instead. licenseIssuerUrl carries that when the two differ, falling back
  // to licenseApiUrl for single-host deployments where they're the same.
  const issuerBaseUrl = config.licenseIssuerUrl || config.licenseApiUrl;
  logger.info("relay license config", {
    licenseApiUrl: config.licenseApiUrl,
    issuerBaseUrl,
    expectedIssuer: deviceTokenIssuer(issuerBaseUrl),
  });

  const connections = new Connections();
  const admissions = new SocketAdmissions(config.maxConnections, config.rateLimitConnPerIp);
  const replayCache = new ReplayCache({ ttlMs: config.replayTtlMs });
  const pushRateLimiter = new MessageRateLimiter(config.pushRateLimitPerSec);
  const jsonRateLimiter = new TokenBucketRateLimiter(config.jsonRateLimitPerSec, config.jsonRateLimitBurst);
  const licenseCache = deps.licenseCache ?? new LicenseCache({ maxEntries: config.licenseCacheMaxEntries });
  const licenseGate: LicenseGate = deps.licenseGate ?? createLicenseGate({
    licenseIssuerUrl: issuerBaseUrl,
    jwks: new JwksCache({ licenseApiUrl: config.licenseApiUrl, jwksPath: config.licenseApiJwksPath }),
    cache: licenseCache,
  });
  const startTime = Date.now();
  const liveness = new ConnectionLivenessTracker();
  // Throttled per kind: either degradation drops every connection back into
  // the proxy's shared per-IP bucket and must be visible, but the detail is
  // proxy/client-supplied, so a hostile chain must not turn this into a flood.
  const lastDegradedWarnAt = new Map<ClientIpDegradation["kind"], number>();
  const warnIpDegraded = (event: ClientIpDegradation): void => {
    const now = Date.now();
    if (now - (lastDegradedWarnAt.get(event.kind) ?? 0) < 60_000) return;
    lastDegradedWarnAt.set(event.kind, now);
    const why = event.kind === "untrusted-peer"
      ? "X-Forwarded-For present but the direct peer is not in TRUSTED_PROXY_IPS — check it matches the network the proxy is on"
      : "unparseable X-Forwarded-For hop from a trusted proxy";
    logger.warn(`Client-IP resolution degraded: ${why} (per-IP limits share one bucket)`, {
      kind: event.kind,
      detail: event.detail.slice(0, 64),
    });
  };

  /** Server-side "hello or die" timers, so a silent socket never holds a slot. */
  const helloTimers = new Map<string, ReturnType<typeof setTimeout>>();
  function clearHelloTimer(connectionId: string): void {
    const t = helloTimers.get(connectionId);
    if (t) {
      clearTimeout(t);
      helloTimers.delete(connectionId);
    }
  }


  function sendJson(ws: ServerWebSocket<WsData>, data: unknown): void {
    if (ws.readyState !== 1) return;
    ws.send(JSON.stringify(data));
  }

  interface ErrorOpts {
    serverTime?: string;
  }
  function sendError(
    ws: ServerWebSocket<WsData>,
    code: string,
    message: string,
    retryable: boolean,
    opts: ErrorOpts = {},
  ): void {
    sendJson(ws, { type: "error", code, message, retryable, ...opts });
  }

  /** Every relay-initiated close is preceded by a typed error frame. */
  function sendErrorAndClose(
    ws: ServerWebSocket<WsData>,
    code: string,
    message: string,
    retryable: boolean,
    closeCode: number,
    opts: ErrorOpts = {},
  ): void {
    sendError(ws, code, message, retryable, opts);
    ws.data.phase = "closed";
    try { ws.close(closeCode, code); } catch { /* already closing */ }
  }

  /** Live peers to notify about [conn]'s presence: all same-account
   *  connections of the OPPOSITE device type, deduped. Cross-type only — the
   *  app's presence handler treats any frame on a machine's socket as that
   *  machine's presence, so sibling-app noise must never reach it. */
  function sameAccountPeers(conn: Connection, deviceType: Connection["deviceType"]): Connection[] {
    const seen = new Set<string>();
    const out: Connection[] = [];
    const add = (peer: Connection | undefined) => {
      if (!peer || peer.ws.readyState !== 1) return;
      if (peer.deviceId === conn.deviceId || seen.has(peer.deviceId)) return;
      seen.add(peer.deviceId);
      out.push(peer);
    };
    for (const peer of connections.getConnectionsForUser(conn.uid)) {
      if (peer.deviceType === deviceType) add(peer);
    }
    return out;
  }

  function fanOutAgentPresence(conn: Connection, event: "peer-online" | "peer-offline"): void {
    if (conn.deviceType !== "agent") return;
    for (const peer of sameAccountPeers(conn, "app")) {
      sendJson(peer.ws, { type: event, peerId: conn.deviceId });
    }
  }

  async function handleHello(ws: ServerWebSocket<WsData>, raw: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "First frame must be a hello", false, 1008);
      return;
    }
    const result = HelloMessage.safeParse(parsed);
    if (!result.success) {
      sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "First frame must be a valid v3 hello", false, 1008);
      return;
    }
    const hello = result.data;

    // (2) Clock window — the only retryable AUTH_FAILED; serverTime lets a
    // wrong-clocked client recompute its offset and retry once.
    const now = Date.now();
    const tsMs = Date.parse(hello.ts);
    if (!Number.isFinite(tsMs) || Math.abs(now - tsMs) > config.clockSkewMs) {
      sendErrorAndClose(
        ws,
        "AUTH_FAILED",
        `clock skew: hello ts ${hello.ts} outside ±${config.clockSkewMs}ms of server time`,
        true,
        1008,
        { serverTime: new Date(now).toISOString() },
      );
      return;
    }

    // (3) Possession proof — rebuild the sig body with the SERVER's normalized
    // Host so a cross-relay-replayed hello (signed for another host) fails here.
    const sigBody = buildHelloSigBody({
      relayHost: ws.data.relayHost,
      deviceType: hello.deviceType,
      deviceId: hello.deviceId,
      publicKey: hello.publicKey,
      epoch: hello.epoch,
      licenseToken: hello.licenseToken,
      ts: hello.ts,
      nonce: hello.nonce,
    });
    if (!verifyHelloSig(hello.publicKey, sigBody, hello.sig)) {
      sendErrorAndClose(ws, "AUTH_FAILED", "hello signature invalid", false, 1008);
      return;
    }

    // (4) Replay guard — recorded only AFTER the signature verifies, so an
    // unauthenticated flood of junk hellos can never consume cache capacity and
    // evict a legitimately-cached victim nonce (which would re-enable replay of
    // a captured victim hello). A sig-invalid hello is already rejected above
    // and never needed replay protection; the cache exists solely to stop
    // replays of otherwise-VALID hellos.
    if (!replayCache.checkAndRecord(hello.deviceId, hello.nonce)) {
      sendErrorAndClose(ws, "AUTH_FAILED", "hello nonce already seen (replay)", false, 1008);
      return;
    }

    // (5) License gate.
    let uid: string;
    if (hello.deviceType === "agent") {
      const gateResult = await licenseGate.verify(hello.licenseToken, hello.deviceId, hello.publicKey);
      if (!gateResult.ok) {
        // LICENSE_UNAVAILABLE is retryable (web/JWKS outage — verdict unknown);
        // the LICENSE_* verdicts are terminal.
        const retryable = gateResult.code === "LICENSE_UNAVAILABLE";
        sendErrorAndClose(ws, gateResult.code, `license: ${gateResult.code}`, retryable, 1008);
        return;
      }
      uid = gateResult.entry.userId;
    } else {
      const gateResult = await licenseGate.verifyAppToken(hello.licenseToken);
      if (!gateResult.ok) {
        const retryable = gateResult.code === "LICENSE_UNAVAILABLE";
        sendErrorAndClose(ws, gateResult.code, `license: ${gateResult.code}`, retryable, 1008);
        return;
      }
      uid = gateResult.entry.userId;
    }

    if (ws.data.phase !== "authenticating" || ws.readyState !== 1) return;

    // (6) Epoch arbitration.
    const existing = connections.getByDeviceId(hello.deviceId);
    if (existing) {
      if (hello.publicKey !== existing.publicKey) {
        sendErrorAndClose(
          ws,
          "AUTH_FAILED",
          "identity conflict: a live connection holds this deviceId under a different key",
          false,
          1008,
        );
        return;
      }
      // Equal-epoch admission would otherwise let ANY frame the device has
      // already sent evict its own live socket — permanently, since SUPERSEDED
      // is retryable:false — whenever the replay cache has dropped the record,
      // which it does on capacity eviction and on every restart. Reject a hello
      // that is older than the admitting one (a captured frame always is; a
      // genuine redial never is, both timestamps coming from the same client
      // clock) or that repeats its nonce (the admitting frame itself played
      // back). A same-millisecond redial still gets through on its fresh nonce.
      if (tsMs < existing.helloTs || hello.nonce === existing.helloNonce) {
        sendErrorAndClose(ws, "AUTH_FAILED", "hello replay: not newer than the frame holding this deviceId", false, 1008);
        return;
      }
      if (hello.epoch >= existing.epoch) {
        // Equal epoch admits (pubkey equality is guaranteed above): epoch is
        // minted once per process and a client instance holds one socket at a
        // time, so an equal-epoch hello with a fresh nonce is that instance
        // redialing after its watchdog closed a half-open socket the relay
        // hasn't reaped yet. Rejecting it strands the device: SUPERSEDED is
        // retryable:false, and clients rightly stop reconnecting on it.
        //
        // Remove the superseded socket before admitting its successor so the
        // identity always has exactly one live holder.
        connections.remove(existing);
        liveness.remove(existing.connectionId);
        sendErrorAndClose(existing.ws, "SUPERSEDED", "replaced by a newer connection", false, 1008);
      } else {
        sendErrorAndClose(ws, "SUPERSEDED", "a newer connection already holds this deviceId", false, 1008);
        return;
      }
    }

    const conn: Connection = {
      connectionId: ws.data.connectionId,
      deviceId: hello.deviceId,
      deviceType: hello.deviceType,
      uid,
      publicKey: hello.publicKey,
      epoch: hello.epoch,
      helloNonce: hello.nonce,
      helloTs: tsMs,
      ws,
      connectedAt: now,
      lastSeen: now,
    };
    connections.insert(conn);
    liveness.add(conn.connectionId, now);
    ws.data.deviceId = hello.deviceId;
    ws.data.phase = "ready";
    clearHelloTimer(ws.data.connectionId);

    sendJson(ws, {
      type: "welcome",
      deviceId: hello.deviceId,
      epoch: hello.epoch,
      serverTime: new Date(now).toISOString(),
    });

    // Apps discover already-online agents on admission; agents only publish
    // their own availability to apps.
    if (conn.deviceType === "agent") {
      fanOutAgentPresence(conn, "peer-online");
    } else {
      for (const agent of sameAccountPeers(conn, "agent")) {
        sendJson(ws, { type: "peer-online", peerId: agent.deviceId });
      }
    }
  }

  async function handleControlMessage(ws: ServerWebSocket<WsData>, raw: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      if (!jsonRateLimiter.allow(ws.data.connectionId)) {
        sendError(ws, "MESSAGE_RATE_LIMITED", "control message rate limit exceeded", true);
      } else {
        sendError(ws, "INVALID_MESSAGE", "Invalid JSON", false);
      }
      return;
    }
    if (
      parsed !== null &&
      typeof parsed === "object" &&
      "type" in parsed &&
      ((parsed as { type?: unknown }).type === "stream-open" ||
        (parsed as { type?: unknown }).type === "stream-close")
    ) {
      sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "Central relay streams are retired", false, 1008);
      return;
    }
    if (!jsonRateLimiter.allow(ws.data.connectionId)) {
      sendError(ws, "MESSAGE_RATE_LIMITED", "control message rate limit exceeded", true);
      return;
    }
    const result = ClientMessage.safeParse(parsed);
    if (!result.success) {
      sendError(ws, "INVALID_MESSAGE", "Invalid message format", false);
      return;
    }
    const msg = result.data;
    const conn = connections.getByConnectionId(ws.data.connectionId);
    if (!conn) {
      // Past hello per WsData but no live entry — the socket is being torn down.
      return;
    }

    switch (msg.type) {
      case "hello":
        // A second hello on a ready socket is a protocol violation.
        sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "already past hello on this connection", false, 1008);
        return;

      case "ping":
        // App-layer liveness probe: protocol-level pongs are unobservable from
        // browser-style WS clients, so clients probe here (see bridge watchdog).
        liveness.noteApplicationPing(conn.connectionId, Date.now());
        ws.send(JSON.stringify({ type: "pong" }));
        return;


      case "push:deliver": {
        if (conn.deviceType !== "agent") {
          sendError(ws, "NOT_AUTHENTICATED", "Must be an authenticated agent to deliver push", false);
          return;
        }
        // Per-agent throttle (bounded cardinality; not keyed by pushToken).
        if (!pushRateLimiter.allow(`push:${conn.deviceId}`)) {
          sendError(ws, "MESSAGE_RATE_LIMITED", "Push delivery rate limit exceeded", true);
          return;
        }
        const sender = msg.provider === "apns" ? deps.apnsSender : deps.fcmSender;
        if (!sender) {
          sendJson(ws, { type: "push:result", pushToken: msg.pushToken, ok: false, reason: "unconfigured" });
          return;
        }
        // The relay is a BLIND FORWARDER: forward ciphertext to the provider
        // (FCM or APNs), never to the peer. Re-resolve the agent's CURRENT socket
        // when the send settles (the provider round-trip can outlast a reconnect)
        // so an "unregistered" reason still reaches the live agent and prunes the
        // dead token.
        const agentDeviceId = conn.deviceId;
        const replyPushResult = (r: "ok" | "unregistered" | "error"): void => {
          const live = connections.getByDeviceId(agentDeviceId)?.ws;
          if (!live) return;
          sendJson(live, r === "ok"
            ? { type: "push:result", pushToken: msg.pushToken, ok: true }
            : { type: "push:result", pushToken: msg.pushToken, ok: false, reason: r });
        };
        sender
          .send(msg.pushToken, { epk: msg.blob.epk, box: msg.blob.box })
          .then(replyPushResult)
          .catch((e) => {
            logger.warn("push:deliver send failed", { provider: msg.provider, error: String(e) });
            replyPushResult("error");
          });
        return;
      }
    }
  }


  const pingInterval = config.pingIntervalMs > 0 ? setInterval(() => {
    const t = Date.now();
    const windowMs = config.pingIntervalMs + config.pongTimeoutMs;
    for (const live of connections.getAll()) {
      if (liveness.isTimedOut(live.connectionId, t, windowMs)) {
        logger.info("Device timed out (no pong)", {
          connectionId: live.connectionId,
          deviceId: live.deviceId,
          deviceType: live.deviceType,
          ...liveness.ages(live.connectionId, t),
        });
        try { live.ws.close(1001, "Pong timeout"); } catch { /* closing */ }
        continue;
      }
      live.ws.ping();
    }
  }, config.pingIntervalMs) : null;

  const server = Bun.serve<WsData>({
    port: config.port,
    fetch(req, srv) {
      const url = new URL(req.url);

      if (url.pathname === "/health") {
        return Response.json({
          status: "ok",
          uptime: Math.floor((Date.now() - startTime) / 1000),
          connections: connections.getConnectionCount(),
          version: VERSION,
        });
      }

      if (url.pathname === "/metrics") {
        return Response.json({
          activeConnections: connections.getConnectionCount(),
          uptime: Math.floor((Date.now() - startTime) / 1000),
        });
      }

      if (url.pathname === "/internal/revoke") {
        if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return handleRevoke(req, { licenseCache, connections, relayInternalSecret: config.relayInternalSecret });
      }

      if (url.pathname === "/internal/peer-policy") {
        if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return handlePeerPolicy(req, { licenseCache, connections, relayInternalSecret: config.relayInternalSecret });
      }

      if (url.pathname === "/internal/connections") {
        if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return handleListConnections(req, { licenseCache, connections, relayInternalSecret: config.relayInternalSecret });
      }

      if (url.pathname === "/internal/expire") {
        if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return handleExpire(req, { licenseCache, connections, relayInternalSecret: config.relayInternalSecret });
      }

      if (url.pathname === "/ws") {
        const peerIp = srv.requestIP(req)?.address || "unknown";
        const ip = resolveClientIp(peerIp, req.headers.get("x-forwarded-for"), config.trustedProxyIps, warnIpDegraded);
        const connectionId = crypto.randomUUID();
        const rejected = admissions.reserve(connectionId, ip);
        if (rejected === "ip") {
          return Response.json({ type: "error", code: "RATE_LIMITED", message: "Too many connections from this IP" }, { status: 429 });
        }
        if (rejected === "global") {
          return Response.json({ type: "error", code: "MAX_CONNECTIONS", message: "Server at capacity" }, { status: 503 });
        }
        const relayHost = normalizeHostHeader(req.headers.get("host") ?? "");
        const data: WsData = {
          connectionId,
          ip,
          relayHost,
          phase: "awaiting-hello",
        };
        if (!srv.upgrade(req, { data })) {
          admissions.release(connectionId);
          return new Response("WebSocket upgrade failed", { status: 400 });
        }
        return undefined;
      }

      return new Response("Not Found", { status: 404 });
    },
    websocket: {
      // Accept the retired frame size long enough to send its typed 1008 rejection.
      maxPayloadLength: PEER_MAX_RECORD_BYTES,
      open(ws) {
        const timer = setTimeout(() => {
          if (ws.data.phase === "awaiting-hello" || ws.data.phase === "authenticating") {
            sendErrorAndClose(ws, "AUTH_FAILED", "hello timeout", true, 1008);
          }
        }, HELLO_TIMEOUT_MS);
        timer.unref?.();
        helloTimers.set(ws.data.connectionId, timer);
        logger.info("WebSocket connected", { ip: ws.data.ip });
      },
      async message(ws, message) {
        if (ws.data.phase === "awaiting-hello") {
          // The first frame MUST be a text hello — a binary frame here is a
          // protocol violation (step 1).
          if (typeof message !== "string") {
            sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "First frame must be a hello", false, 1008);
            return;
          }
          ws.data.phase = "authenticating";
          await handleHello(ws, message);
          return;
        }
        if (ws.data.phase === "authenticating") {
          sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "authentication already in progress", false, 1008);
          return;
        }
        if (ws.data.phase === "closed") return;
        if (typeof message === "string") {
          await handleControlMessage(ws, message);
        } else {
          sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "Binary frames are not accepted by the control relay", false, 1008);
        }
      },
      close(ws) {
        const { connectionId, ip, deviceId } = ws.data;
        ws.data.phase = "closed";
        admissions.release(connectionId);
        clearHelloTimer(connectionId);

        const conn = connections.getByConnectionId(connectionId);
        if (!conn) {
          // Superseded (already removed) or never past hello — no fan-out.
          logger.info("WebSocket disconnected", { ip, deviceId });
          return;
        }
        connections.remove(conn);
        liveness.remove(conn.connectionId);

        // No cascade close: same-account peers stay connected and just go
        // offline to us. Must pass the Connection object, not
        // deviceId — connections.remove(conn) already ran above, so a
        // re-lookup here would find nothing.
        fanOutAgentPresence(conn, "peer-offline");
        logger.info("WebSocket disconnected", { ip, deviceId: conn.deviceId });
      },
      pong(ws) {
        const conn = connections.getByConnectionId(ws.data.connectionId);
        if (!conn) return;
        liveness.noteProtocolPong(conn.connectionId, Date.now());
        connections.updateLastSeen(conn.deviceId);
      },
    },
  });

  return {
    server,
    connections,
    licenseCache,
    stop() {
      if (pingInterval) clearInterval(pingInterval);
      for (const t of helloTimers.values()) clearTimeout(t);
      helloTimers.clear();
      connections.clear();
      admissions.clear();
      replayCache.destroy();
      pushRateLimiter.destroy();
      jsonRateLimiter.destroy();
      licenseCache.destroy();
      server.stop();
    },
  };
}
