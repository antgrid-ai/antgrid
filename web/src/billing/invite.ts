import { z } from "zod";
import type { DB } from "../db/index.js";
import type { SendEmail } from "../auth/email.js";
import {
  checkInviteToken,
  countPendingInvites,
  createInvite,
  expireStalePendingInvites,
  findPendingInviteByIdWithHash,
  generateInviteToken,
  inviteEmailReference,
  markInviteAccepted,
  refreshInviteToken,
  INVITE_TTL_SECONDS,
  type AccountInviteRow,
} from "../models/account-invite.js";
import {
  ACCOUNT_MEMBER_STATUS_ACTIVE,
  countActiveSeatHolders,
  type AccountMemberRole,
} from "../models/account-member.js";
import { activeSubscriptionForAccount } from "../models/subscription.js";
import { addAccountMember, AddMemberError } from "./add-member.js";

export class InviteError extends Error {
  constructor(
    readonly code:
      | "INVALID_EMAIL"
      | "ALREADY_MEMBER"
      | "ALREADY_INVITED"
      | "NO_ACTIVE_SUBSCRIPTION"
      | "OVER_SUBSCRIBED"
      | "SEAT_CAP"
      | "HAS_PAID_SUBSCRIPTION"
      | "ALREADY_ON_THIS_ACCOUNT"
      | "INVALID_LINK"
      | "EMAIL_MISMATCH"
      | "EMAIL_UNVERIFIED"
      | "UNKNOWN_ROLE",
    message?: string,
    /** The number the refusal is about — seats purchased, for the two seat
     *  refusals. An owner told only "full" cannot tell what to do next. */
    readonly limit?: number
  ) {
    super(message ?? code);
    this.name = "InviteError";
  }
}

function isUniqueViolation(e: unknown): boolean {
  return typeof e === "object" && e !== null && (e as { code?: string }).code === "P2002";
}

/** Lowercased so the stored address renders the way the owner will recognize
 *  it. Uniqueness does not depend on this — both `user.email` and
 *  `account_invites.email` are citext. */
export function normalizeInviteEmail(raw: string): string {
  return raw.trim().toLowerCase();
}

/**
 * Issue an invitation, refusing anything that could not be honoured.
 *
 * Under `pg_advisory_xact_lock(hashtext('billing:' || accountId))` — the key the
 * reducer, `updateSubscriptionSeats` and `addAccountMember` all take, so a
 * webhook shrinking the contract cannot land between the count and the insert.
 *
 * The seat sum is holders PLUS outstanding invites. Counting holders alone lets
 * an owner send ten invitations against one free seat, nine of which are refused
 * at accept time in front of the person who was invited. Accept-time counts
 * holders alone for the mirror-image reason — see `countPendingInvites`.
 *
 * The mail is NOT sent here: an HTTP round trip inside an interactive
 * transaction blocks every webhook for the account behind the lock and dies on
 * Prisma's 5s timeout. The caller sends after the commit.
 */
