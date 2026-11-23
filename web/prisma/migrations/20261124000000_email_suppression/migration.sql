-- Bounce suppression keyed by a keyed digest of the recipient; no plaintext address and
-- no FK, so the 30-day email_jobs sweep, the auth_journeys cascade, the 1-day
-- auth_rate_buckets sweep and account deletion never reach it.
ALTER TABLE email_jobs ADD COLUMN recipient_hash bytea;
ALTER TABLE pending_sign_in ADD COLUMN requester_entry text;

CREATE TABLE email_suppressions (
  recipient_hash bytea PRIMARY KEY CHECK (octet_length(recipient_hash) = 32),
  reason         text NOT NULL CHECK (reason IN ('recipient', 'unclassified', 'complaint')),
  events         integer NOT NULL DEFAULT 1,
  created_at     timestamptz(6) NOT NULL DEFAULT now(),
  updated_at     timestamptz(6) NOT NULL DEFAULT now(),
  expires_at     timestamptz(6) NOT NULL,
  lifted_at      timestamptz(6)
);
CREATE INDEX email_suppressions_expires_at_idx ON email_suppressions (expires_at);
