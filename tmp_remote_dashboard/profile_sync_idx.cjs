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
(async()=>{
  const a=await pool.query("select indexname,indexdef from pg_indexes where schemaname='millitop_tv' and tablename='profile_sync_entities'");
  console.log(JSON.stringify(a.rows,null,2));
  await pool.end();
})().catch(e=>{console.error('ERR',e.message);process.exit(1);});
