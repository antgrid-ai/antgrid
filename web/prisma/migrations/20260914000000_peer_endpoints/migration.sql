CREATE TABLE peer_endpoint_registrations (
  endpoint_id CHAR(64) PRIMARY KEY CHECK (endpoint_id ~ '^[0-9a-f]{64}$'),
  user_id TEXT NOT NULL, device_id UUID NOT NULL, enrollment_id TEXT NOT NULL,
  generation BIGINT NOT NULL CHECK (generation > 0),
  created_at TIMESTAMPTZ(6) NOT NULL DEFAULT now(), revoked_at TIMESTAMPTZ(6),
  UNIQUE (enrollment_id, generation)
);
CREATE UNIQUE INDEX peer_endpoint_one_active ON peer_endpoint_registrations(enrollment_id) WHERE revoked_at IS NULL;
CREATE INDEX peer_endpoint_registrations_user_id_idx ON peer_endpoint_registrations(user_id);
CREATE TABLE peer_endpoint_challenges (
  id UUID PRIMARY KEY, user_id TEXT NOT NULL, device_id UUID NOT NULL,
  enrollment_id TEXT NOT NULL, endpoint_id CHAR(64) NOT NULL,
  expected_generation BIGINT NOT NULL CHECK (expected_generation >= 0),
  challenge TEXT NOT NULL, expires_at TIMESTAMPTZ(6) NOT NULL, consumed_at TIMESTAMPTZ(6)
);
CREATE INDEX peer_endpoint_challenges_expires_at_idx ON peer_endpoint_challenges(expires_at);
CREATE TABLE peer_authorization_policies (user_id TEXT PRIMARY KEY, generation BIGINT NOT NULL DEFAULT 0 CHECK (generation >= 0), relay_config_hash TEXT);
CREATE TABLE peer_authorization_outbox (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id TEXT NOT NULL,
  generation BIGINT NOT NULL, created_at TIMESTAMPTZ(6) NOT NULL DEFAULT now(),
  delivered_at TIMESTAMPTZ(6), attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ(6) NOT NULL DEFAULT now()
);
CREATE INDEX peer_authorization_outbox_delivered_at_next_attempt_at_idx ON peer_authorization_outbox(delivered_at, next_attempt_at);

