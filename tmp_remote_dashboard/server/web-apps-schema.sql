CREATE TABLE IF NOT EXISTS millitop_tv.launcher_web_app_schema (
 version integer PRIMARY KEY, checksum text NOT NULL, installed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS millitop_tv.launcher_web_apps (
 id uuid PRIMARY KEY,
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 80),
 url text NOT NULL CHECK(length(url) BETWEEN 1 AND 2048),
 icon text NOT NULL CHECK(icon IN ('web','emby','jellyfin')),
 enabled boolean NOT NULL DEFAULT false,
 revision integer NOT NULL DEFAULT 1 CHECK(revision > 0),
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS millitop_tv.launcher_web_app_assignments (
 app_id uuid NOT NULL REFERENCES millitop_tv.launcher_web_apps(id) ON DELETE CASCADE,
 device_id uuid NOT NULL REFERENCES millitop_tv.devices(id) ON DELETE CASCADE,
 enabled boolean NOT NULL DEFAULT true,
 assigned_by uuid NOT NULL,
 assigned_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(app_id,device_id)
);
CREATE INDEX IF NOT EXISTS launcher_web_app_device_idx ON millitop_tv.launcher_web_app_assignments(device_id,enabled);
CREATE TABLE IF NOT EXISTS millitop_tv.launcher_web_app_events (
 id uuid PRIMARY KEY,actor_user_id uuid NOT NULL,app_id uuid NOT NULL,
 action text NOT NULL,details jsonb NOT NULL DEFAULT '{}'::jsonb,created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE millitop_tv.launcher_web_apps ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.launcher_web_app_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.launcher_web_app_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON millitop_tv.launcher_web_app_schema,millitop_tv.launcher_web_apps,millitop_tv.launcher_web_app_assignments,millitop_tv.launcher_web_app_events FROM PUBLIC;
DO $$ DECLARE role_name text; BEGIN
 FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
   EXECUTE format('REVOKE ALL ON millitop_tv.launcher_web_app_schema,millitop_tv.launcher_web_apps,millitop_tv.launcher_web_app_assignments,millitop_tv.launcher_web_app_events FROM %I',role_name);
  END IF;
 END LOOP;
END $$;
