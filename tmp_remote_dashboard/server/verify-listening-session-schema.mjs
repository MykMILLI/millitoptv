import { Pool } from 'pg';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const schema = readFileSync(new URL('./listening-session-schema.sql', import.meta.url), 'utf8');
const checksum = createHash('sha256').update(schema).digest('hex');
const required = name => { if (!process.env[name]) throw new Error('Missing configuration ' + name); return process.env[name]; };
const pool = new Pool({
 host: required('DB_HOST'), port: Number(required('DB_PORT')), database: required('DB_NAME'), user: required('DB_USER'),
 password: readFileSync('/run/secrets/db_password', 'utf8').trim(), ssl: false, max: 1, connectionTimeoutMillis: 10000
});
let c;
try {
 c = await pool.connect();
 await c.query('BEGIN READ ONLY');
 await c.query("SET LOCAL statement_timeout='20s'");
 const role = (await c.query('SELECT current_user AS role')).rows[0].role;
 console.log('LISTENING_SESSION_SCHEMA_RUNTIME_ROLE: ' + role);
 const marker = (await c.query("SELECT to_regclass('millitop_tv.listening_session_schema') AS name")).rows[0].name;
 if (!marker) throw new Error('Database-owner migration has not been applied. Keep runtime CREATE privileges restricted.');
 const version = await c.query('SELECT checksum FROM millitop_tv.listening_session_schema WHERE version=1');
 if (version.rowCount !== 1 || version.rows[0].checksum !== checksum) throw new Error('Listening-session schema checksum missing or incompatible. Ask the database owner; no DDL was attempted.');
 const access = {
  listening_sessions: ['SELECT', 'INSERT', 'UPDATE'],
  listening_session_members: ['SELECT', 'INSERT', 'UPDATE'],
  listening_session_messages: ['SELECT', 'INSERT'],
  listening_session_song_requests: ['SELECT', 'INSERT', 'UPDATE'],
  listening_session_skip_votes: ['SELECT', 'INSERT'],
  listening_session_signals: ['SELECT', 'INSERT'],
  listening_session_invites: ['SELECT', 'INSERT', 'UPDATE'],
  listening_session_events: ['SELECT', 'INSERT']
 };
 const commands = { SELECT: 'r', INSERT: 'a', UPDATE: 'w' };
 for (const [table, privileges] of Object.entries(access)) {
  const name = 'millitop_tv.' + table;
  const state = (await c.query('SELECT relrowsecurity AS enabled FROM pg_class WHERE oid=to_regclass($1)', [name])).rows[0];
  if (!state?.enabled) throw new Error('RLS must be enabled on ' + name);
  for (const privilege of privileges) {
   const allowed = (await c.query('SELECT has_table_privilege(current_user,$1,$2) AS ok', [name, privilege])).rows[0].ok;
   if (!allowed) throw new Error('Missing scoped ' + privilege + ' on ' + name);
   const policy = (await c.query(
    `SELECT EXISTS(SELECT 1 FROM pg_policy WHERE polrelid=to_regclass($1) AND polpermissive AND polcmd IN ('*',$2)
      AND (current_user::regrole)::oid=ANY(polroles) AND COALESCE(pg_get_expr(polqual,polrelid),'true')='true'
      AND COALESCE(pg_get_expr(polwithcheck,polrelid),'true')='true') AS ok`,
    [name, commands[privilege]]
   )).rows[0].ok;
   if (!policy) throw new Error('Missing explicit backend-role RLS policy for ' + privilege + ' on ' + name);
  }
 }
 await c.query('SELECT id,host_household_id,host_device_id,title,join_code,status,now_playing,revision FROM millitop_tv.listening_sessions LIMIT 0');
 await c.query('SELECT session_id,device_id,profile_id,display_name,role FROM millitop_tv.listening_session_members LIMIT 0');
 await c.query('SELECT id,session_id,device_id,body FROM millitop_tv.listening_session_messages LIMIT 0');
 await c.query('SELECT id,session_id,device_id,track_ref,status FROM millitop_tv.listening_session_song_requests LIMIT 0');
 await c.query('SELECT session_id,now_playing_token,device_id FROM millitop_tv.listening_session_skip_votes LIMIT 0');
 await c.query('SELECT id,session_id,from_device_id,to_device_id,kind,payload FROM millitop_tv.listening_session_signals LIMIT 0');
 await c.query('SELECT id,session_id,invited_by_device_id,email,token,status FROM millitop_tv.listening_session_invites LIMIT 0');
 await c.query('SELECT id,session_id,device_id,action,details FROM millitop_tv.listening_session_events LIMIT 0');
 await c.query('COMMIT');
 console.log('LISTENING_SESSION_SCHEMA_ALREADY_READY');
 console.log('RUNTIME_DML_AND_RLS_VERIFIED_NO_CREATE_GRANT');
} catch (e) {
 if (c) await c.query('ROLLBACK').catch(() => {});
 console.error('LISTENING_SESSION_SCHEMA_STOPPED: ' + e.message);
 process.exitCode = 1;
} finally {
 c?.release();
 await pool.end();
}
