-- Watch party (shared playback) schema, version 1.
-- Apply as the database owner (not the runtime role):
--   psql -v ON_ERROR_STOP=1 -f server/watch-party-schema.sql
-- Idempotent: safe to re-run. The runtime role only receives DML grants.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS millitop_tv.watch_party_schema (
 version integer PRIMARY KEY,
 installed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS millitop_tv.watch_parties (
 id uuid PRIMARY KEY,
 host_household_id uuid NOT NULL REFERENCES millitop_tv.households(id),
 host_device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),
 title text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
 join_code text NOT NULL UNIQUE CHECK (join_code ~ '^[A-Z2-9]{8}$'),
 status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','ended')),
 locked boolean NOT NULL DEFAULT false,
 media jsonb NOT NULL DEFAULT '{}'::jsonb,
 media_rev integer NOT NULL DEFAULT 0 CHECK (media_rev >= 0),
 upstream_ct text,
 playback jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 host_seen_at timestamptz NOT NULL DEFAULT now(),
 ended_at timestamptz,
 end_reason text
);
CREATE INDEX IF NOT EXISTS watch_parties_active ON millitop_tv.watch_parties(status, host_seen_at) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS millitop_tv.watch_party_participants (
 id uuid PRIMARY KEY,
 party_id uuid NOT NULL REFERENCES millitop_tv.watch_parties(id) ON DELETE CASCADE,
 token_hash text NOT NULL UNIQUE,
 relay_key text NOT NULL UNIQUE,
 display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 60),
 role text NOT NULL CHECK (role IN ('host','guest')),
 client_kind text NOT NULL DEFAULT 'web' CHECK (client_kind IN ('app','web')),
 device_id uuid REFERENCES millitop_tv.devices(id),
 invite_id uuid,
 joined_at timestamptz NOT NULL DEFAULT now(),
 last_seen_at timestamptz NOT NULL DEFAULT now(),
 left_at timestamptz,
 removed_at timestamptz
);
CREATE INDEX IF NOT EXISTS watch_party_participants_party ON millitop_tv.watch_party_participants(party_id) WHERE left_at IS NULL AND removed_at IS NULL;

CREATE TABLE IF NOT EXISTS millitop_tv.watch_party_messages (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 party_id uuid NOT NULL REFERENCES millitop_tv.watch_parties(id) ON DELETE CASCADE,
 participant_id uuid NOT NULL REFERENCES millitop_tv.watch_party_participants(id) ON DELETE CASCADE,
 display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 60),
 body text NOT NULL CHECK (length(body) BETWEEN 1 AND 1000),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS watch_party_messages_thread ON millitop_tv.watch_party_messages(party_id, id);

CREATE TABLE IF NOT EXISTS millitop_tv.watch_party_invites (
 id uuid PRIMARY KEY,
 party_id uuid NOT NULL REFERENCES millitop_tv.watch_parties(id) ON DELETE CASCADE,
 invited_by uuid NOT NULL REFERENCES millitop_tv.watch_party_participants(id) ON DELETE CASCADE,
 email text NOT NULL CHECK (length(email) BETWEEN 3 AND 320),
 token_hash text NOT NULL UNIQUE,
 status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed','accepted')),
 error text,
 created_at timestamptz NOT NULL DEFAULT now(),
 sent_at timestamptz,
 accepted_at timestamptz
);
CREATE INDEX IF NOT EXISTS watch_party_invites_party ON millitop_tv.watch_party_invites(party_id, created_at);

CREATE TABLE IF NOT EXISTS millitop_tv.watch_party_settings (
 key text PRIMARY KEY CHECK (key IN ('smtp','voice','limits')),
 value jsonb NOT NULL DEFAULT '{}'::jsonb,
 secret_ct text,
 updated_at timestamptz NOT NULL DEFAULT now(),
 updated_by uuid
);

CREATE TABLE IF NOT EXISTS millitop_tv.watch_party_events (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 party_id uuid,
 participant_id uuid,
 action text NOT NULL,
 details jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS watch_party_events_party ON millitop_tv.watch_party_events(party_id, id);

ALTER TABLE millitop_tv.watch_party_schema ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.watch_parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.watch_party_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.watch_party_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.watch_party_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.watch_party_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.watch_party_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON millitop_tv.watch_party_schema, millitop_tv.watch_parties, millitop_tv.watch_party_participants,
 millitop_tv.watch_party_messages, millitop_tv.watch_party_invites, millitop_tv.watch_party_settings,
 millitop_tv.watch_party_events FROM PUBLIC;
DO $$ DECLARE r text; BEGIN
 FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
   EXECUTE format('REVOKE ALL ON millitop_tv.watch_party_schema, millitop_tv.watch_parties, millitop_tv.watch_party_participants, millitop_tv.watch_party_messages, millitop_tv.watch_party_invites, millitop_tv.watch_party_settings, millitop_tv.watch_party_events FROM %I', r);
  END IF;
 END LOOP;
END $$;

GRANT SELECT ON millitop_tv.watch_party_schema TO "millitop_tv_api";
GRANT SELECT, INSERT, UPDATE ON millitop_tv.watch_parties TO "millitop_tv_api";
GRANT SELECT, INSERT, UPDATE ON millitop_tv.watch_party_participants TO "millitop_tv_api";
GRANT SELECT, INSERT ON millitop_tv.watch_party_messages TO "millitop_tv_api";
GRANT SELECT, INSERT, UPDATE ON millitop_tv.watch_party_invites TO "millitop_tv_api";
GRANT SELECT, INSERT, UPDATE ON millitop_tv.watch_party_settings TO "millitop_tv_api";
GRANT SELECT, INSERT ON millitop_tv.watch_party_events TO "millitop_tv_api";

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['watch_party_schema','watch_parties','watch_party_participants','watch_party_messages','watch_party_invites','watch_party_settings','watch_party_events'] LOOP
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'millitop_tv' AND tablename = t AND policyname = t || '_backend') THEN
   EXECUTE format('CREATE POLICY %I ON millitop_tv.%I FOR ALL TO "millitop_tv_api" USING (true) WITH CHECK (true)', t || '_backend', t);
  END IF;
 END LOOP;
END $$;

INSERT INTO millitop_tv.watch_party_schema(version) VALUES (1) ON CONFLICT (version) DO NOTHING;
COMMIT;
