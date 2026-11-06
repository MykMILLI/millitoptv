import pg from "pg";
import fs from "node:fs";
const { Pool } = pg;
const envText = fs.readFileSync("/app/.env", "utf8");
const env = {};
for (const line of envText.split(/\r?\n/)) {
  const i = line.indexOf('=');
  if (i > 0) env[line.slice(0, i)] = line.slice(i + 1);
}
const password = fs.readFileSync('/run/secrets/db_password','utf8').trim();
const pool = new Pool({
  host: env.DB_HOST,
  port: Number(env.DB_PORT || 5432),
  database: env.DB_NAME,
  user: env.DB_USER,
  password,
  ssl: false,
});
try {
  const r = await pool.query(`
    select table_schema, table_name
    from information_schema.tables
    where table_name like 'media_library%'
    order by table_schema, table_name
  `);
  console.log(JSON.stringify(r.rows, null, 2));
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
