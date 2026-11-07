CREATE TABLE millitop_tv.community_schema (version integer PRIMARY KEY, checksum text NOT NULL, installed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE millitop_tv.support_requests (
 id uuid PRIMARY KEY, household_id uuid NOT NULL REFERENCES millitop_tv.households(id), device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),
 kind text NOT NULL CHECK(kind IN ('media','problem','message')), title text NOT NULL CHECK(length(title) BETWEEN 1 AND 160), body text NOT NULL CHECK(length(body) BETWEEN 1 AND 6000),
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','in_progress','waiting_customer','closed')), revision integer NOT NULL DEFAULT 1,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX support_requests_household_page ON millitop_tv.support_requests(household_id,created_at DESC,id DESC);
CREATE TABLE millitop_tv.support_replies (
 id uuid PRIMARY KEY, request_id uuid NOT NULL REFERENCES millitop_tv.support_requests(id), body text NOT NULL CHECK(length(body) BETWEEN 1 AND 6000),
 author_kind text NOT NULL CHECK(author_kind IN ('admin','household')), actor_user_id uuid, actor_device_id uuid, public boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX support_replies_thread ON millitop_tv.support_replies(request_id,created_at,id);
CREATE TABLE millitop_tv.help_articles (
 id uuid PRIMARY KEY,title text NOT NULL CHECK(length(title) BETWEEN 1 AND 160),category text NOT NULL CHECK(length(category) BETWEEN 1 AND 80),markdown text NOT NULL CHECK(length(markdown) BETWEEN 1 AND 64000),
 published boolean NOT NULL DEFAULT false,household_ids uuid[] NOT NULL DEFAULT '{}',revision integer NOT NULL DEFAULT 1,created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE millitop_tv.discovery_cards (
 id uuid PRIMARY KEY,title text NOT NULL CHECK(length(title) BETWEEN 1 AND 160),description text NOT NULL DEFAULT '',section text NOT NULL CHECK(section IN ('movies','shows')),
 trailer_url text NOT NULL,thumbnail_url text NOT NULL,position integer NOT NULL DEFAULT 0,published boolean NOT NULL DEFAULT false,household_ids uuid[] NOT NULL DEFAULT '{}',revision integer NOT NULL DEFAULT 1,created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE millitop_tv.community_events (
 id uuid PRIMARY KEY,actor_user_id uuid,actor_device_id uuid,entity_id uuid NOT NULL,action text NOT NULL,details jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE millitop_tv.support_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.support_replies ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.help_articles ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.discovery_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.community_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON millitop_tv.community_schema,millitop_tv.support_requests,millitop_tv.support_replies,millitop_tv.help_articles,millitop_tv.discovery_cards,millitop_tv.community_events FROM PUBLIC;
DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON millitop_tv.community_schema,millitop_tv.support_requests,millitop_tv.support_replies,millitop_tv.help_articles,millitop_tv.discovery_cards,millitop_tv.community_events FROM %I',r); END IF; END LOOP; END $$;
