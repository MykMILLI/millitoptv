CREATE TABLE IF NOT EXISTS millitop_tv.billing_schema (
 version integer PRIMARY KEY, checksum text NOT NULL, installed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS millitop_tv.billing_accounts (
 id uuid PRIMARY KEY,
 household_id uuid NOT NULL REFERENCES millitop_tv.households(id),
 merchant_id text NOT NULL,environment text NOT NULL CHECK(environment IN ('sandbox','production')),
 customer_id text NOT NULL,customer_name text NOT NULL,
 active boolean NOT NULL DEFAULT true,access_mode text NOT NULL CHECK(access_mode IN ('household','pin')),
 pin_salt text,pin_hash text,revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
 created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK((access_mode='household' AND pin_salt IS NULL AND pin_hash IS NULL) OR
       (access_mode='pin' AND pin_salt IS NOT NULL AND pin_hash IS NOT NULL AND pin_salt~'^[a-f0-9]{32}$' AND pin_hash~'^[a-f0-9]{64}$'))
);
CREATE UNIQUE INDEX IF NOT EXISTS billing_one_active_household ON millitop_tv.billing_accounts(household_id) WHERE active;
CREATE UNIQUE INDEX IF NOT EXISTS billing_one_active_customer ON millitop_tv.billing_accounts(merchant_id,environment,customer_id) WHERE active;
CREATE TABLE IF NOT EXISTS millitop_tv.billing_projects (
 id uuid PRIMARY KEY,account_id uuid NOT NULL REFERENCES millitop_tv.billing_accounts(id),
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 120),description text NOT NULL DEFAULT '',internal_note text NOT NULL DEFAULT '',
 status text NOT NULL CHECK(status IN ('planned','in_progress','waiting_customer','on_hold','completed','cancelled')),
 revision integer NOT NULL DEFAULT 1 CHECK(revision>0),created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS billing_projects_account_idx ON millitop_tv.billing_projects(account_id,updated_at DESC);
CREATE TABLE IF NOT EXISTS millitop_tv.billing_project_updates (
 id uuid PRIMARY KEY,project_id uuid NOT NULL REFERENCES millitop_tv.billing_projects(id),body text NOT NULL,
 customer_visible boolean NOT NULL DEFAULT true,created_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS millitop_tv.billing_sessions (
 token_hash text PRIMARY KEY CHECK(token_hash~'^[a-f0-9]{64}$'),account_id uuid NOT NULL REFERENCES millitop_tv.billing_accounts(id),
 device_id uuid NOT NULL REFERENCES millitop_tv.devices(id),expires_at timestamptz NOT NULL,revoked_at timestamptz,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS billing_sessions_expiry_idx ON millitop_tv.billing_sessions(expires_at);
CREATE TABLE IF NOT EXISTS millitop_tv.billing_events (
 id uuid PRIMARY KEY,actor_user_id uuid NOT NULL,account_id uuid NOT NULL,action text NOT NULL,
 details jsonb NOT NULL DEFAULT '{}'::jsonb,created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE millitop_tv.billing_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.billing_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.billing_project_updates ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.billing_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE millitop_tv.billing_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON millitop_tv.billing_schema,millitop_tv.billing_accounts,millitop_tv.billing_projects,millitop_tv.billing_project_updates,millitop_tv.billing_sessions,millitop_tv.billing_events FROM PUBLIC;
DO $$ DECLARE role_name text; BEGIN
 FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
   EXECUTE format('REVOKE ALL ON millitop_tv.billing_schema,millitop_tv.billing_accounts,millitop_tv.billing_projects,millitop_tv.billing_project_updates,millitop_tv.billing_sessions,millitop_tv.billing_events FROM %I',role_name);
  END IF;
 END LOOP;
END $$;
