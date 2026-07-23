import { verify as edVerify } from "node:crypto";
import type { ServerWebSocket } from "bun";
import type { RelayConfig } from "./config.js";
import { Connections, type WsData, type Connection } from "./connections.js";
import { Grants } from "./grants.js";
import { ReplayCache } from "./replay-cache.js";
import { verifyPairApproval } from "./pair-verify.js";
import {
  ClientMessage,
  HelloMessage,
  RouteHeader,
  type RouteHeaderOutbound,
} from "./protocol.js";
import { MessageRateLimiter, TokenBucketRateLimiter, pairKey } from "./rate-limiter.js";
import { logger, setLogLevel } from "./logger.js";
import {
  buildHelloSigBody,
  encodeRouteFrame,
  decodeRouteFrame,
  FrameError,
  MAX_FRAME_PAYLOAD,
  type FrameKind,
} from "antgrid-wire";
import { JwksCache } from "./license/jwks-cache.js";
import { LicenseCache } from "./license/cache.js";
import { createLicenseGate, type LicenseGate } from "./license/gate.js";
import { deviceTokenIssuer } from "./license/verify.js";
import { handleRevoke, handleExpire, handleListConnections } from "./license/internal-routes.js";

const VERSION = "0.1.0";
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const HELLO_TIMEOUT_MS = 10_000;

export interface RelayServer {
  server: ReturnType<typeof Bun.serve>;
  connections: Connections;
  grants: Grants;
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
  const grants = new Grants();
  const replayCache = new ReplayCache({ ttlMs: config.replayTtlMs });
  const rateLimiter = new MessageRateLimiter(config.rateLimitMsgPerSec);
  const jsonRateLimiter = new TokenBucketRateLimiter(config.jsonRateLimitPerSec, config.jsonRateLimitBurst);
  const pairRateLimiter = new MessageRateLimiter(config.pairRateLimitPerIp);
  const licenseCache = deps.licenseCache ?? new LicenseCache({ maxEntries: config.licenseCacheMaxEntries });
  const licenseGate: LicenseGate = deps.licenseGate ?? createLicenseGate({
    licenseIssuerUrl: issuerBaseUrl,
    jwks: new JwksCache({ licenseApiUrl: config.licenseApiUrl, jwksPath: config.licenseApiJwksPath }),
    cache: licenseCache,
  });
  const startTime = Date.now();
  const lastPong = new Map<string, number>();

  /** Pending pair-request rendezvous, keyed by relay-generated `pairId`. */
  interface PendingPair {
    requesterConnectionId: string;
    requesterDeviceId: string;
    requesterPubkey: string;
    claimedPhonePubkey: string;
    nonce: string;
    deadline: number;
    agentDeviceId: string;
  }
  const pendingPairs = new Map<string, PendingPair>();

  /** Server-side "hello or die" timers, so a silent socket never holds a slot. */
  const helloTimers = new Map<string, ReturnType<typeof setTimeout>>();
  function clearHelloTimer(connectionId: string): void {
    const t = helloTimers.get(connectionId);
    if (t) {
      clearTimeout(t);
      helloTimers.delete(connectionId);
    }
  }

  const MSG_WINDOW_MS = 10000;
  const messageTimes: number[] = [];
  let msgHead = 0;

  function recordMessage(): void {
    const now = Date.now();
    messageTimes.push(now);
    const cutoff = now - MSG_WINDOW_MS;
    while (msgHead < messageTimes.length && messageTimes[msgHead] <= cutoff) msgHead++;
    if (msgHead > messageTimes.length / 2 && msgHead > 1000) {
      messageTimes.splice(0, msgHead);
      msgHead = 0;
    }
  }

  function sendJson(ws: ServerWebSocket<WsData>, data: unknown): void {
    if (ws.readyState !== 1) return;
    ws.send(JSON.stringify(data));
  }

  interface ErrorOpts {
    ref?: string;
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

  /** Every relay-initiated close is preceded by a typed error frame (design §3.3). */
  function sendErrorAndClose(
    ws: ServerWebSocket<WsData>,
    code: string,
    message: string,
    retryable: boolean,
    closeCode: number,
    opts: ErrorOpts = {},
  ): void {
    sendError(ws, code, message, retryable, opts);
    try { ws.close(closeCode, code); } catch { /* already closing */ }
  }

