-- Add waitlist_signup for the marketing site's launch-interest capture.
-- Rows are written by the anonymous, cross-origin POST /api/waitlist route; no
-- FK to user — a signup happens long before an account exists.
--
-- The unique index on "email" is load-bearing, not hygiene: the route inserts
-- with ON CONFLICT DO NOTHING so a repeat submit is a silent no-op answered
-- with the same 200 as a first submit. Without it a second submit would create
-- a duplicate row, and any later de-dup would have to distinguish the two —
-- which is exactly the membership fact the endpoint must not expose.

CREATE TABLE "waitlist_signup" (
  "id"         UUID           NOT NULL DEFAULT gen_random_uuid(),
  "email"      TEXT           NOT NULL,
  "source"     TEXT           NOT NULL,
  "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

  CONSTRAINT "waitlist_signup_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "waitlist_signup_email_key"      ON "waitlist_signup" ("email");
CREATE INDEX        "waitlist_signup_created_at_idx" ON "waitlist_signup" ("created_at");