export async function createAccountInvite(
  db: DB,
  args: {
    accountId: string;
    email: string;
    role: AccountMemberRole;
    createdBy: string;
    secret: string;
  }
): Promise<{ invite: AccountInviteRow; token: string }> {
  const email = normalizeInviteEmail(args.email);
  if (!z.email().safeParse(email).success) throw new InviteError("INVALID_EMAIL");

  const token = generateInviteToken();
  const invite = await db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${args.accountId}`}))`;

    // Both conditions `addAccountMember` refuses on, checked here too so the
    // owner learns now rather than the invitee learning at accept time. The
    // second catches an owner inviting themselves: they hold a membership row on
    // their own account in every path that heals one, but the account ownership
    // is the fact that does not depend on that row existing.
    const existing = await tx.user.findUnique({ where: { email }, select: { id: true } });
    if (existing) {
      const [member, owned] = await Promise.all([
        tx.accountMember.findFirst({
          where: {
            accountId: args.accountId,
            userId: existing.id,
            status: ACCOUNT_MEMBER_STATUS_ACTIVE,
          },
          select: { id: true },
        }),
        tx.productAccount.findUnique({ where: { userId: existing.id }, select: { id: true } }),
      ]);
      if (member || owned?.id === args.accountId) throw new InviteError("ALREADY_MEMBER");
    }

    // Before both counts: a lapsed invite is still `pending` to the seat sum and
    // still owns its address in the partial unique index, so sweeping is what
    // keeps a month-old invitation from holding a seat nobody can claim.
    await expireStalePendingInvites(tx, args.accountId);

    const sub = await activeSubscriptionForAccount(tx, args.accountId);
    // Not a default of one: an account with no live contract has no seat to sell.
    if (!sub) throw new InviteError("NO_ACTIVE_SUBSCRIPTION");

    const seatHolders = await countActiveSeatHolders(tx, args.accountId);
    // Checked ahead of the cap it is arithmetically a subset of, because the two
    // ask different things of the owner: over-subscribed means the team is
    // already bigger than the bill and either buying seats or removing someone
    // fixes it, where a merely full team only needs a seat. Being over-subscribed
    // blocks NEW invites and nothing else — existing members keep working, and
    // nobody is ever removed to make a number fit.
    if (seatHolders > sub.seats) {
      throw new InviteError(
        "OVER_SUBSCRIBED",
        `this account has ${seatHolders} members on ${sub.seats} seats; buy seats or remove someone before inviting`,
        sub.seats
      );
    }
    const pending = await countPendingInvites(tx, args.accountId);
    if (seatHolders + pending >= sub.seats) {
      throw new InviteError(
        "SEAT_CAP",
        `all ${sub.seats} seats are taken or promised (${seatHolders} in use, ${pending} invited); buy another before inviting`,
        sub.seats
      );
    }

    try {
      return await createInvite(tx, { ...args, email, token });
    } catch (e) {
      // 23505 on `account_invites_one_pending_per_email_idx`, which the sweep
      // above has already cleared of lapsed rows — so the collision is a live
      // invitation, and resend is the verb the owner wants.
      if (isUniqueViolation(e)) throw new InviteError("ALREADY_INVITED");
      throw e;
    }
  });

  return { invite, token };
}

/** Re-arm an outstanding invite with a fresh token, invalidating the one already
 *  in the invitee's inbox — two live tokens for one seat is two ways in, and the
 *  older mail is the one an attacker who saw it would still be holding. Null
 *  when the invite is no longer pending. */
export async function resendAccountInvite(
  db: DB,
  args: { id: string; accountId: string; secret: string }
): Promise<{ invite: AccountInviteRow; token: string } | null> {
  const token = generateInviteToken();
  const invite = await refreshInviteToken(db, { ...args, token });
  return invite ? { invite, token } : null;
}

/**
 * Take an invitation, putting the signed-in user on the inviting account.
 *
 * Two things this deliberately does NOT do.
 *
 * It does not prove an email address. The invitee must already be signed in and
 * already verified, and nothing here writes `emailVerified` — a third flip that
 * forgot `purgeUnprovenPasswordCredential` would re-open the takeover the two
 * existing flips (trusted-social linking, magic-link approve) pay for. Not
 * flipping it at all is the only version of this with nothing to forget.
 *
 * And it does not insert a membership. `addAccountMember` is the single choke
 * point, so the seat check and the personal-subscription cancellation cannot be
 * skipped by arriving through this door.
 *
 * The address check is what stops the link being a bearer token: the token
 * proves someone read the mail, not that they are the person it was sent to.
 */