  /** Notify grant-linked live peers that [deviceId] just came/went. */
  function fanOutPeerPresence(deviceId: string, event: "peer-online" | "peer-offline"): void {
    for (const grant of grants.peersOf(deviceId)) {
      const peerId = grant.agentDeviceId === deviceId ? grant.phoneDeviceId : grant.agentDeviceId;
      const peer = connections.getByDeviceId(peerId);
      if (peer && peer.ws.readyState === 1) sendJson(peer.ws, { type: event, peerId: deviceId });
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
    // wrong-clocked client recompute its offset and retry once (design §13.1).
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
    let claims: Connection["claims"];
    if (hello.deviceType === "agent") {
      const gateResult = await licenseGate.verify(hello.licenseToken, hello.deviceId, hello.publicKey);
      if (!gateResult.ok) {
        // LICENSE_UNAVAILABLE is retryable (web/JWKS outage — verdict unknown);
        // the LICENSE_* verdicts are terminal.
        const retryable = gateResult.code === "LICENSE_UNAVAILABLE";
        sendErrorAndClose(ws, gateResult.code, `license: ${gateResult.code}`, retryable, 1008);
        return;
      }
      claims = {
        uid: gateResult.entry.userId,
        tier: gateResult.entry.tier,
        sessionLimit: gateResult.entry.sessionLimit,
        jti: gateResult.entry.jti,
      };
    } else {
      const gateResult = await licenseGate.verifyAppToken(hello.licenseToken);
      if (!gateResult.ok) {
        const retryable = gateResult.code === "LICENSE_UNAVAILABLE";
        sendErrorAndClose(ws, gateResult.code, `license: ${gateResult.code}`, retryable, 1008);
        return;
      }
      claims = {
        uid: gateResult.entry.userId,
        tier: gateResult.entry.tier,
        jti: gateResult.entry.jti,
      };
    }

    // (6) Epoch arbitration (design §6.3).
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
      if (hello.epoch > existing.epoch) {
        // Release the superseded connection (dropping its openStreams) BEFORE
        // inserting the successor, so sessionLimit counting never double-counts
        // one device across a restart (design §7.3).
        connections.remove(existing);
        sendErrorAndClose(existing.ws, "SUPERSEDED", "replaced by a newer connection", false, 1008);
      } else {
        sendErrorAndClose(ws, "SUPERSEDED", "a newer or equal connection already holds this deviceId", false, 1008);
        return;
      }
    }

    const conn: Connection = {
      connectionId: ws.data.connectionId,
      deviceId: hello.deviceId,
      deviceType: hello.deviceType,
      name: hello.name,
      publicKey: hello.publicKey,
      epoch: hello.epoch,
      ws,
      ip: ws.data.ip,
      connectedAt: now,
      lastSeen: now,
      claims,
      openStreams: new Set<string>(),
    };
    connections.insert(conn);
    ws.data.deviceId = hello.deviceId;
    ws.data.jti = claims?.jti;
    ws.data.phase = "ready";
    clearHelloTimer(ws.data.connectionId);
    lastPong.delete(hello.deviceId);

    sendJson(ws, {
      type: "welcome",
      deviceId: hello.deviceId,
      epoch: hello.epoch,
      serverTime: new Date(now).toISOString(),
    });

    // A reconnecting device with a live grant is immediately reachable — tell
    // both sides so a mid-session phone can trigger its rekey (design §6.2).
    for (const grant of grants.peersOf(hello.deviceId)) {
      const peerId = grant.agentDeviceId === hello.deviceId ? grant.phoneDeviceId : grant.agentDeviceId;
      const peer = connections.getByDeviceId(peerId);
      if (peer && peer.ws.readyState === 1) {
        sendJson(peer.ws, { type: "peer-online", peerId: hello.deviceId });
        sendJson(ws, { type: "peer-online", peerId });
      }
    }
  }

