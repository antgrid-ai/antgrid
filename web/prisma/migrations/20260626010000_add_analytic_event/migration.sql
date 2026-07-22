-- Add analytic_event table for first-party anonymous usage analytics.
-- Rows are written by the POST /events route; no FK to user — installId
-- is a random per-install UUID, not an account identifier.

CREATE TABLE "analytic_event" (
  "id"          UUID        NOT NULL DEFAULT gen_random_uuid(),
  "install_id"  TEXT        NOT NULL,
  "name"        TEXT        NOT NULL,
  "ts"          TIMESTAMPTZ(6) NOT NULL,
  "platform"    TEXT        NOT NULL,
  "app_version" TEXT        NOT NULL,
  "props"       JSONB,
  "created_at"  TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

  CONSTRAINT "analytic_event_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "analytic_event_name_ts_idx"    ON "analytic_event" ("name", "ts");
CREATE INDEX "analytic_event_install_ts_idx" ON "analytic_event" ("install_id", "ts");
