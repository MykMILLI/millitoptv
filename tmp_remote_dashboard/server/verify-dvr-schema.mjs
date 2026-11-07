// Read-only check that the DVR tables, grants, and RLS policy exist for the API role.
import { Pool } from 'pg'; import { readFileSync } from 'node:fs';
const pool = new Pool({ host: process.env.DB_HOST, port: Number(process.env.DB_PORT), database: process.env.DB_NAME, user: process.env.DB_USER, password: readFileSync('/run/secrets/db_password', 'utf8').trim(), ssl: false, max: 1, connectionTimeoutMillis: 10000 });
let c;
try {
  c = await pool.connect(); await c.query('BEGIN READ ONLY'); await c.query("SET LOCAL statement_timeout='15s'");
  for (const t of ['dvr_recordings', 'dvr_schedules']) {
    const name = 'millitop_tv.' + t;
    if (!(await c.query('SELECT relrowsecurity AS enabled FROM pg_class WHERE oid=to_regclass($1)', [name])).rows[0]?.enabled) throw Error('DVR table or RLS missing: ' + name + '. Apply server/dvr-schema.sql as the schema owner.');
    for (const p of ['SELECT', 'INSERT', 'UPDATE']) if (!(await c.query('SELECT has_table_privilege(current_user,$1,$2) AS ok', [name, p])).rows[0].ok) throw Error('Runtime grant missing: ' + p + ' on ' + name);
  }
  await c.query('COMMIT'); console.log('DVR_SCHEMA_RUNTIME_READY');
} finally { if (c) { await c.query('ROLLBACK').catch(() => {}); c.release(); } await pool.end(); }