  async function handleControlMessage(ws: ServerWebSocket<WsData>, raw: string): Promise<void> {
    // JSON control messages are rate-limited per connection (design §3.3) —
    // dropped, never closed, so a pairing burst degrades gracefully.
    if (!jsonRateLimiter.allow(ws.data.connectionId)) {
      sendError(ws, "MESSAGE_RATE_LIMITED", "control message rate limit exceeded", true);
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      sendError(ws, "INVALID_MESSAGE", "Invalid JSON", false);
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
        sendError(ws, "PROTOCOL_VIOLATION", "already past hello on this connection", false);
        return;

      case "stream-open": {
        if (conn.deviceType !== "agent") {
          sendError(ws, "WRONG_DEVICE_TYPE", "Only agents can open streams", false);
          return;
        }
        // Count → admit MUST stay await-free. The event loop is single-threaded,
        // so with no yield between counting and adding, two concurrent opens
        // cannot both pass the cap. Inserting an `await` here reopens a
        // count→admit TOCTOU — don't.
        const uid = conn.claims?.uid ?? "";
        const sessionLimit = conn.claims?.sessionLimit ?? 0;
        const open = connections.countOpenStreamsForUser(uid);
        if (open >= sessionLimit) {
          sendError(
            ws,
            "SESSION_LIMIT_EXCEEDED",
            `Concurrent remote agent limit reached (${sessionLimit})`,
            false,
            { ref: msg.streamId },
          );
          return;
        }
        conn.openStreams.add(msg.streamId);
        sendJson(ws, { type: "stream-opened", streamId: msg.streamId });
        return;
      }

      case "stream-close": {
        if (conn.deviceType !== "agent") {
          sendError(ws, "WRONG_DEVICE_TYPE", "Only agents can close streams", false);
          return;
        }
        conn.openStreams.delete(msg.streamId);
        sendJson(ws, { type: "stream-closed", streamId: msg.streamId });
        return;
      }

      case "grant-revoke": {
        const revoked = grants.revokeByPeers(conn.deviceId, msg.peerDeviceId, "REVOKED");
        if (revoked) {
          const peer = connections.getByDeviceId(msg.peerDeviceId);
          if (peer && peer.ws.readyState === 1) {
            sendJson(peer.ws, { type: "grant-revoked", peerDeviceId: conn.deviceId, reason: "REVOKED" });
          }
        }
        return;
      }

      case "pair-request": {
        if (conn.deviceType !== "app") {
          sendError(ws, "WRONG_DEVICE_TYPE", "Only apps can initiate pairing", false);
          return;
        }
        const agent = connections.getByDeviceId(msg.agentDeviceId);
        if (!agent || agent.deviceType !== "agent" || agent.ws.readyState !== 1) {
          // Application-layer failure — socket stays open, client retries.
          sendError(ws, "AGENT_OFFLINE", "Target agent is not connected", true, { ref: msg.nonce });
          return;
        }
        // Throttle the FORWARD specifically — it's the only part an unpaired
        // caller can make the agent pay for (an Ed25519 verify per request,
        // plus a possible account-peer-key fetch). Deliberately below the
        // AGENT_OFFLINE check: offline answers never reach an agent, and a
        // phone legitimately re-sends at ~2/sec while a bridge reconnects.
        if (!pairRateLimiter.allow(pairKey(conn.deviceId, msg.agentDeviceId))) {
          sendError(ws, "PAIR_RATE_LIMITED", "Pairing rate limit exceeded", true, { ref: msg.nonce });
          return;
        }
        const deadline = Math.min(msg.deadline, Date.now() + config.pairRequestTimeoutMs);
        const pairId = crypto.randomUUID();
        pendingPairs.set(pairId, {
          requesterConnectionId: conn.connectionId,
          requesterDeviceId: conn.deviceId,
          // Anchor the pending to the phone's authenticated connection key, not
          // the client-claimed field, so the approved grant is always routable.
          requesterPubkey: conn.publicKey,
          // The phone's claimed PAIRING key. Not an auth anchor (the relay
          // can't verify it) — kept only to check the agent approved the key
          // this request actually asked for.
          claimedPhonePubkey: msg.phonePubkey,
          nonce: msg.nonce,
          deadline,
          agentDeviceId: msg.agentDeviceId,
        });
        // Strip the deprecated trust flag; stamp the relay pairId. The agent
        // never receives a relay-controlled trust signal (confused-deputy).
        const { sameAccount: _stripped, ...rest } = msg;
        agent.ws.send(JSON.stringify({ ...rest, pairId }));
        return;
      }

      case "pair-approval": {
        if (conn.deviceType !== "agent") {
          sendError(ws, "WRONG_DEVICE_TYPE", "Only agents can send pair-approval", false);
          return;
        }
        const pending = pendingPairs.get(msg.pairId);
        if (!pending || pending.agentDeviceId !== conn.deviceId) {
          sendError(ws, "NONCE_MISMATCH", "No matching pending pair request", false, { ref: msg.pairId });
          return;
        }
        const phone = connections.getByConnectionId(pending.requesterConnectionId);
        if (!phone || phone.ws.readyState !== 1) {
          pendingPairs.delete(msg.pairId);
          return;
        }
        const verifyResult = verifyPairApproval({
          agentEd25519Pubkey: conn.publicKey,
          agentDeviceId: conn.deviceId,
          approval: msg,
          expectedNonce: pending.nonce,
        });
        // NOT compared against `pending.requesterPubkey`: `msg.phonePubkey` is
        // the phone's PAIRING identity (agent-pinned, per-machine) while the
        // connection is authenticated under its DeviceIdentity key — two
        // distinct keys that are never equal. The approval is tied to this
        // phone by the relay-generated pairId; these fields only assert the
        // agent approved what the request asked for.
        const consistent =
          msg.phonePubkey === pending.claimedPhonePubkey && msg.phoneDeviceId === pending.requesterDeviceId;
        if (!verifyResult.ok || !consistent) {
          // Neither socket closes (error-contract law): the phone learns the
          // pairing failed, the agent learns its approval was rejected.
          sendError(phone.ws, "PAIR_REJECTED", "Pair approval rejected", false, { ref: pending.nonce });
          sendError(ws, "INVALID_MESSAGE", "Pair approval failed verification", false, { ref: msg.pairId });
          pendingPairs.delete(msg.pairId);
          return;
        }

        const displaced = grants.create({
          agentDeviceId: conn.deviceId,
          phoneDeviceId: pending.requesterDeviceId,
          // The phone's authenticated CONNECTION key, not the approval's
          // pairing key: routing authorizes app→agent by `sender.publicKey`,
          // so anchoring anything else makes the grant unroutable.
          phonePubkey: pending.requesterPubkey,
          userId: phone.claims?.uid ?? "",
          tier: conn.claims?.tier,
        });
        for (const g of displaced) {
          const displacedPhone = connections.getByDeviceId(g.phoneDeviceId);
          if (displacedPhone && displacedPhone.ws.readyState === 1) {
            sendJson(displacedPhone.ws, {
              type: "grant-revoked",
              peerDeviceId: conn.deviceId,
              reason: "PEER_REPLACED",
            });
          }
        }

        // Forward the signed approval, then announce the grant to both sides.
        sendJson(phone.ws, msg);
        sendJson(phone.ws, {
          type: "pair-connected",
          peerId: conn.deviceId,
          peerName: conn.name,
          peerType: conn.deviceType,
        });
        sendJson(ws, {
          type: "pair-connected",
          peerId: phone.deviceId,
          peerName: phone.name,
          peerType: phone.deviceType,
        });
        pendingPairs.delete(msg.pairId);
        return;
      }

      case "pair-rejected": {
        if (conn.deviceType !== "agent") {
          sendError(ws, "WRONG_DEVICE_TYPE", "Only agents can send pair-rejected", false);
          return;
        }
        const pending = pendingPairs.get(msg.pairId);
        if (!pending || pending.agentDeviceId !== conn.deviceId) return;
        const phone = connections.getByConnectionId(pending.requesterConnectionId);
        if (phone && phone.ws.readyState === 1) sendJson(phone.ws, msg);
        pendingPairs.delete(msg.pairId);
        return;
      }

      case "push:deliver": {
        if (conn.deviceType !== "agent") {
          sendError(ws, "NOT_AUTHENTICATED", "Must be an authenticated agent to deliver push", false);
          return;
        }
        // Per-agent throttle (bounded cardinality; not keyed by pushToken).
        if (!rateLimiter.allow(`push:${conn.deviceId}`)) {
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

  function handleBinaryFrame(ws: ServerWebSocket<WsData>, buf: Buffer): void {
    let decoded: { header: unknown; payload: Uint8Array; kind: FrameKind };
    try {
      decoded = decodeRouteFrame(buf);
    } catch (e) {
      if (e instanceof FrameError) {
        sendErrorAndClose(ws, "PROTOCOL_VIOLATION", `Frame error: ${e.reason}`, false, 1008);
        return;
      }
      throw e;
    }

    const headerResult = RouteHeader.safeParse(decoded.header);
    if (!headerResult.success) {
      sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "Invalid route header", false, 1008);
      return;
    }
    const header = headerResult.data;

    const sender = connections.getByConnectionId(ws.data.connectionId);
    if (!sender) {
      sendErrorAndClose(ws, "NOT_AUTHENTICATED", "Must be authenticated to route", false, 1008);
      return;
    }

    // Authorization is grant-anchored and offline-safe: an unauthorized sender
    // learns NOTHING about peer presence (grant check precedes reachability).
    const target = connections.getByDeviceId(header.to);
    let authorized: boolean;
    if (sender.deviceType === "agent") {
      // agent→app: grant existence by device authorizes; the delivered peer's
      // live key is bound below so a phone that rotated keys can't receive.
      authorized = grants.linkedByDevices(sender.deviceId, header.to);
    } else {
      // app→agent: the phone's own connection key must anchor the grant.
      authorized = grants.linked(header.to, sender.publicKey);
    }
    if (!authorized) {
      sendError(ws, "NOT_AUTHORIZED", "No grant links sender and target", false);
      return;
    }

    if (!target || target.ws.readyState !== 1) {
      sendError(ws, "PEER_OFFLINE", "Recipient not connected", true);
      return;
    }

    if (sender.deviceType === "agent" && !grants.linked(sender.deviceId, target.publicKey)) {
      // The phone reconnected under a key the agent never approved — re-pair.
      sendError(ws, "NOT_AUTHORIZED", "Target key not granted", false);
      return;
    }

    const key = pairKey(sender.deviceId, header.to);
    if (!rateLimiter.allow(key)) {
      sendError(ws, "MESSAGE_RATE_LIMITED", "Message rate limit exceeded", true);
      return;
    }

    connections.updateLastSeen(sender.deviceId);
    grants.refreshLastUsed(
      sender.deviceType === "agent" ? sender.deviceId : header.to,
      sender.deviceType === "agent" ? target.publicKey : sender.publicKey,
    );

    const outHeader: RouteHeaderOutbound = {
      type: "message",
      from: sender.deviceId,
      channel: header.channel,
      ts: Date.now(),
    };
    // Forward verbatim: the kind byte and sealed payload are opaque to us.
    target.ws.send(encodeRouteFrame(outHeader, decoded.payload, decoded.kind));
    recordMessage();
  }

  // Deadline sweeper — drops past-deadline pending pairs and, if the requester
  // is still connected, tells it EXPIRED (retryable) instead of silence.
  const pairSweeper = setInterval(() => {
    const t = Date.now();
    for (const [pairId, p] of pendingPairs) {
      if (t <= p.deadline) continue;
      pendingPairs.delete(pairId);
      const requester = connections.getByConnectionId(p.requesterConnectionId);
      if (requester && requester.ws.readyState === 1) {
        sendError(requester.ws, "EXPIRED", "pair-request expired", true, { ref: p.nonce });
      }
    }
  }, 5_000);
  pairSweeper.unref?.();

  // Stale-grant sweeper (design §13.3) — hourly; notifies any live peer.
  const grantSweeper = setInterval(() => {
    for (const g of grants.sweepStale(config.staleGrantDays)) {
      for (const id of [g.agentDeviceId, g.phoneDeviceId]) {
        const peer = connections.getByDeviceId(id);
        if (peer && peer.ws.readyState === 1) {
          const otherId = id === g.agentDeviceId ? g.phoneDeviceId : g.agentDeviceId;
          sendJson(peer.ws, { type: "grant-revoked", peerDeviceId: otherId, reason: "STALE" });
        }
      }
    }
  }, 60 * 60 * 1000);
  grantSweeper.unref?.();

  const pingInterval = config.pingIntervalMs > 0 ? setInterval(() => {
    const t = Date.now();
    for (const c of connections.listConnections()) {
      const live = connections.getByDeviceId(c.deviceId);
      if (!live) continue;
      const lastPongTime = lastPong.get(c.deviceId) ?? live.connectedAt;
      if (t - lastPongTime > config.pingIntervalMs + config.pongTimeoutMs) {
        logger.info("Device timed out (no pong)", { deviceId: c.deviceId });
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
        const t = Date.now();
        const cutoff = t - MSG_WINDOW_MS;
        while (msgHead < messageTimes.length && messageTimes[msgHead] <= cutoff) msgHead++;
        const activeCount = messageTimes.length - msgHead;
        const messagesPerSec = activeCount / (MSG_WINDOW_MS / 1000);
        return Response.json({
          activeConnections: connections.getConnectionCount(),
          grants: grants.size,
          messagesPerSec: Math.round(messagesPerSec * 100) / 100,
          uptime: Math.floor((t - startTime) / 1000),
        });
      }

      if (url.pathname === "/internal/revoke") {
        if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return handleRevoke(req, { licenseCache, connections, grants, relayInternalSecret: config.relayInternalSecret });
      }

      if (url.pathname === "/internal/connections") {
        if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return handleListConnections(req, { licenseCache, connections, grants, relayInternalSecret: config.relayInternalSecret });
      }

      if (url.pathname === "/internal/expire") {
        if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
        return handleExpire(req, { licenseCache, connections, grants, relayInternalSecret: config.relayInternalSecret });
      }

      if (url.pathname === "/ws") {
        const ip = srv.requestIP(req)?.address || "unknown";
        if (connections.getConnectionCountByIp(ip) >= config.rateLimitConnPerIp) {
          return Response.json({ type: "error", code: "RATE_LIMITED", message: "Too many connections from this IP" }, { status: 429 });
        }
        if (connections.getConnectionCount() >= config.maxConnections) {
          return Response.json({ type: "error", code: "MAX_CONNECTIONS", message: "Server at capacity" }, { status: 503 });
        }
        const relayHost = normalizeHostHeader(req.headers.get("host") ?? "");
        const data: WsData = {
          connectionId: crypto.randomUUID(),
          ip,
          relayHost,
          phase: "awaiting-hello",
        };
        if (!srv.upgrade(req, { data })) {
          return new Response("WebSocket upgrade failed", { status: 400 });
        }
        return undefined;
      }

      return new Response("Not Found", { status: 404 });
    },
    websocket: {
      maxPayloadLength: MAX_FRAME_PAYLOAD,
      open(ws) {
        connections.incrementIpCount(ws.data.ip);
        const timer = setTimeout(() => {
          if (ws.data.phase === "awaiting-hello") {
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
          // protocol violation (design §4.1 step 1).
          if (typeof message !== "string") {
            sendErrorAndClose(ws, "PROTOCOL_VIOLATION", "First frame must be a hello", false, 1008);
            return;
          }
          await handleHello(ws, message);
          return;
        }
        if (typeof message === "string") {
          await handleControlMessage(ws, message);
        } else {
          handleBinaryFrame(ws, Buffer.from(message));
        }
      },
      close(ws) {
        const { connectionId, ip, deviceId } = ws.data;
        connections.decrementIpCount(ip);
        clearHelloTimer(connectionId);

        // Drop any pending pair this socket initiated as requester.
        for (const [pairId, p] of pendingPairs) {
          if (p.requesterConnectionId === connectionId) pendingPairs.delete(pairId);
        }

        const conn = connections.getByConnectionId(connectionId);
        if (!conn) {
          // Superseded (already removed) or never past hello — no fan-out.
          logger.info("WebSocket disconnected", { ip, deviceId });
          return;
        }
        connections.remove(conn);
        lastPong.delete(conn.deviceId);

        // Drop pendings targeting this agent; its successor re-establishes them.
        for (const [pairId, p] of pendingPairs) {
          if (p.agentDeviceId === conn.deviceId) pendingPairs.delete(pairId);
        }

        // No cascade close: granted peers stay connected and just go offline
        // to us (design §6.4).
        fanOutPeerPresence(conn.deviceId, "peer-offline");
        logger.info("WebSocket disconnected", { ip, deviceId: conn.deviceId });
      },
      pong(ws) {
        if (ws.data.deviceId) {
          lastPong.set(ws.data.deviceId, Date.now());
          connections.updateLastSeen(ws.data.deviceId);
        }
      },
    },
  });

  return {
    server,
    connections,
    grants,
    licenseCache,
    stop() {
      if (pingInterval) clearInterval(pingInterval);
      clearInterval(pairSweeper);
      clearInterval(grantSweeper);
      for (const t of helloTimers.values()) clearTimeout(t);
      helloTimers.clear();
      pendingPairs.clear();
      grants.clear();
      connections.clear();
      replayCache.destroy();
      rateLimiter.destroy();
      jsonRateLimiter.destroy();
      pairRateLimiter.destroy();
      licenseCache.destroy();
      server.stop();
    },
  };
}