export async function acceptAccountInvite(
  db: DB,
  args: { inviteId: string; token: string; userId: string; secret: string }
): Promise<{ accountId: string }> {
  const user = await db.user.findUniqueOrThrow({
    where: { id: args.userId },
    select: { email: true, emailVerified: true },
  });

  const invite = await findPendingInviteByIdWithHash(db, args.inviteId);
  if (!invite) throw new InviteError("INVALID_LINK");
  if (!checkInviteToken(invite.tokenHash, args.token, args.secret)) {
    throw new InviteError("INVALID_LINK");
  }
  // Unparseable role — the value goes straight into the membership row, so
  // guessing at it would be guessing at whether this person can cancel the
  // team's contract.
  if (invite.role === null) throw new InviteError("UNKNOWN_ROLE");
  if (normalizeInviteEmail(user.email) !== normalizeInviteEmail(invite.email)) {
    throw new InviteError("EMAIL_MISMATCH");
  }
  // An unproven address must not be able to claim mail addressed to it. In
  // practice `requireEmailVerification` withholds the session that gets this
  // far, which is exactly why this stays a refusal and never a repair.
  if (!user.emailVerified) throw new InviteError("EMAIL_UNVERIFIED");

  try {
    await addAccountMember(db, {
      accountId: invite.accountId,
      userId: args.userId,
      role: invite.role,
    });
  } catch (e) {
    if (e instanceof AddMemberError) {
      // Already on this account: the membership landed and the consume did not —
      // a crash between the two writes, or a double-submit. Reporting a failure
      // to someone who is demonstrably on the team would be a lie, and would
      // leave the invitation pending against a seat forever.
      if (e.code === "ALREADY_ON_THIS_ACCOUNT") {
        await markInviteAccepted(db, invite.id);
        return { accountId: invite.accountId };
      }
      throw new InviteError(e.code, e.message, e.limit);
    }
    throw e;
  }

  // Consumed after the membership commits, not before. A refusal must not burn
  // the invitation — a seat that vanished under a concurrent accept is worth
  // retrying — and replay is not resting on this write anyway: the read above
  // filters on `pending`, and two accepts that interleave past it both reach
  // `addAccountMember`, where the advisory lock makes the second one
  // ALREADY_ON_THIS_ACCOUNT rather than a second membership.
  if (!(await markInviteAccepted(db, invite.id))) {
    console.warn(
      JSON.stringify({
        evt: "invite.consumed_race",
        inviteId: invite.id,
        accountId: invite.accountId,
        at: new Date().toISOString(),
      })
    );
  }
  return { accountId: invite.accountId };
}

const INVITE_TTL_DAYS = Math.round(INVITE_TTL_SECONDS / 86400);

/**
 * Mail the invitation.
 *
 * What the cost paragraph is doing here: accepting cancels whatever
 * subscription the invitee holds, and for the whole pre-activation cohort that
 * is a Pro grant nobody charged them for and leaving the team will not return.
 * It is the one place in the product a user can lose Pro without buying
 * anything, so it is said before they click, not after.
 *
 * One URL in the body, deliberately — the test helper that pulls the link out of
 * captured mail takes the first one it finds.
 */
export async function sendInviteEmail(
  sendEmail: SendEmail,
  args: {
    to: string;
    inviteId: string;
    token: string;
    invitedBy: string;
    baseUrl: string;
  }
): Promise<void> {
  const url = new URL(
    `/invite?id=${args.inviteId}&t=${encodeURIComponent(args.token)}`,
    args.baseUrl
  ).toString();

  await sendEmail({
    to: args.to,
    subject: "You've been invited to a team on Antgrid",
    text:
      `${args.invitedBy} invited you to join their team on Antgrid.\n\n` +
      `Accept the invitation: ${url}\n\n` +
      `Before you accept: joining moves your account onto their subscription and ` +
      `CANCELS the subscription you hold today — including a free Pro grant you ` +
      `were never charged for. Leaving the team later does not bring it back.\n\n` +
      `Sign in as ${args.to} first; the invitation can only be accepted by that ` +
      `address.\n\n` +
      `This invitation expires in ${INVITE_TTL_DAYS} days. If you were not ` +
      `expecting it, ignore this email.`,
    clientReference: inviteEmailReference(args.inviteId),
  });
}
