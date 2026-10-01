-- Operator usage history behind /internal/stats, written by web's usage
-- sampler (src/usage/sampler.ts), which documents how each table is read,
-- written and pruned. Device last_seen_at is overwritten on every heartbeat and
-- the relay keeps no history, so neither can answer "how many were active on a
-- past day".
--
-- analytic_event.created_at is indexed because the stats windows use the
-- server-stamped time, which the existing (name, ts) indexes cannot serve.

CREATE TABLE "usage_daily" (
  "day"                 DATE           NOT NULL,
  "active_users"        INTEGER        NOT NULL DEFAULT 0,
  "active_mobile_apps"  INTEGER        NOT NULL DEFAULT 0,
  "active_desktop_apps" INTEGER        NOT NULL DEFAULT 0,
  "active_agents"       INTEGER        NOT NULL DEFAULT 0,
  "relay_peak_apps"     INTEGER        NOT NULL DEFAULT 0,
  "relay_peak_agents"   INTEGER        NOT NULL DEFAULT 0,
  "relay_peak_total"    INTEGER        NOT NULL DEFAULT 0,
  "relay_seen_apps"     INTEGER        NOT NULL DEFAULT 0,
  "relay_seen_agents"   INTEGER        NOT NULL DEFAULT 0,
  "updated_at"          TIMESTAMPTZ(6) NOT NULL DEFAULT now(),

  CONSTRAINT "usage_daily_pkey" PRIMARY KEY ("day")
);

CREATE TABLE "usage_relay_seen" (
  "day"         DATE NOT NULL,
  "device_id"   TEXT NOT NULL,
  "device_type" TEXT NOT NULL,

  CONSTRAINT "usage_relay_seen_pkey" PRIMARY KEY ("day", "device_id")
);

CREATE TABLE "usage_heartbeat_seen" (
  "day"       DATE NOT NULL,
  "user_id"   TEXT NOT NULL,
  "device_id" TEXT NOT NULL,

  CONSTRAINT "usage_heartbeat_seen_pkey" PRIMARY KEY ("day", "user_id", "device_id")
);

-- Partial (WHERE revoked_at IS NULL), so raw SQL only: Prisma cannot model it.
-- Serves the sampler's device_id lookups for relay-held devices.
CREATE INDEX "devices_device_id_active_idx" ON "devices" ("device_id") WHERE "revoked_at" IS NULL;

CREATE INDEX "analytic_event_created_at_idx" ON "analytic_event" ("created_at");
