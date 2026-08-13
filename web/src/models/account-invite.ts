import { randomBytes } from "node:crypto";
import { z } from "zod";
import type { Tx } from "../db/index.js";
import { hmacBytes, hmacMatches } from "../util/hmac.js";
import { AccountMemberRoleSchema, type AccountMemberRole } from "./account-member.js";
import type { DeliveryStatus } from "./pending-sign-in.js";

export const AccountInviteStatusSchema = z.enum(["pending", "accepted", "revoked", "expired"]);
export type AccountInviteStatus = z.infer<typeof AccountInviteStatusSchema>;

/** The one status the partial unique index and every outstanding-invite read key
 *  on. Derived from the schema rather than spelled inline so a widened union
 *  cannot leave a bare `"pending"` behind in a where-clause — the same reason
 *  ACCOUNT_MEMBER_STATUS_ACTIVE exists. */
export const ACCOUNT_INVITE_STATUS_PENDING: AccountInviteStatus =
  AccountInviteStatusSchema.enum.pending;

/** A week: long enough to survive a holiday, short enough that a mailbox someone
 *  else later takes over is not still holding a live seat on someone's team. */
export const INVITE_TTL_SECONDS = 7 * 24 * 60 * 60;
export const INVITE_TOKEN_BYTES = 32;

export type AccountInviteRow = {
  id: string;
  accountId: string;
  email: string;
  /** null when the stored role is outside the schema. Fail closed: this value is
   *  written straight into the membership row, so acceptance must refuse rather
   *  than guess at it. */
  role: AccountMemberRole | null;
  createdBy: string;
  expiresAt: Date;
  /** Non-null only ever means the address is dead — ZeptoMail sends no delivered
   *  event, so silence is the success case. */
  deliveryStatus: string | null;
  createdAt: Date;
};

/** Standard public projection — excludes the token hash. */
const rowSelect = {
  id: true,
  accountId: true,
  email: true,
  role: true,
  createdBy: true,
  expiresAt: true,
  deliveryStatus: true,
  createdAt: true,
} as const;

type StoredRow = {
  id: string;
  accountId: string;
  email: string;
  role: string;
  createdBy: string;
  expiresAt: Date;
  deliveryStatus: string | null;
  createdAt: Date;
};

function toRow(row: StoredRow): AccountInviteRow {
  const role = AccountMemberRoleSchema.safeParse(row.role);
  return { ...row, role: role.success ? role.data : null };
}

export function generateInviteToken(): string {
  return randomBytes(INVITE_TOKEN_BYTES).toString("base64url");
}

/**
 * Issue a pending invite, storing only the HMAC of the token that travels in the
 * URL.
 *
 * The caller must have swept lapsed invites for this account first
 * (`expireStalePendingInvites`) and must hold the billing advisory lock:
 * `account_invites_one_pending_per_email_idx` cannot see expiry, so an invite
 * that lapsed a month ago still owns the slot and this create fails with 23505
 * on an address the owner is entitled to re-invite.
 */
export async function createInvite(
  tx: Tx,
  args: {
    accountId: string;
    email: string;
    role: AccountMemberRole;
    createdBy: string;
    token: string;
    secret: string;
  }
): Promise<AccountInviteRow> {
  const row = await tx.accountInvite.create({
    data: {
      accountId: args.accountId,
      email: args.email,
      role: args.role,
      status: ACCOUNT_INVITE_STATUS_PENDING,
      tokenHash: hmacBytes(args.secret, args.token),
      createdBy: args.createdBy,
      expiresAt: new Date(Date.now() + INVITE_TTL_SECONDS * 1000),
    },
    select: rowSelect,
  });
  return toRow(row);
}

/** Re-arm an outstanding invite with a fresh token and a fresh TTL.
 *
 *  Account-scoped so a resend cannot be aimed at another team's invite id, and
 *  in this module because the HMAC secret must never leave it. Returns null when
 *  the invite is no longer pending — a resend is not a way to revive a revoked
 *  one. */
export async function refreshInviteToken(
  tx: Tx,
  args: { id: string; accountId: string; token: string; secret: string }
): Promise<AccountInviteRow | null> {
  const now = new Date();
  const res = await tx.accountInvite.updateMany({
    where: { id: args.id, accountId: args.accountId, status: ACCOUNT_INVITE_STATUS_PENDING },
    data: {
      tokenHash: hmacBytes(args.secret, args.token),
      expiresAt: new Date(now.getTime() + INVITE_TTL_SECONDS * 1000),
      // Cleared so the flag always describes the LATEST send. Left in place, a
      // bounce recorded against the first mail would make the resend
      // indistinguishable from one that bounced too.
      deliveryStatus: null,
      updatedAt: now,
    },
  });
  if (res.count === 0) return null;
  const row = await tx.accountInvite.findUnique({ where: { id: args.id }, select: rowSelect });
  return row ? toRow(row) : null;
}

/** The invite as the acceptance screen may see it — pending and unexpired, with
 *  the TTL enforced in the query rather than by the caller. */
export async function findPendingInviteById(
  tx: Tx,
  id: string
): Promise<AccountInviteRow | null> {
  const row = await tx.accountInvite.findFirst({
    where: { id, status: ACCOUNT_INVITE_STATUS_PENDING, expiresAt: { gt: new Date() } },
    select: rowSelect,
  });
  return row ? toRow(row) : null;
}

