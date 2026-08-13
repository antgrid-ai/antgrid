-- Membership becomes a table rather than an overloaded column: `user.account_id`
-- is a denormalized pointer, and hanging roles, join dates and departures off it
-- would make every one of those a schema change. The subscription owner stays
-- `product_accounts` — nothing is re-parented.
--
-- Both foreign keys carry an explicit ON UPDATE CASCADE. Prisma's implicit
-- onUpdate for a required relation is Cascade, so omitting the clause here
-- (→ Postgres NO ACTION) makes the next `migrate dev` emit a spurious
-- DropForeignKey/AddForeignKey pair. Same trap as the oauth tables, which pay
-- for it the other way round with `onUpdate: NoAction` in the schema.
CREATE TABLE "account_members" (
    "id" UUID NOT NULL DEFAULT gen_random_uuid(),
    "account_id" UUID NOT NULL REFERENCES "product_accounts"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "user_id" TEXT NOT NULL REFERENCES "user"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "role" TEXT NOT NULL,
    "status" TEXT NOT NULL,
    "joined_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
    "ended_at" TIMESTAMPTZ(6),

    CONSTRAINT "account_members_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "account_members_account_user_key" ON "account_members"("account_id", "user_id");

-- One active membership per user, enforced in the database rather than in a
-- resolver: with two active rows `findFirst` picks by physical row order and the
-- same user gets different entitlements on different requests.
--
-- PARTIAL index. Prisma cannot model one and is blind to it on introspection —
-- same convention and same reason as devices_user_active_idx, so there is
-- deliberately no `@@index` for it in schema.prisma. Declaring one would make
-- every `migrate dev` try to create a conflicting plain index.
CREATE UNIQUE INDEX "account_members_one_active_per_user_idx"
  ON "account_members"("user_id") WHERE "status" = 'active';

-- Backfill: every existing account is a solo team whose owner is its user. This
-- has to run AFTER both indexes — ON CONFLICT resolves against a unique index
-- that must already exist, and reordering it earlier fails the migration with
-- 42P10 rather than a wrong row count. Tombstoned accounts are skipped: their
-- users fall through to the personal-account fallback, and an active membership
-- pointing at a dead account would be the one row the partial index then blocks
-- from ever joining a real team.
INSERT INTO "account_members" ("account_id", "user_id", "role", "status", "joined_at")
SELECT pa."id", pa."user_id", 'owner', 'active', pa."created_at"
FROM "product_accounts" pa
WHERE pa."deleted_at" IS NULL
ON CONFLICT ("account_id", "user_id") DO NOTHING;

-- Seats are the paid axis. Snapshotted onto the subscription like every other
-- limit, so a negotiated contract is not the list price.
ALTER TABLE "subscriptions" ADD COLUMN "seats" INTEGER NOT NULL DEFAULT 1;

-- Nullable: NULL is how an Enterprise contract says "unlimited". That makes it
-- the one catalog column Prisma treats as optional on create, so a plan row
-- seeded without it lands on the maximally permissive value — keep
-- CATALOG_PLANS (src/models/plan.ts) carrying an explicit maxSeats.
ALTER TABLE "plans" ADD COLUMN "max_seats" INTEGER;

-- seedPlans() upserts with `update: {}`, so a CATALOG_PLANS edit alone never
-- reaches an existing database — every catalog change needs its statement here,
-- and the two move in the same commit.
UPDATE "plans" SET "max_seats" = 1;
UPDATE "plans" SET "max_seats" = 25 WHERE slug = 'pro_yearly';

-- Members share one account, so the denormalized pointer stops being unique.
-- `user_account_id_key` is a genuine CREATE UNIQUE INDEX (20260612000000_billing),
-- not a table constraint, so DROP INDEX is the right verb. The FK on the same
-- column references product_accounts' primary key, not this index, and survives.
DROP INDEX "user_account_id_key";
CREATE INDEX "user_account_id_idx" ON "user"("account_id");
