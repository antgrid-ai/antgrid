-- An invitation is a promise of a seat nobody occupies yet, so it cannot be an
-- `account_members` row: a pending row there would count against
-- `countActiveSeatHolders` the moment it existed, and
-- `account_members_one_active_per_user_idx` would refuse an invite to anyone who
-- has ever signed in. Separate table, separate lifecycle; the create-time seat
-- math adds the two counts.
--
-- Both foreign keys carry an explicit ON UPDATE CASCADE. Prisma's implicit
-- onUpdate for a required relation is Cascade, so omitting the clause here
-- (→ Postgres NO ACTION) makes the next `migrate dev` emit a spurious
-- DropForeignKey/AddForeignKey pair. Same trap as account_members.
CREATE TABLE "account_invites" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "account_id" UUID NOT NULL REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    -- CITEXT, matching `user.email`: the invite sent to Ada@x.test is the one Ada
    -- accepts signed in as ada@x.test, and the pending-uniqueness index below
    -- only means anything case-insensitively. The extension is installed by the
    -- init migration.
    "email" CITEXT NOT NULL,
    "role" TEXT NOT NULL,
    "status" TEXT NOT NULL,
    -- HMAC of the token that travels in the invite URL. The plain token is never
    -- stored, same as pending_sign_in.nonce_hash.
    "token_hash" BYTEA NOT NULL,
    -- Account deletion TOMBSTONES the user row rather than deleting it, so this
    -- cascade almost never fires and an invite outlives the owner who sent it.
    -- Retiring outstanding invites is the application's job, not the FK's.
    "created_by" TEXT NOT NULL REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "expires_at" TIMESTAMPTZ(6) NOT NULL,
    -- When the invite left `pending`, whichever terminal status it landed on.
    -- One column rather than accepted_at/revoked_at/expired_at, of which exactly
    -- one could ever be set: `status` already says which.
    "resolved_at" TIMESTAMPTZ(6),
    -- Delivery outcome from the ZeptoMail webhook, keyed by the namespaced
    -- client_reference `invite:<id>`. Without somewhere to put it the webhook
    -- has no branch to take and a hard bounce is discarded in silence — an owner
    -- would wait on an invite that can never arrive at a mistyped address.
    "delivery_status" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "updated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

    CONSTRAINT "account_invites_pkey" PRIMARY KEY ("id")
);

-- One outstanding invite per address per account. Without it an owner clicking
-- "invite" twice buys two pending rows, the create-time seat count doubles
-- against them, and revoking one leaves the other live.
--
-- It keys on `status` alone and not on expiry, because a partial index predicate
-- cannot reference now(). A lapsed invite therefore keeps occupying the slot
-- until something flips it to `expired` — which is why the create path sweeps
-- first (expireStalePendingInvites, src/models/account-invite.ts).
--
-- PARTIAL index. Prisma cannot model one and is blind to it on introspection —
-- same convention and same reason as account_members_one_active_per_user_idx, so
-- there is deliberately no `@@unique` for it in schema.prisma. Declaring one
-- would make every `migrate dev` try to create a conflicting plain index.
CREATE UNIQUE INDEX "account_invites_one_pending_per_email_idx"
  ON "account_invites"("account_id", "email") WHERE "status" = 'pending';

-- CreateIndex
CREATE INDEX "account_invites_account_status_idx" ON "account_invites"("account_id", "status");

-- The invitee arrives knowing only their own address.
-- CreateIndex
CREATE INDEX "account_invites_email_idx" ON "account_invites"("email");

-- CreateIndex
CREATE INDEX "account_invites_expires_idx" ON "account_invites"("expires_at");

ALTER TABLE "account_invites" ADD CONSTRAINT account_invites_email_check
  CHECK (length(email) > 0 AND length(email) <= 320);
