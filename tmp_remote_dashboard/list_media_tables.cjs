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
pool.query("select table_schema, table_name from information_schema.tables where table_name like 'media_library%' order by 1,2")
  .then(r => console.log(JSON.stringify(r.rows, null, 2)))
  .catch(e => { console.error('ERR', e.message); process.exitCode = 1; })
  .finally(() => pool.end());
