const { Pool } = require('pg');
const fs = require('fs');
const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: fs.readFileSync('/run/secrets/db_password', 'utf8').trim(),
  ssl: false,
});
pool.query("select current_user, has_schema_privilege(current_user,'public','USAGE') as public_usage, has_schema_privilege(current_user,'public','CREATE') as public_create, has_schema_privilege(current_user,'millitop_tv','USAGE') as mt_usage, has_schema_privilege(current_user,'millitop_tv','CREATE') as mt_create")
  .then(r => console.log(JSON.stringify(r.rows, null, 2)))
  .catch(e => { console.error('ERR', e.message); process.exitCode = 1; })
  .finally(() => pool.end());
