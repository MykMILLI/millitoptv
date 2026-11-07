CREATE TABLE millitop_tv.listening_session_schema (version integer PRIMARY KEY, checksum text NOT NULL, installed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE millitop_tv.listening_sessions (
 id uuid PRIMARY KEY, host_household_id uuid NOT NULL REFERENCES millitop_tv.households(id), host_device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),
 host_profile_id uuid, title text NOT NULL CHECK(length(title) BETWEEN 1 AND 120), join_code text NOT NULL UNIQUE CHECK(join_code ~ '^[A-Z0-9]{6,10}$'),
 status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','ended')), now_playing jsonb NOT NULL DEFAULT '{}'::jsonb,
 now_playing_token text NOT NULL DEFAULT '', revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), ended_at timestamptz
);
CREATE TABLE millitop_tv.listening_session_members (
 session_id uuid NOT NULL REFERENCES millitop_tv.listening_sessions(id) ON DELETE CASCADE, device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),
 profile_id uuid, display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 60), role text NOT NULL CHECK(role IN ('host','guest')),
 joined_at timestamptz NOT NULL DEFAULT now(), left_at timestamptz, last_seen_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(session_id,device_id)
);
CREATE INDEX listening_session_members_active ON millitop_tv.listening_session_members(session_id) WHERE left_at IS NULL;
CREATE TABLE millitop_tv.listening_session_messages (
 id uuid PRIMARY KEY, session_id uuid NOT NULL REFERENCES millitop_tv.listening_sessions(id) ON DELETE CASCADE, device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),
 display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 60), body text NOT NULL CHECK(length(body) BETWEEN 1 AND 2000),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX listening_session_messages_thread ON millitop_tv.listening_session_messages(session_id,created_at,id);
CREATE TABLE millitop_tv.listening_session_song_requests (
 id uuid PRIMARY KEY, session_id uuid NOT NULL REFERENCES millitop_tv.listening_sessions(id) ON DELETE CASCADE, device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),
 display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 60), track_ref jsonb NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','queued','rejected','played')),
 created_at timestamptz NOT NULL DEFAULT now(), resolved_at timestamptz
);
CREATE INDEX listening_session_requests_thread ON millitop_tv.listening_session_song_requests(session_id,created_at,id);
CREATE TABLE millitop_tv.listening_session_skip_votes (
 session_id uuid NOT NULL REFERENCES millitop_tv.listening_sessions(id) ON DELETE CASCADE, now_playing_token text NOT NULL,
 device_id uuid NOT NULL REFERENCES millitop_tv.devices(id), created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(session_id,now_playing_token,device_id)
);
CREATE TABLE millitop_tv.listening_session_signals (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, session_id uuid NOT NULL REFERENCES millitop_tv.listening_sessions(id) ON DELETE CASCADE,
 from_device_id uuid NOT NULL REFERENCES millitop_tv.devices(id), to_device_id uuid REFERENCES millitop_tv.devices(id),
 kind text NOT NULL CHECK(kind IN ('join-announce','offer','answer','ice-candidate','leave')), payload jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX listening_session_signals_poll ON millitop_tv.listening_session_signals(session_id,id);
CREATE TABLE millitop_tv.listening_session_invites (
 id uuid PRIMARY KEY, session_id uuid NOT NULL REFERENCES millitop_tv.listening_sessions(id) ON DELETE CASCADE, invited_by_device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),
 email text NOT NULL CHECK(length(email) BETWEEN 3 AND 320), token text NOT NULL UNIQUE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sent','failed','accepted')),
 created_at timestamptz NOT NULL DEFAULT now(), sent_at timestamptz
);
CREATE INDEX listening_session_invites_session ON millitop_tv.listening_session_invites(session_id,created_at);
CREATE TABLE millitop_tv.listening_session_events (
 id uuid PRIMARY KEY, session_id uuid NOT NULL, device_id uuid, action text NOT NULL, details jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE millitop_tv.listening_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.listening_session_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.listening_session_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.listening_session_song_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.listening_session_skip_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.listening_session_signals ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.listening_session_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.listening_session_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON millitop_tv.listening_session_schema,millitop_tv.listening_sessions,millitop_tv.listening_session_members,millitop_tv.listening_session_messages,millitop_tv.listening_session_song_requests,millitop_tv.listening_session_skip_votes,millitop_tv.listening_session_signals,millitop_tv.listening_session_invites,millitop_tv.listening_session_events FROM PUBLIC;
DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON millitop_tv.listening_session_schema,millitop_tv.listening_sessions,millitop_tv.listening_session_members,millitop_tv.listening_session_messages,millitop_tv.listening_session_song_requests,millitop_tv.listening_session_skip_votes,millitop_tv.listening_session_signals,millitop_tv.listening_session_invites,millitop_tv.listening_session_events FROM %I',r); END IF; END LOOP; END $$;