/** Explicitly named twin of `findPendingInviteById` that also returns the hash,
 *  so the public projection can never leak it by accident. */
export async function findPendingInviteByIdWithHash(
  tx: Tx,
  id: string
): Promise<(AccountInviteRow & { tokenHash: Uint8Array }) | null> {
  const row = await tx.accountInvite.findFirst({
    where: { id, status: ACCOUNT_INVITE_STATUS_PENDING, expiresAt: { gt: new Date() } },
    select: { ...rowSelect, tokenHash: true },
  });
  return row ? { ...toRow(row), tokenHash: row.tokenHash } : null;
}

/** Constant-time HMAC check: hashes `presented` with `secret`, compares to `stored`. */
export function checkInviteToken(
  stored: Uint8Array,
  presented: string,
  secret: string
): boolean {
  return hmacMatches(stored, presented, secret);
}

export async function listPendingInvites(
  tx: Tx,
  accountId: string
): Promise<AccountInviteRow[]> {
  const rows = await tx.accountInvite.findMany({
    where: { accountId, status: ACCOUNT_INVITE_STATUS_PENDING, expiresAt: { gt: new Date() } },
    orderBy: { createdAt: "desc" },
    select: rowSelect,
  });
  return rows.map(toRow);
}

/**
 * Seats already spoken for by invitations nobody has accepted yet.
 *
 * The seat count at invite CREATE is this plus `countActiveSeatHolders`, or an
 * owner sends ten invites against one free seat and nine of them are refused at
 * accept time, in front of the invitee. Accept-time counts seat holders alone —
 * adding the pending ones there would refuse the last legitimate acceptance.
 */
export async function countPendingInvites(tx: Tx, accountId: string): Promise<number> {
  return tx.accountInvite.count({
    where: { accountId, status: ACCOUNT_INVITE_STATUS_PENDING, expiresAt: { gt: new Date() } },
  });
}

/** Retire invites whose TTL has run out, freeing both the seat they were counted
 *  against and the slot `account_invites_one_pending_per_email_idx` holds for
 *  their address. Nothing runs this on a schedule — the invite-create path calls
 *  it under the billing lock, which is the only moment either matters. */
export async function expireStalePendingInvites(tx: Tx, accountId: string): Promise<number> {
  const now = new Date();
  const res = await tx.accountInvite.updateMany({
    where: { accountId, status: ACCOUNT_INVITE_STATUS_PENDING, expiresAt: { lte: now } },
    data: { status: AccountInviteStatusSchema.enum.expired, resolvedAt: now, updatedAt: now },
  });
  return res.count;
}

/**
 * Consume the invite, returning false when someone already did.
 *
 * The pending-and-unexpired predicate lives in the WHERE, not in a preceding
 * read: two concurrent acceptances both pass a read, and only the conditional
 * write makes the second one lose. It has to run in the same transaction as the
 * membership insert, or the loser joins anyway.
 */
export async function markInviteAccepted(tx: Tx, id: string): Promise<boolean> {
  const now = new Date();
  const res = await tx.accountInvite.updateMany({
    where: { id, status: ACCOUNT_INVITE_STATUS_PENDING, expiresAt: { gt: now } },
    data: { status: AccountInviteStatusSchema.enum.accepted, resolvedAt: now, updatedAt: now },
  });
  return res.count === 1;
}

/**
 * Namespace for the ZeptoMail `client_reference` on invite mail.
 *
 * A bare invite id would be routed to `markDelivery` by the webhook — every
 * reference goes there — where it passes the `z.uuid()` guard, updates zero
 * `pending_sign_in` rows and logs a line that reads like a benign late bounce.
 * The prefix is what gives `routes/email-webhooks.ts` something to branch on,
 * and it fails that UUID guard cleanly if the branch is ever dropped.
 */
export const INVITE_REFERENCE_PREFIX = "invite:";

export function inviteEmailReference(id: string): string {
  return `${INVITE_REFERENCE_PREFIX}${id}`;
}

/** Record a bounce against the invite. Mirrors `markDelivery`: the UUID guard
 *  keeps a malformed reference a clean no-op, and `updateMany` returns zero
 *  rather than throwing for an invite already accepted, revoked or purged. */
export async function markInviteDelivery(
  tx: Tx,
  id: string,
  status: DeliveryStatus
): Promise<number> {
  if (!z.uuid().safeParse(id).success) return 0;
  const res = await tx.accountInvite.updateMany({
    where: { id },
    data: { deliveryStatus: status },
  });
  return res.count;
}

/** Withdraw an outstanding invite. Account-scoped so an owner cannot revoke
 *  another team's invite by id. False when it was not pending to begin with. */
export async function revokeInvite(tx: Tx, accountId: string, id: string): Promise<boolean> {
  const now = new Date();
  const res = await tx.accountInvite.updateMany({
    where: { id, accountId, status: ACCOUNT_INVITE_STATUS_PENDING },
    data: { status: AccountInviteStatusSchema.enum.revoked, resolvedAt: now, updatedAt: now },
  });
  return res.count === 1;
}
