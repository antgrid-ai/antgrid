ALTER TABLE "user" ADD COLUMN registration_origin jsonb, ADD COLUMN activation_origin jsonb;
ALTER TABLE pending_sign_in ADD COLUMN journey_id uuid, ADD COLUMN issued_session_id text, ADD COLUMN return_path text NOT NULL DEFAULT '/dashboard';
CREATE TABLE auth_journeys (recipient_hash bytea, id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id text REFERENCES "user"(id) ON DELETE CASCADE, origin jsonb NOT NULL, category text NOT NULL DEFAULT 'unknown', created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX auth_journeys_created_at_idx ON auth_journeys(created_at);
CREATE TABLE auth_flows (approval_origin jsonb, return_path text NOT NULL DEFAULT '/dashboard', id uuid PRIMARY KEY DEFAULT gen_random_uuid(), journey_id uuid NOT NULL REFERENCES auth_journeys(id) ON DELETE CASCADE, state text NOT NULL DEFAULT 'pending', session_id text, challenge text, launch_hash bytea, binding_hash bytea, code_hash bytea, consumed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL);
CREATE INDEX auth_flows_expires_at_idx ON auth_flows(expires_at);
CREATE TABLE auth_flow_events (flow_id uuid NOT NULL REFERENCES auth_flows(id) ON DELETE CASCADE, stage text NOT NULL, at timestamptz NOT NULL DEFAULT now(), failure text, PRIMARY KEY(flow_id,stage));
CREATE TABLE email_jobs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), flow_id uuid REFERENCES auth_flows(id) ON DELETE CASCADE, reference text NOT NULL UNIQUE, related_reference text, provider_id text, key_version text, payload bytea, state text NOT NULL DEFAULT 'queued', attempts integer NOT NULL DEFAULT 0, next_at timestamptz NOT NULL DEFAULT now(), lease_id uuid, lease_until timestamptz, expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), failure text);
CREATE INDEX email_jobs_state_next_at_idx ON email_jobs(state,next_at);
CREATE TABLE email_recipient_events (id text PRIMARY KEY, job_id uuid NOT NULL REFERENCES email_jobs(id) ON DELETE CASCADE, kind text NOT NULL, at timestamptz NOT NULL DEFAULT now());
CREATE TABLE auth_rate_buckets (key text PRIMARY KEY, stamps timestamptz[] NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());
CREATE FUNCTION delete_auth_browser_binding() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 DELETE FROM auth_rate_buckets WHERE key LIKE 'auth-browser-binding:%:' || OLD.id::text;
 RETURN OLD;
END $$;
CREATE TRIGGER delete_auth_browser_binding BEFORE DELETE ON auth_flows FOR EACH ROW EXECUTE FUNCTION delete_auth_browser_binding();
CREATE TABLE auth_cohorts (day date NOT NULL, dimension text NOT NULL, counts jsonb NOT NULL, PRIMARY KEY(day,dimension));
-- Removal of a session invalidates issued tickets without enabling reissuance.
CREATE FUNCTION invalidate_auth_session() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 UPDATE auth_flows SET state='revoked', code_hash=NULL WHERE session_id=OLD.id;
 RETURN OLD;
END $$;
CREATE TRIGGER invalidate_auth_session AFTER DELETE ON session FOR EACH ROW EXECUTE FUNCTION invalidate_auth_session();
-- Pending rows are deliberately retained briefly for redemption retries, but
-- must not outlive the account whose identity they carry.
CREATE FUNCTION delete_auth_pending() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 DELETE FROM auth_journeys WHERE id IN (SELECT journey_id FROM pending_sign_in WHERE approved_user_id=OLD.id OR lower(email)=lower(OLD.email::text));
 DELETE FROM pending_sign_in WHERE approved_user_id=OLD.id OR lower(email)=lower(OLD.email::text);
 RETURN OLD;
END $$;
CREATE TRIGGER delete_auth_pending BEFORE DELETE ON "user" FOR EACH ROW EXECUTE FUNCTION delete_auth_pending();

INSERT INTO auth_journeys(id, origin, category, created_at)
SELECT id, '{"surface":"unknown","platform":"unknown","method":"magic_link","version":null,"quality":"unknown"}'::jsonb, 'unknown', created_at FROM pending_sign_in;
INSERT INTO auth_flows(id, journey_id, state, expires_at, created_at)
SELECT id, id, CASE WHEN consumed_at IS NOT NULL THEN 'redeemed' ELSE 'pending' END, expires_at, created_at FROM pending_sign_in;
UPDATE pending_sign_in SET journey_id=id;
