import { createHash, randomBytes } from "node:crypto";
import { verifyAsync } from "@noble/ed25519";
import {
  ENDPOINT_CHALLENGE_MS, PEER_LEASE_MS, endpointChallengeBytes,
  peerAuthorizationSnapshotSchema, PeerRelayAdmissionResponseSchema, type EndpointChallenge,
  type PeerRelayAdmissionRequest, type PeerRelayAdmissionResponse,
} from "antgrid-wire";
import type { DB, Tx } from "../db/index.js";
import type { AuthVars } from "../auth/middleware.js";
import { activeSubscriptionForUser } from "./subscription.js";
import { resolveBillingAccountId } from "./account-member.js";
import { parseDeviceOAuthMetadata } from "./device-oauth.js";

type Identity = NonNullable<AuthVars["deviceAuthorization"]> & { userId: string };
export class PeerAuthorizationError extends Error {
  constructor(readonly code: "UNAUTHENTICATED" | "STALE_GENERATION" | "INVALID_CHALLENGE" | "INVALID_SIGNATURE" | "ENDPOINT_REUSED" | "NOT_ENTITLED") {
    super(code);
  }
}

async function currentIdentity(tx: Tx, identity: Identity) {
  const device = await tx.device.findUnique({ where: { id: identity.id } });
  const credential = await tx.oauthClient.findUnique({ where: { clientId: identity.enrollmentId } });
  const metadata = parseDeviceOAuthMetadata(credential?.metadata);
  const user = await tx.user.findUnique({ where: { id: identity.userId } });
  const ownedAccount = await tx.productAccount.findUnique({ where: { userId: identity.userId } });
  if (!user || ownedAccount?.deletedAt || !device || device.revokedAt || device.userId !== identity.userId ||
      device.deviceId !== identity.deviceId || device.oauthClientId !== identity.enrollmentId ||
      !Buffer.from(device.publicKey).equals(Buffer.from(identity.publicKey)) ||
      !credential || credential.disabled || !credential.grantTypes.includes("client_credentials") ||
      !metadata.success || metadata.data.userId !== identity.userId ||
      metadata.data.deviceUuid !== identity.deviceId ||
      metadata.data.ed25519Pub !== Buffer.from(device.publicKey).toString("base64")) {
    throw new PeerAuthorizationError("UNAUTHENTICATED");
  }
  return device;
}

async function generation(tx: Tx, enrollmentId: string) {
  const latest = await tx.peerEndpointRegistration.findFirst({
    where: { enrollmentId }, orderBy: { generation: "desc" },
  });
  return latest?.generation ?? 0n;
}

async function serializable<T>(db: DB, work: (tx: Tx) => Promise<T>): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try { return await db.$transaction(work, { isolationLevel: "Serializable" }); }
    catch (error) {
      const code = (error as { code?: string }).code;
      if (code === "P2034" && attempt < 3) continue;
      if (code === "P2002") throw new PeerAuthorizationError("ENDPOINT_REUSED");
      throw error;
    }
  }
}

export async function createEndpointChallenge(db: DB, identity: Identity,
  input: { endpointId: string; expectedGeneration: string }): Promise<EndpointChallenge> {
  return serializable(db, async (tx) => {
    await currentIdentity(tx, identity);
    if (await generation(tx, identity.enrollmentId) !== BigInt(input.expectedGeneration)) {
      throw new PeerAuthorizationError("STALE_GENERATION");
    }
    // Only the newest unconsumed challenge is useful; bound retained challenges per enrollment.
    await tx.peerEndpointChallenge.deleteMany({ where: { OR: [
      { enrollmentId: identity.enrollmentId }, { expiresAt: { lte: new Date() } },
    ] } });
    const row = await tx.peerEndpointChallenge.create({ data: {
      userId: identity.userId, deviceId: identity.deviceId, enrollmentId: identity.enrollmentId,
      endpointId: input.endpointId, expectedGeneration: BigInt(input.expectedGeneration),
      challenge: randomBytes(32).toString("base64"), expiresAt: new Date(Date.now() + ENDPOINT_CHALLENGE_MS),
    } });
    return { ...input, challengeId: row.id, challenge: row.challenge, accountId: identity.userId,
      deviceId: identity.deviceId, enrollmentId: identity.enrollmentId };
  });
}

