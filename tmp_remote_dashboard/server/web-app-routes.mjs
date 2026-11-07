import { randomUUID,createHash } from 'node:crypto';
import { validateWebApp,validateAssignments,isUuid } from './web-app-validation.mjs';

export function registerWebAppRoutes(app,pool,deviceLimit) {
 if(typeof deviceLimit!=='function')throw new Error('A device rate limiter is required.');
 const admin=(req,res)=>{if(!req.admin?.id){res.status(401).json({error:'Dashboard authentication required.'});return false;}return true;};
 async function tx(res,next,work){let c;try{c=await pool.connect();await c.query('BEGIN');await c.query("SET LOCAL statement_timeout='15s'");const result=await work(c);await c.query('COMMIT');res.status(result.status??200).json(result.body);}catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});next(e);}finally{c?.release();}}
 const audit=(c,actor,id,action,details={})=>c.query('INSERT INTO millitop_tv.launcher_web_app_events(id,actor_user_id,app_id,action,details) VALUES($1,$2,$3,$4,$5)',[randomUUID(),actor,id,action,JSON.stringify(details)]);
 app.get('/api/admin/web-apps',async(req,res,next)=>{
  if(!admin(req,res))return;
  try{res.json((await pool.query(`SELECT a.*,COALESCE((SELECT json_agg(json_build_object('deviceId',x.device_id,'enabled',x.enabled)) FROM millitop_tv.launcher_web_app_assignments x WHERE x.app_id=a.id),'[]'::json) AS assignments FROM millitop_tv.launcher_web_apps a ORDER BY a.created_at DESC LIMIT 500`)).rows);}catch(e){next(e);}
 });
 app.post('/api/admin/web-apps',async(req,res,next)=>{
  if(!admin(req,res))return;let b;try{b=validateWebApp(req.body);}catch(e){return res.status(400).json({error:e.message});}
  return tx(res,next,async c=>{const id=randomUUID();const r=await c.query('INSERT INTO millitop_tv.launcher_web_apps(id,title,url,icon,enabled,created_by) VALUES($1,$2,$3,$4,$5,$6) RETURNING *',[id,b.title,b.url,b.icon,b.enabled,req.admin.id]);await audit(c,req.admin.id,id,'web_app.created');return {status:201,body:r.rows[0]};});
 });
 app.post('/api/admin/web-apps/:id',async(req,res,next)=>{
  if(!admin(req,res))return;if(!isUuid(req.params.id))return res.status(400).json({error:'Invalid app ID.'});
  let b;try{b=validateWebApp(req.body,{revision:true});}catch(e){return res.status(400).json({error:e.message});}
  return tx(res,next,async c=>{const r=await c.query(`UPDATE millitop_tv.launcher_web_apps SET title=$3,url=$4,icon=$5,enabled=$6,revision=revision+1,updated_at=now() WHERE id=$1 AND revision=$2 RETURNING *`,[req.params.id,b.revision,b.title,b.url,b.icon,b.enabled]);if(!r.rowCount)return {status:409,body:{error:'App changed or no longer exists. Refresh before editing.'}};await audit(c,req.admin.id,req.params.id,'web_app.updated',{revision:r.rows[0].revision,enabled:b.enabled});return {body:r.rows[0]};});
 });
 app.post('/api/admin/web-apps/:id/assign',async(req,res,next)=>{
  if(!admin(req,res))return;if(!isUuid(req.params.id))return res.status(400).json({error:'Invalid app ID.'});
  let b;try{b=validateAssignments(req.body);}catch(e){return res.status(400).json({error:e.message});}
  return tx(res,next,async c=>{
   const found=await c.query('SELECT id FROM millitop_tv.launcher_web_apps WHERE id=$1 FOR SHARE',[req.params.id]);
   if(!found.rowCount)return {status:404,body:{error:'App not found.'}};
   const devices=await c.query(`SELECT d.id FROM millitop_tv.devices d JOIN millitop_tv.households h ON h.id=d.household_id WHERE d.id=ANY($1::uuid[]) AND d.revoked_at IS NULL AND h.active FOR SHARE OF d,h`,[b.deviceIds]);
   if(devices.rowCount!==b.deviceIds.length)return {status:400,body:{error:'One or more devices are inactive or revoked. No assignments changed.'}};
   for(const id of b.deviceIds)await c.query(`INSERT INTO millitop_tv.launcher_web_app_assignments(app_id,device_id,enabled,assigned_by) VALUES($1,$2,$3,$4) ON CONFLICT(app_id,device_id) DO UPDATE SET enabled=EXCLUDED.enabled,assigned_by=EXCLUDED.assigned_by,assigned_at=now()`,[req.params.id,id,b.enabled,req.admin.id]);
   await audit(c,req.admin.id,req.params.id,'web_app.assignment_updated',{count:b.deviceIds.length,enabled:b.enabled});
   return {body:{accepted:true,count:b.deviceIds.length,enabled:b.enabled}};
  });
 });
 app.post('/api/device/web-apps',deviceLimit,async(req,res,next)=>{
  const token=/^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(req.get('authorization')||'');
  if(!token)return res.status(401).json({error:'Device authentication required.'});
  return tx(res,next,async c=>{
   const r=await c.query(`SELECT d.id FROM millitop_tv.device_credentials k JOIN millitop_tv.devices d ON d.id=k.device_id JOIN millitop_tv.households h ON h.id=d.household_id WHERE k.token_hash=$1 AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at>now()) AND d.revoked_at IS NULL AND h.active FOR SHARE OF k,d,h`,[createHash('sha256').update(token[1]).digest('hex')]);
   if(!r.rowCount)return {status:401,body:{error:'Device credential is invalid or revoked.'}};
   const apps=await c.query(`SELECT a.id,a.title,a.url,a.icon,a.revision FROM millitop_tv.launcher_web_app_assignments x JOIN millitop_tv.launcher_web_apps a ON a.id=x.app_id WHERE x.device_id=$1 AND x.enabled AND a.enabled ORDER BY a.title,a.id LIMIT 200`,[r.rows[0].id]);
   return {body:{protocol:1,apps:apps.rows,serverTime:new Date().toISOString()}};
  });
 });
}
