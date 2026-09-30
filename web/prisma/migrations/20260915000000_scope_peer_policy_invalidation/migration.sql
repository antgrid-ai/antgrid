-- Scope billing invalidation to the account that changed.
--
-- The statement-level triggers replaced here could not see which rows a
-- statement touched, so they invalidated EVERY policy row on any write to the
-- four billing tables, and fired even when the statement changed nothing. One
-- no-op `UPDATE "user" SET account_id` — which ensureProductAccount issued on
-- nearly every authenticated request — was therefore enough to retire every
-- live peer connection in the deployment, once per request.

CREATE FUNCTION invalidate_peer_policy_for_account(target_account UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE owner_id TEXT;
BEGIN
  IF target_account IS NULL THEN RETURN; END IF;
  -- Wider than listBillingAccountUserIds (models/account-member.ts), which
  -- counts active members only: a membership that has just ended still has
  -- connections to retire, and being wrong in that direction costs a reconnect
  -- where the other direction leaves an unauthorized peer attached. The owner
  -- is unconditional because entitlement falls back to the account they own
  -- whether or not a membership row exists. Ordered so two concurrent
  -- invalidations of overlapping sets cannot deadlock on the policy rows.
  FOR owner_id IN
    SELECT user_id FROM product_accounts WHERE id = target_account
    UNION
    SELECT user_id FROM account_members WHERE account_id = target_account
    ORDER BY 1
  LOOP
    PERFORM invalidate_peer_policy(owner_id);
  END LOOP;
END $$;

-- Entitlement itself, and rewritten only by checkout, a gateway webhook or seat
-- reconciliation — rare enough that every write invalidates rather than
-- enumerating the columns behind resolveEntitlement and activeSubscriptionWhere.
CREATE FUNCTION peer_subscription_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.account_id IS DISTINCT FROM NEW.account_id THEN
    PERFORM invalidate_peer_policy_for_account(OLD.account_id);
  END IF;
  PERFORM invalidate_peer_policy_for_account(CASE WHEN TG_OP = 'DELETE' THEN OLD.account_id ELSE NEW.account_id END);
  RETURN NULL;
END $$;

CREATE FUNCTION peer_membership_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN PERFORM invalidate_peer_policy(OLD.user_id); END IF;
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.user_id IS DISTINCT FROM OLD.user_id) THEN
    PERFORM invalidate_peer_policy(NEW.user_id);
  END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION peer_billing_account_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  PERFORM invalidate_peer_policy_for_account(CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END);
  IF TG_OP = 'UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN
    PERFORM invalidate_peer_policy(OLD.user_id);
  END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION peer_user_account_changed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  PERFORM invalidate_peer_policy(CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END);
  RETURN NULL;
END $$;

DROP TRIGGER peer_subscription_policy ON subscriptions;
DROP TRIGGER peer_membership_policy ON account_members;
DROP TRIGGER peer_billing_account_policy ON product_accounts;
DROP TRIGGER peer_user_policy ON "user";
DROP FUNCTION peer_billing_changed();

CREATE TRIGGER peer_subscription_policy AFTER INSERT OR UPDATE OR DELETE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION peer_subscription_changed();
CREATE TRIGGER peer_membership_policy AFTER INSERT OR UPDATE OR DELETE ON account_members
  FOR EACH ROW EXECUTE FUNCTION peer_membership_changed();
CREATE TRIGGER peer_billing_account_policy AFTER DELETE ON product_accounts
  FOR EACH ROW EXECUTE FUNCTION peer_billing_account_changed();
CREATE TRIGGER peer_billing_account_update AFTER UPDATE OF user_id, deleted_at ON product_accounts
  FOR EACH ROW WHEN ((OLD.user_id, OLD.deleted_at) IS DISTINCT FROM (NEW.user_id, NEW.deleted_at))
  EXECUTE FUNCTION peer_billing_account_changed();
CREATE TRIGGER peer_user_policy AFTER DELETE ON "user"
  FOR EACH ROW EXECUTE FUNCTION peer_user_account_changed();
CREATE TRIGGER peer_user_account_update AFTER UPDATE OF account_id ON "user"
  FOR EACH ROW WHEN (OLD.account_id IS DISTINCT FROM NEW.account_id)
  EXECUTE FUNCTION peer_user_account_changed();