export async function registerEndpoint(db: DB, identity: Identity,
  input: { challengeId: string; deviceSignature: string; endpointSignature: string }) {
  return serializable(db, async (tx) => {
    const device = await currentIdentity(tx, identity);
    const row = await tx.peerEndpointChallenge.findUnique({ where: { id: input.challengeId } });
    if (!row || row.consumedAt || row.expiresAt.getTime() <= Date.now() ||
        row.userId !== identity.userId || row.deviceId !== identity.deviceId || row.enrollmentId !== identity.enrollmentId) {
      throw new PeerAuthorizationError("INVALID_CHALLENGE");
    }
    const bytes = endpointChallengeBytes({ challengeId: row.id, challenge: row.challenge,
      accountId: row.userId, deviceId: row.deviceId, enrollmentId: row.enrollmentId,
      endpointId: row.endpointId, expectedGeneration: row.expectedGeneration.toString() });
    const valid = await Promise.all([
      verifyAsync(Buffer.from(input.deviceSignature, "base64"), bytes, device.publicKey),
      verifyAsync(Buffer.from(input.endpointSignature, "base64"), bytes, Buffer.from(row.endpointId, "hex")),
    ]).catch(() => [false]);
    if (!valid.every(Boolean)) throw new PeerAuthorizationError("INVALID_SIGNATURE");
    if (await generation(tx, identity.enrollmentId) !== row.expectedGeneration || row.expectedGeneration === 9223372036854775807n) {
      throw new PeerAuthorizationError("STALE_GENERATION");
    }
    if (await tx.peerEndpointRegistration.findUnique({ where: { endpointId: row.endpointId } })) {
      throw new PeerAuthorizationError("ENDPOINT_REUSED");
    }
    const consumed = await tx.peerEndpointChallenge.updateMany({ where: {
      id: row.id, consumedAt: null, expiresAt: { gt: new Date() },
    }, data: { consumedAt: new Date() } });
    if (consumed.count !== 1) throw new PeerAuthorizationError("INVALID_CHALLENGE");
    await tx.peerEndpointRegistration.updateMany({ where: { enrollmentId: identity.enrollmentId, revokedAt: null },
      data: { revokedAt: new Date() } });
    const next = await tx.peerEndpointRegistration.create({ data: {
      endpointId: row.endpointId, userId: row.userId, deviceId: row.deviceId,
      enrollmentId: row.enrollmentId, generation: row.expectedGeneration + 1n,
    } });
    return { endpointId: next.endpointId, generation: next.generation.toString() };
  });
}

export async function endpointInventory(tx: Tx, userId: string) {
  const rows = await tx.peerEndpointRegistration.findMany({ where: { userId, revokedAt: null } });
  return new Map(rows.map((row) => [row.enrollmentId,
    { endpointId: row.endpointId, generation: row.generation.toString() }]));
}

/**
 * `allowInsecureRelay` lets a minted snapshot carry a plaintext `http:` origin
 * for the local dev stack. It must come from the serving process's own env and
 * never from request input, or a caller could widen what it is being authorized
 * against; it defaults to off so every existing call site stays TLS-only.
 */
export interface RelayOptions { allowInsecureRelay?: boolean }

export async function peerAuthorizationSnapshot(db: DB, identity: Identity, relayUrls: string[],
  options: RelayOptions = {}) {
  return serializable(db, (tx) => authorizationSnapshot(tx, identity, relayUrls, options));
}

