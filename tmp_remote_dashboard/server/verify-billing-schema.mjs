import { Pool } from 'pg';import { readFileSync } from 'node:fs';import { createHash } from 'node:crypto';
const checksum=createHash('sha256').update(readFileSync(new URL('./billing-schema.sql',import.meta.url))).digest('hex');
const required=n=>{if(!process.env[n])throw Error('Missing '+n);return process.env[n];};
const pool=new Pool({host:required('DB_HOST'),port:Number(required('DB_PORT')),database:required('DB_NAME'),user:required('DB_USER'),password:readFileSync('/run/secrets/db_password','utf8').trim(),ssl:false,max:1,connectionTimeoutMillis:10000});let c;
try{c=await pool.connect();await c.query('BEGIN READ ONLY');await c.query("SET LOCAL statement_timeout='20s'");
 const marker=(await c.query("SELECT to_regclass('millitop_tv.billing_schema') AS name")).rows[0].name;
 if(!marker)throw Error('Run the supplied owner SQL first. No runtime CREATE grant is required.');
 const version=await c.query('SELECT checksum FROM millitop_tv.billing_schema WHERE version=1');if(version.rowCount!==1||version.rows[0].checksum!==checksum)throw Error('Billing schema checksum missing/incompatible.');
 const access={billing_accounts:['SELECT','INSERT','UPDATE'],billing_projects:['SELECT','INSERT','UPDATE'],billing_project_updates:['SELECT','INSERT'],billing_sessions:['SELECT','INSERT','UPDATE','DELETE'],billing_events:['SELECT','INSERT']};const commands={SELECT:'r',INSERT:'a',UPDATE:'w',DELETE:'d'};
 for(const [table,privileges] of Object.entries(access)){
  const name='millitop_tv.'+table;if(!(await c.query('SELECT relrowsecurity AS enabled FROM pg_class WHERE oid=to_regclass($1)',[name])).rows[0]?.enabled)throw Error('RLS not enabled: '+name);
  for(const p of privileges){
   if(!(await c.query('SELECT has_table_privilege(current_user,$1,$2) AS ok',[name,p])).rows[0].ok)throw Error('Missing scoped '+p+' on '+name);
   const policy=(await c.query(`SELECT EXISTS(SELECT 1 FROM pg_policy WHERE polrelid=to_regclass($1) AND polpermissive AND polcmd IN ('*',$2) AND (current_user::regrole)::oid=ANY(polroles) AND COALESCE(pg_get_expr(polqual,polrelid),'true')='true' AND COALESCE(pg_get_expr(polwithcheck,polrelid),'true')='true') AS ok`,[name,commands[p]])).rows[0].ok;
   if(!policy)throw Error('Missing backend-role policy: '+name+' '+p);
  }
 }
 await c.query('SELECT id,household_id,merchant_id,environment,customer_id,access_mode,pin_hash,revision FROM millitop_tv.billing_accounts LIMIT 0');
 await c.query('SELECT id,account_id,title,description,internal_note,status,revision FROM millitop_tv.billing_projects LIMIT 0');
 await c.query('COMMIT');console.log('BILLING_RUNTIME_DML_AND_RLS_VERIFIED');
}catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});console.error('BILLING_SCHEMA_STOPPED: '+e.message);process.exitCode=1;}finally{c?.release();await pool.end();}
