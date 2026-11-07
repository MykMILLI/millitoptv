CREATE TABLE millitop_tv.profile_sync_schema (version integer PRIMARY KEY,checksum text NOT NULL,installed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE millitop_tv.profile_sync_heads (household_id uuid PRIMARY KEY REFERENCES millitop_tv.households(id),revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0));
CREATE TABLE millitop_tv.profile_sync_entities (
 household_id uuid NOT NULL REFERENCES millitop_tv.households(id),profile_id uuid NOT NULL,kind text NOT NULL CHECK(kind IN ('profile','shortcut','favorite','preference')),entity_key text NOT NULL CHECK(length(entity_key) BETWEEN 1 AND 240),
 revision bigint NOT NULL CHECK(revision>0),deleted boolean NOT NULL DEFAULT false,payload jsonb,updated_by_device uuid NOT NULL REFERENCES millitop_tv.devices(id),updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(household_id,profile_id,kind,entity_key),CHECK((deleted AND payload IS NULL) OR (NOT deleted AND payload IS NOT NULL)),CHECK(kind<>'profile' OR entity_key='profile')
);
CREATE TABLE millitop_tv.profile_sync_events (
 household_id uuid NOT NULL REFERENCES millitop_tv.households(id),revision bigint NOT NULL,profile_id uuid NOT NULL,kind text NOT NULL,entity_key text NOT NULL,deleted boolean NOT NULL,payload jsonb,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(household_id,revision)
);
CREATE TABLE millitop_tv.profile_sync_operations (
 household_id uuid NOT NULL REFERENCES millitop_tv.households(id),device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),operation_id uuid NOT NULL,payload_hash text NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(device_id,operation_id)
);
CREATE TABLE millitop_tv.profile_sync_avatars (
 household_id uuid NOT NULL REFERENCES millitop_tv.households(id),profile_id uuid NOT NULL,digest text NOT NULL,png bytea NOT NULL CHECK(octet_length(png)<=524288),updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(household_id,profile_id)
);
ALTER TABLE millitop_tv.profile_sync_heads ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.profile_sync_entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.profile_sync_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.profile_sync_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.profile_sync_avatars ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON millitop_tv.profile_sync_schema,millitop_tv.profile_sync_heads,millitop_tv.profile_sync_entities,millitop_tv.profile_sync_events,millitop_tv.profile_sync_operations,millitop_tv.profile_sync_avatars FROM PUBLIC;
DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON millitop_tv.profile_sync_schema,millitop_tv.profile_sync_heads,millitop_tv.profile_sync_entities,millitop_tv.profile_sync_events,millitop_tv.profile_sync_operations,millitop_tv.profile_sync_avatars FROM %I',r);END IF;END LOOP;END $$;
