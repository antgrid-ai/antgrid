import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import type { Tx } from "../db/index.js";

// Only a hard bounce is recorded. ZeptoMail emits no "delivered" webhook event
// (verified against a live Agent: hardbounce/softbounce/fbl_compliant only), so
// success is never signalled — a non-null value here always means the address
// is dead and the link never arrived.
export type DeliveryStatus = "bounced";

export const PENDING_TTL_SECONDS = 600;
export const NONCE_BYTES = 32;
export const BROWSER_TOKEN_BYTES = 32;

export type PendingSignInRow = {
  id: string;
  email: string;
  approvedAt: Date | null;
  approvedUserId: string | null;
  consumedAt: Date | null;
  expiresAt: Date;
  requesterUa: string | null;
  requesterIp: string | null;
};

// HMAC-SHA256(secret, value) returned as a Uint8Array<ArrayBuffer> — the strict
// shape Prisma expects for Bytes columns in this project: never `Buffer`,
// always `new Uint8Array(new ArrayBuffer(n))`.
function hmac(secret: string, value: string): Uint8Array<ArrayBuffer> {
  const digest = createHmac("sha256", secret).update(value).digest();
  const out = new Uint8Array(new ArrayBuffer(digest.length));
  out.set(digest);
  return out;
}

export function generateNonce(): string {
  return randomBytes(NONCE_BYTES).toString("base64url");
}

export function generateBrowserToken(): string {
  return randomBytes(BROWSER_TOKEN_BYTES).toString("base64url");
}

/** Standard public projection — excludes hash columns. */
const rowSelect = {
  id: true,
  email: true,
  approvedAt: true,
  approvedUserId: true,
  consumedAt: true,
  expiresAt: true,
  requesterUa: true,
  requesterIp: true,
} as const;

export async function createPending(
  tx: Tx,
  args: {
    email: string;
    nonce: string;
    browserToken: string;
    secret: string;
    requesterUa: string | null;
    requesterIp: string | null;
  }
): Promise<PendingSignInRow> {
  const nonceHash = hmac(args.secret, args.nonce);
  const browserTokenHash = hmac(args.secret, args.browserToken);
  const expiresAt = new Date(Date.now() + PENDING_TTL_SECONDS * 1000);

  return tx.pendingSignIn.create({
    data: {
      email: args.email,
      nonceHash,
      browserTokenHash,
      requesterUa: args.requesterUa,
      requesterIp: args.requesterIp,
      expiresAt,
    },
    select: rowSelect,
  });
}

export async function findValidById(tx: Tx, id: string): Promise<PendingSignInRow | null> {
  return tx.pendingSignIn.findFirst({
    where: { id, expiresAt: { gt: new Date() } },
    select: rowSelect,
  });
}

export async function findByIdWithHashes(
  tx: Tx,
  id: string
): Promise<{
  id: string;
  email: string;
  nonceHash: Uint8Array;
  browserTokenHash: Uint8Array;
  approvedAt: Date | null;
  approvedUserId: string | null;
  consumedAt: Date | null;
  expiresAt: Date;
  requesterUa: string | null;
  requesterIp: string | null;
  deliveryStatus: string | null;
} | null> {
  return tx.pendingSignIn.findFirst({
    where: { id, expiresAt: { gt: new Date() } },
    select: {
      ...rowSelect,
      nonceHash: true,
      browserTokenHash: true,
      deliveryStatus: true,
    },
  });
}

/** Constant-time HMAC check: hashes `presented` with `secret`, compares to `stored`. */
export function checkNonce(stored: Uint8Array, presented: string, secret: string): boolean {
  const computed = hmac(secret, presented);
  if (stored.length !== computed.length) return false;
  return timingSafeEqual(stored, computed);
}

export async function markApproved(tx: Tx, id: string, userId: string): Promise<void> {
  await tx.pendingSignIn.update({
    where: { id },
    data: { approvedAt: new Date(), approvedUserId: userId },
  });
}

export async function markConsumed(tx: Tx, id: string): Promise<void> {
  await tx.pendingSignIn.update({
    where: { id },
    data: { consumedAt: new Date() },
  });
}

export async function markDelivery(
  tx: Tx,
  clientReference: string,
  status: DeliveryStatus
): Promise<number> {
  // clientReference IS the pending row id (set as the ZeptoMail client_reference
  // at send). Guard non-UUIDs so a malformed reference is a clean no-op rather
  // than a Prisma "invalid input syntax for type uuid" throw. updateMany (not
  // update) so a webhook landing after the row expired-and-was-purged updates
  // zero rows instead of throwing.
  if (!z.uuid().safeParse(clientReference).success) return 0;
  const res = await tx.pendingSignIn.updateMany({
    where: { id: clientReference },
    data: { deliveryStatus: status },
  });
  return res.count;
}

export async function deleteExpired(tx: Tx): Promise<number> {
  const result = await tx.pendingSignIn.deleteMany({
    where: { expiresAt: { lt: new Date() } },
  });
  return result.count;
}