async function authorizationSnapshot(tx: Tx, identity: Identity, relayUrls: string[],
  options: RelayOptions) {
    const device = await currentIdentity(tx, identity);
    const sub = await activeSubscriptionForUser(tx, identity.userId);
    const billingId = await resolveBillingAccountId(tx, identity.userId);
    const billing = billingId ? await tx.productAccount.findUnique({ where: { id: billingId } }) : null;
    const allowed = sub !== null && billing !== null && billing.deletedAt === null;
    let policy = await tx.peerAuthorizationPolicy.upsert({ where: { userId: identity.userId },
      create: { userId: identity.userId }, update: {} });
    const relayConfigHash = createHash("sha256").update(JSON.stringify([...relayUrls].sort())).digest("hex");
    if (policy.relayConfigHash !== relayConfigHash) {
      policy = await tx.peerAuthorizationPolicy.update({ where: { userId: identity.userId },
        data: { relayConfigHash, generation: { increment: 1 } } });
      await tx.peerAuthorizationOutbox.create({ data: { userId: identity.userId, generation: policy.generation } });
    }
    const endpoints = await endpointInventory(tx, identity.userId);
    const devices = allowed ? await tx.device.findMany({ where: {
      userId: identity.userId, revokedAt: null,
      kind: device.kind === "agent" ? "app" : "agent",
      ...(device.kind === "app" ? { mobileAccessEnabled: true } : {}),
    }, take: 1025, orderBy: { id: "asc" } }) : [];
    const credentials = await tx.oauthClient.findMany({ where: {
      clientId: { in: devices.flatMap((peer) => peer.oauthClientId ? [peer.oauthClientId] : []) },
    } });
    const peers = devices.filter((peer) => {
      const credential = credentials.find((item) => item.clientId === peer.oauthClientId);
      const metadata = parseDeviceOAuthMetadata(credential?.metadata);
      return credential && !credential.disabled && credential.grantTypes.includes("client_credentials") &&
        metadata.success && metadata.data.userId === peer.userId && metadata.data.deviceUuid === peer.deviceId &&
        metadata.data.ed25519Pub === Buffer.from(peer.publicKey).toString("base64");
    }).map((peer) => ({ deviceId: peer.deviceId, ed25519Pub: Buffer.from(peer.publicKey).toString("base64"),
      endpoint: endpoints.get(peer.oauthClientId!) ?? null }));
    // Subscription expiry can precede the normal authorization lease boundary.
    const deadlines = sub ? [sub.cancelledAt, sub.trialEndsAt, sub.currentPeriodEnd]
      .filter((date): date is Date => date !== null).map((date) => date.getTime() - Date.now()) : [0];
    return peerAuthorizationSnapshotSchema(options.allowInsecureRelay === true).parse({ accountId: identity.userId, deviceId: identity.deviceId,
      enrollmentId: identity.enrollmentId, policyGeneration: policy.generation.toString(),
      registrationGeneration: (await generation(tx, identity.enrollmentId)).toString(),
      allowed, leaseMs: allowed ? Math.max(0, Math.min(PEER_LEASE_MS, ...deadlines)) : 0,
      endpoint: endpoints.get(identity.enrollmentId) ?? null, peers, relayUrls: allowed ? relayUrls : [] });
}

export async function peerRelayAdmission(db: DB, input: PeerRelayAdmissionRequest,
  relayUrls: string[], options: RelayOptions = {}): Promise<PeerRelayAdmissionResponse> {
  const denied = { allowed: false as const, requestId: input.requestId };
  if (!relayUrls.includes(input.relayUrl)) return denied;
  try {
    return await serializable(db, async (tx) => {
      const registration = await tx.peerEndpointRegistration.findUnique({ where: { endpointId: input.endpointId } });
      if (!registration || registration.revokedAt) return denied;
      const device = await tx.device.findUnique({ where: { userId_deviceId: {
        userId: registration.userId, deviceId: registration.deviceId,
      } } });
      if (!device) return denied;
      // Registration, credential binding and policy must come from one transaction.
      const snapshot = await authorizationSnapshot(tx, { id: device.id, userId: registration.userId,
        deviceId: registration.deviceId, enrollmentId: registration.enrollmentId,
        publicKey: device.publicKey, kind: device.kind }, relayUrls, options);
      if (!snapshot.allowed || snapshot.leaseMs <= 0 || snapshot.endpoint?.endpointId !== input.endpointId ||
          snapshot.endpoint.generation !== registration.generation.toString() ||
          snapshot.registrationGeneration !== registration.generation.toString()) return denied;
      return PeerRelayAdmissionResponseSchema.parse({ allowed: true, requestId: input.requestId,
        endpointId: input.endpointId, userId: snapshot.accountId, deviceId: snapshot.deviceId,
        enrollmentId: snapshot.enrollmentId, registrationGeneration: snapshot.registrationGeneration,
        policyGeneration: snapshot.policyGeneration, leaseMs: snapshot.leaseMs });
    });
  } catch (error) {
    if (error instanceof PeerAuthorizationError) return denied;
    throw error;
  }
}
