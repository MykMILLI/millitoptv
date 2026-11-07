-- Millitop TV cloud DVR schema. Apply once as the schema owner, e.g.:
--   psql -v ON_ERROR_STOP=1 -f server/dvr-schema.sql
-- then verify from the API container with: node server/verify-dvr-schema.mjs
BEGIN;
CREATE TABLE IF NOT EXISTS millitop_tv.dvr_recordings (
  id uuid PRIMARY KEY,
  household_id uuid NOT NULL REFERENCES millitop_tv.households(id),
  profile_id integer NOT NULL CHECK (profile_id BETWEEN 1 AND 1000000),
  started_by_device uuid REFERENCES millitop_tv.devices(id),
  schedule_id uuid,
  source_id text NOT NULL CHECK (length(source_id) BETWEEN 1 AND 200),
  channel_id text NOT NULL CHECK (length(channel_id) BETWEEN 1 AND 400),
  channel_name text NOT NULL CHECK (length(channel_name) BETWEEN 1 AND 200),
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
  status text NOT NULL CHECK (status IN ('recording','completed','failed')),
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  size_bytes bigint NOT NULL DEFAULT 0 CHECK (size_bytes >= 0),
  note text CHECK (note IS NULL OR length(note) <= 400),
  deleted_at timestamptz
);
CREATE INDEX IF NOT EXISTS dvr_recordings_household_idx
  ON millitop_tv.dvr_recordings (household_id, started_at DESC) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS dvr_recordings_one_active_channel
  ON millitop_tv.dvr_recordings (household_id, channel_id) WHERE status = 'recording';

CREATE TABLE IF NOT EXISTS millitop_tv.dvr_schedules (
  id uuid PRIMARY KEY,
  household_id uuid NOT NULL REFERENCES millitop_tv.households(id),
  profile_id integer NOT NULL CHECK (profile_id BETWEEN 1 AND 1000000),
  created_by_device uuid REFERENCES millitop_tv.devices(id),
  source_id text NOT NULL CHECK (length(source_id) BETWEEN 1 AND 200),
  channel_id text NOT NULL CHECK (length(channel_id) BETWEEN 1 AND 400),
  channel_name text NOT NULL CHECK (length(channel_name) BETWEEN 1 AND 200),
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
  -- May contain IPTV provider credentials; table is backend-only (RLS + revoke).
  stream_url text NOT NULL CHECK (length(stream_url) BETWEEN 1 AND 4096),
  start_utc timestamptz NOT NULL,
  end_utc timestamptz NOT NULL CHECK (end_utc > start_utc),
  status text NOT NULL CHECK (status IN ('scheduled','recording','completed','failed','missed','cancelled')),
  recording_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS dvr_schedules_unique_pending
  ON millitop_tv.dvr_schedules (household_id, channel_id, start_utc) WHERE status = 'scheduled';
CREATE INDEX IF NOT EXISTS dvr_schedules_due_idx
  ON millitop_tv.dvr_schedules (start_utc) WHERE status = 'scheduled';

ALTER TABLE millitop_tv.dvr_recordings ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.dvr_schedules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON millitop_tv.dvr_recordings, millitop_tv.dvr_schedules FROM PUBLIC;
DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON millitop_tv.dvr_recordings, millitop_tv.dvr_schedules FROM %I', r); END IF; END LOOP; END $$;
GRANT SELECT, INSERT, UPDATE ON millitop_tv.dvr_recordings TO "millitop_tv_api";
GRANT SELECT, INSERT, UPDATE ON millitop_tv.dvr_schedules TO "millitop_tv_api";
DROP POLICY IF EXISTS backend_access ON millitop_tv.dvr_recordings;
DROP POLICY IF EXISTS backend_access ON millitop_tv.dvr_schedules;
CREATE POLICY backend_access ON millitop_tv.dvr_recordings FOR ALL TO "millitop_tv_api" USING (true) WITH CHECK (true);
CREATE POLICY backend_access ON millitop_tv.dvr_schedules FOR ALL TO "millitop_tv_api" USING (true) WITH CHECK (true);
COMMIT;
