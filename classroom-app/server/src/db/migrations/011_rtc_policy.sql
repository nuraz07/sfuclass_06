-- server/src/db/migrations/011_rtc_policy.sql
--
-- Tenant ICE policy and allowed media regions (F8 Real-Time Connectivity).
-- Read by server/src/rtc/IcePolicy.js (cached 60 s per task); used for TURN credential issuance and,
-- through the same IcePolicy instance, for room placement (data residency).
--
--   ice_transport_policy   'all'   clients may connect directly or through TURN (default)
--                          'relay' clients connect only through TURN: neither the SFU nor other participants
--                                  ever see a learner's IP address
--   credential_ttl_s       TURN credential lifetime; NULL = platform default (ICE_CREDENTIAL_TTL_S).
--                          IcePolicy additionally clamps to [ICE_CREDENTIAL_MIN_TTL_S, ICE_CREDENTIAL_MAX_TTL_S].
--   turn_transports        subset of {udp, tcp, tls}; NULL = platform default (ICE_ENABLED_TRANSPORTS)
--   allowed_media_regions  AWS region codes media may be placed in or relayed through; NULL = unrestricted
--
-- A tenant without a row uses the platform defaults. Absence of a row is therefore the normal case, and
-- the table only holds tenants that deviate.
--
-- Migration rules (architecture doc, section 10.1): additive only, safe to run while the previous release
-- serves traffic, applied by the one-off migration task under the advisory lock in db/migrate.js, which
-- runs each file inside one transaction. Down path at the end of this file (manual, documented only).

-- ------------------------------------------------------------------ validation helper
-- CHECK constraints cannot contain subqueries; an IMMUTABLE function can.
CREATE OR REPLACE FUNCTION rtc_valid_region_list(regions text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT cardinality(regions) BETWEEN 1 AND 32
     AND array_position(regions, NULL) IS NULL
     AND NOT EXISTS (
           SELECT 1 FROM unnest(regions) AS r
            WHERE r !~ '^[a-z]{2}(-[a-z]+)+-[0-9]{1,2}$')
     AND cardinality(regions) = (SELECT count(DISTINCT r) FROM unnest(regions) AS r);
$$;

COMMENT ON FUNCTION rtc_valid_region_list(text[]) IS
  'True when every element is an AWS region code, without NULLs or duplicates, 1–32 entries.';

-- ------------------------------------------------------------------ table
CREATE TABLE IF NOT EXISTS tenant_rtc_policy (
  tenant_id              uuid        PRIMARY KEY,
  ice_transport_policy   text        NOT NULL DEFAULT 'all',
  credential_ttl_s       integer,
  turn_transports        text[],
  allowed_media_regions  text[],
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  updated_by             uuid,

  CONSTRAINT tenant_rtc_policy_policy_chk
    CHECK (ice_transport_policy IN ('all', 'relay')),
  CONSTRAINT tenant_rtc_policy_ttl_chk
    CHECK (credential_ttl_s IS NULL OR credential_ttl_s BETWEEN 300 AND 86400),
  CONSTRAINT tenant_rtc_policy_transports_chk
    CHECK (turn_transports IS NULL
           OR (cardinality(turn_transports) BETWEEN 1 AND 3
               AND turn_transports <@ ARRAY['udp', 'tcp', 'tls']::text[])),
  -- relay-only needs a transport that works through restrictive firewalls
  CONSTRAINT tenant_rtc_policy_relay_tls_chk
    CHECK (ice_transport_policy <> 'relay' OR turn_transports IS NULL OR 'tls' = ANY (turn_transports)),
  CONSTRAINT tenant_rtc_policy_regions_chk
    CHECK (allowed_media_regions IS NULL OR rtc_valid_region_list(allowed_media_regions))
);

COMMENT ON TABLE tenant_rtc_policy IS
  'Per-tenant overrides for ICE/TURN and media residency. No row = platform defaults. Read by rtc/IcePolicy.js.';
COMMENT ON COLUMN tenant_rtc_policy.ice_transport_policy IS 'all | relay (relay hides participant IP addresses).';
COMMENT ON COLUMN tenant_rtc_policy.credential_ttl_s IS 'TURN credential lifetime in seconds; NULL = platform default.';
COMMENT ON COLUMN tenant_rtc_policy.turn_transports IS 'Subset of udp, tcp, tls; NULL = platform default.';
COMMENT ON COLUMN tenant_rtc_policy.allowed_media_regions IS 'Data residency: allowed AWS regions for SFU placement and TURN relay; NULL = any.';
COMMENT ON COLUMN tenant_rtc_policy.updated_by IS 'User who last changed the policy (audit trail lives in security/auditLog.js).';

-- Referential integrity to the tenant table when this deployment has one (the tenant model predates this
-- migration; the constraint is added only if the referenced table and key exist, so the file stays portable).
DO $$
BEGIN
  IF to_regclass('public.tenants') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tenant_rtc_policy_tenant_fk') THEN
    ALTER TABLE tenant_rtc_policy
      ADD CONSTRAINT tenant_rtc_policy_tenant_fk
      FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE CASCADE;
  END IF;
END
$$;

-- ------------------------------------------------------------------ change tracking
-- updated_at is maintained by the database, and every change is announced on channel
-- 'tenant_rtc_policy_changed' (payload: tenant id) so tasks can drop their IcePolicy cache entry immediately
-- instead of waiting for the 60 s TTL.
CREATE OR REPLACE FUNCTION tenant_rtc_policy_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := now();
  END IF;
  PERFORM pg_notify('tenant_rtc_policy_changed',
                    COALESCE(NEW.tenant_id, OLD.tenant_id)::text);
  RETURN COALESCE(NEW, OLD);
END
$$;

DROP TRIGGER IF EXISTS tenant_rtc_policy_touch_trg ON tenant_rtc_policy;
CREATE TRIGGER tenant_rtc_policy_touch_trg
  BEFORE INSERT OR UPDATE OR DELETE ON tenant_rtc_policy
  FOR EACH ROW EXECUTE FUNCTION tenant_rtc_policy_touch();

-- ------------------------------------------------------------------ down (manual; never run automatically)
-- DROP TRIGGER IF EXISTS tenant_rtc_policy_touch_trg ON tenant_rtc_policy;
-- DROP FUNCTION IF EXISTS tenant_rtc_policy_touch();
-- DROP TABLE IF EXISTS tenant_rtc_policy;
-- DROP FUNCTION IF EXISTS rtc_valid_region_list(text[]);