-- Triggers cover administrative SQL and Better-Auth writes as well as routes.
CREATE FUNCTION invalidate_peer_policy(owner_id TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE next_generation BIGINT;
BEGIN
  IF owner_id IS NULL THEN RETURN; END IF;
  INSERT INTO peer_authorization_policies(user_id, generation) VALUES(owner_id, 1)
    ON CONFLICT(user_id) DO UPDATE SET generation = peer_authorization_policies.generation + 1
    RETURNING generation INTO next_generation;
  INSERT INTO peer_authorization_outbox(user_id, generation) VALUES(owner_id, next_generation);
END $$;

CREATE FUNCTION peer_device_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE peer_endpoint_registrations SET revoked_at = now() WHERE enrollment_id = OLD.oauth_client_id AND revoked_at IS NULL;
    PERFORM invalidate_peer_policy(OLD.user_id);
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND (OLD.oauth_client_id IS DISTINCT FROM NEW.oauth_client_id OR NEW.revoked_at IS NOT NULL OR OLD.public_key IS DISTINCT FROM NEW.public_key
    OR OLD.user_id IS DISTINCT FROM NEW.user_id OR OLD.device_id IS DISTINCT FROM NEW.device_id OR OLD.kind IS DISTINCT FROM NEW.kind) THEN
    UPDATE peer_endpoint_registrations SET revoked_at = now() WHERE enrollment_id = OLD.oauth_client_id AND revoked_at IS NULL;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN PERFORM invalidate_peer_policy(OLD.user_id); END IF;
  PERFORM invalidate_peer_policy(NEW.user_id);
  RETURN NEW;
END $$;
CREATE TRIGGER peer_device_insert_delete AFTER INSERT OR DELETE ON devices FOR EACH ROW EXECUTE FUNCTION peer_device_changed();
CREATE TRIGGER peer_device_update AFTER UPDATE OF user_id, device_id, oauth_client_id, public_key, revoked_at, kind, mobile_access_enabled ON devices
  FOR EACH ROW WHEN ((OLD.user_id, OLD.device_id, OLD.oauth_client_id, OLD.public_key, OLD.revoked_at, OLD.kind, OLD.mobile_access_enabled)
    IS DISTINCT FROM (NEW.user_id, NEW.device_id, NEW.oauth_client_id, NEW.public_key, NEW.revoked_at, NEW.kind, NEW.mobile_access_enabled)) EXECUTE FUNCTION peer_device_changed();

CREATE FUNCTION peer_endpoint_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN PERFORM invalidate_peer_policy(OLD.user_id); END IF;
  PERFORM invalidate_peer_policy(CASE WHEN TG_OP = 'DELETE' THEN OLD.user_id ELSE NEW.user_id END);
  RETURN NULL;
END $$;
CREATE TRIGGER peer_endpoint_policy AFTER INSERT OR UPDATE OR DELETE ON peer_endpoint_registrations FOR EACH ROW EXECUTE FUNCTION peer_endpoint_changed();

CREATE FUNCTION peer_credential_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE owner_id TEXT; credential_id TEXT; previous_id TEXT;
BEGIN
  credential_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.client_id ELSE NEW.client_id END;
  previous_id := CASE WHEN TG_OP = 'UPDATE' THEN OLD.client_id ELSE credential_id END;
  FOR owner_id IN SELECT DISTINCT user_id FROM devices WHERE oauth_client_id IN (credential_id, previous_id) LOOP
    UPDATE peer_endpoint_registrations SET revoked_at = now() WHERE enrollment_id IN (credential_id, previous_id) AND revoked_at IS NULL;
    PERFORM invalidate_peer_policy(owner_id);
  END LOOP;
  RETURN NULL;
END $$;
CREATE TRIGGER peer_credential_delete AFTER DELETE ON oauth_client FOR EACH ROW EXECUTE FUNCTION peer_credential_changed();
CREATE TRIGGER peer_credential_update AFTER UPDATE OF client_id, disabled, metadata, grant_types ON oauth_client FOR EACH ROW
  WHEN ((OLD.client_id, OLD.disabled, OLD.metadata, OLD.grant_types) IS DISTINCT FROM (NEW.client_id, NEW.disabled, NEW.metadata, NEW.grant_types)) EXECUTE FUNCTION peer_credential_changed();

-- Billing changes may affect a team's members; over-invalidation is safe while
-- the rollout is disabled and prevents missing an indirect entitlement change.
CREATE FUNCTION peer_billing_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE owner_id TEXT;
BEGIN
  FOR owner_id IN SELECT user_id FROM peer_authorization_policies ORDER BY user_id LOOP
    PERFORM invalidate_peer_policy(owner_id);
  END LOOP;
  RETURN NULL;
END $$;
CREATE TRIGGER peer_subscription_policy AFTER INSERT OR UPDATE OR DELETE ON subscriptions FOR EACH STATEMENT EXECUTE FUNCTION peer_billing_changed();
CREATE TRIGGER peer_membership_policy AFTER INSERT OR UPDATE OR DELETE ON account_members FOR EACH STATEMENT EXECUTE FUNCTION peer_billing_changed();
CREATE TRIGGER peer_billing_account_policy AFTER UPDATE OR DELETE ON product_accounts FOR EACH STATEMENT EXECUTE FUNCTION peer_billing_changed();
CREATE TRIGGER peer_user_policy AFTER UPDATE OF account_id OR DELETE ON "user" FOR EACH STATEMENT EXECUTE FUNCTION peer_billing_changed();
