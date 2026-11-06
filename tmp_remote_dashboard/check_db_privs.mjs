import fs from "node:fs";
import pg from "pg";
const { Pool } = pg;
const envText = fs.readFileSync("/home/mykal/millitop-tv-dashboard/.env", "utf8");
const env = {};
for (const line of envText.split(/\r?\n/)) {
  const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
  if (m) env[m[1]] = m[2];
}
const password = fs.readFileSync("/home/mykal/millitop-tv-dashboard/secrets/db_password", "utf8").trim();
const pool = new Pool({
  host: env.DB_HOST,
  port: Number(env.DB_PORT || 5432),
  database: env.DB_NAME,
  user: env.DB_USER,
  password,
  ssl: { rejectUnauthorized: false }
});
try {
  const a = await pool.query(`
    select current_user,
           has_schema_privilege(current_user, 'millitop_tv', 'USAGE') as schema_usage,
           has_schema_privilege(current_user, 'millitop_tv', 'CREATE') as schema_create
  `);
  console.log('schema', a.rows[0]);
  const b = await pool.query(`
    select table_name, privilege_type
    from information_schema.role_table_grants
    where grantee = current_user
      and table_schema = 'millitop_tv'
      and table_name in ('media_libraries','media_library_acl','media_library_index','media_library_progress')
    order by table_name, privilege_type
  `);
  console.log('table grants', b.rows);
  const c = await pool.query("select 1 from millitop_tv.media_libraries limit 1");
  console.log('select media_libraries ok', c.rowCount);
} catch (e) {
  console.error('db check error', e.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
