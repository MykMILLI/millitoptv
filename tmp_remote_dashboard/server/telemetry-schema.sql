-- Millitop TV app diagnostics + usage analytics. Apply once as the schema owner:
--   psql -v ON_ERROR_STOP=1 -f server/telemetry-schema.sql
-- then verify from the API container with: node server/verify-telemetry-schema.mjs
-- Rows are redacted by the app before upload (no tokens/passwords/credential URLs)
-- and pruned after TELEMETRY_RETENTION_DAYS (default 90).
BEGIN;
CREATE TABLE IF NOT EXISTS millitop_tv.app_telemetry (
  id bigserial PRIMARY KEY,
  household_id uuid NOT NULL REFERENCES millitop_tv.households(id),
  device_id uuid REFERENCES millitop_tv.devices(id),
  session_id text NOT NULL CHECK (length(session_id) BETWEEN 1 AND 64),
  profile_id integer CHECK (profile_id IS NULL OR profile_id BETWEEN 1 AND 1000000),
  app_version text CHECK (app_version IS NULL OR length(app_version) <= 64),
  platform text CHECK (platform IS NULL OR length(platform) <= 32),
  occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  level text NOT NULL CHECK (level IN ('debug','info','warn','error')),
  category text NOT NULL CHECK (length(category) BETWEEN 1 AND 40),
  message text NOT NULL CHECK (length(message) BETWEEN 1 AND 500),
  error text CHECK (error IS NULL OR length(error) <= 2000),
  hint text CHECK (hint IS NULL OR length(hint) <= 600),
  details jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS app_telemetry_time_idx ON millitop_tv.app_telemetry (occurred_at DESC);
CREATE INDEX IF NOT EXISTS app_telemetry_level_idx ON millitop_tv.app_telemetry (level, occurred_at DESC) WHERE level IN ('warn','error');
CREATE INDEX IF NOT EXISTS app_telemetry_event_idx ON millitop_tv.app_telemetry (category, message, occurred_at DESC);

ALTER TABLE millitop_tv.app_telemetry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON millitop_tv.app_telemetry FROM PUBLIC;
DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON millitop_tv.app_telemetry FROM %I', r); END IF; END LOOP; END $$;
GRANT SELECT, INSERT, DELETE ON millitop_tv.app_telemetry TO "millitop_tv_api";
GRANT USAGE, SELECT ON SEQUENCE millitop_tv.app_telemetry_id_seq TO "millitop_tv_api";
DROP POLICY IF EXISTS backend_access ON millitop_tv.app_telemetry;
CREATE POLICY backend_access ON millitop_tv.app_telemetry FOR ALL TO "millitop_tv_api" USING (true) WITH CHECK (true);
COMMIT;
