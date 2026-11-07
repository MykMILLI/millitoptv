import {createHash} from 'node:crypto';
import {isUuid} from './web-app-validation.mjs';
import {normalizeOperation,validRevision,operationHash,decideMutation,entityDto,validateAvatar} from './profile-sync-validation.mjs';
export function registerProfileSyncRoutes(app,pool,limit){
 if(typeof limit!=='function')throw new Error('Device rate limiter required.');
 async function tx(req,res,next,work){const match=/^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(req.get('authorization')||'');if(!match)return res.status(401).json({error:'Device authentication required.'});let c;try{
  c=await pool.connect();await c.query('BEGIN');await c.query("SET LOCAL statement_timeout='15s'");
  const r=await c.query(`SELECT d.id,d.household_id FROM millitop_tv.device_credentials k JOIN millitop_tv.devices d ON d.id=k.device_id JOIN millitop_tv.households h ON h.id=d.household_id WHERE k.token_hash=$1 AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at>now()) AND d.revoked_at IS NULL AND h.active FOR SHARE OF k,d,h`,[createHash('sha256').update(match[1]).digest('hex')]);
  if(!r.rowCount){await c.query('ROLLBACK');return res.status(401).json({error:'Device credential is invalid or revoked.'});}
  const result=await work(c,r.rows[0]);await c.query('COMMIT');res.status(result.status??200).json(result.body);
 }catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});next(e);}finally{c?.release();}}
 app.post('/api/device/profile-sync/pull',limit,(req,res,next)=>{let after;try{after=validRevision(req.body?.after??0);}catch(e){return res.status(400).json({error:e.message});}return tx(req,res,next,async(c,d)=>{
  const h=await c.query('SELECT revision FROM millitop_tv.profile_sync_heads WHERE household_id=$1',[d.household_id]);const head=Number(h.rows[0]?.revision??0);if(after>head)return {body:{protocol:1,resetRequired:true,head,changes:[],cursor:after,hasMore:false}};
  const rows=(await c.query('SELECT profile_id,kind,entity_key,revision,deleted,payload FROM millitop_tv.profile_sync_events WHERE household_id=$1 AND revision>$2 AND revision<=$3 ORDER BY revision LIMIT 201',[d.household_id,after,head])).rows;const changes=rows.slice(0,200);return {body:{protocol:1,resetRequired:false,head,changes:changes.map(entityDto),cursor:changes.length?Number(changes.at(-1).revision):after,hasMore:rows.length>200}};
 });});
 app.post('/api/device/profile-sync/push',limit,(req,res,next)=>{let op;try{op=normalizeOperation(req.body,{inspectAvatar:false});}catch(e){return res.status(400).json({error:e.message});}const hash=operationHash(op);return tx(req,res,next,async(c,d)=>{
  let preparedAvatar=null;
  if(op.kind==='profile'&&!op.deleted&&typeof op.data.avatarPng==='string'){
   try{preparedAvatar=validateAvatar(op.data.avatarPng);}catch(e){return {status:400,body:{error:e.message}};}
  }
  // Lock order is household head, then receipt/entity. Different households
  // cannot inspect each other's rows, even if UUIDs/operation IDs are guessed.
  await c.query('INSERT INTO millitop_tv.profile_sync_heads(household_id) VALUES($1) ON CONFLICT(household_id) DO NOTHING',[d.household_id]);
  await c.query('SELECT revision FROM millitop_tv.profile_sync_heads WHERE household_id=$1 FOR UPDATE',[d.household_id]);
  const old=await c.query('SELECT payload_hash,result FROM millitop_tv.profile_sync_operations WHERE device_id=$1 AND operation_id=$2 AND household_id=$3',[d.id,op.operationId,d.household_id]);
  if(old.rowCount)return {body:old.rows[0].payload_hash===hash?old.rows[0].result:{accepted:false,code:'OPERATION_ID_REUSED'}};
  async function finish(body){await c.query('INSERT INTO millitop_tv.profile_sync_operations(household_id,device_id,operation_id,payload_hash,result) VALUES($1,$2,$3,$4,$5)',[d.household_id,d.id,op.operationId,hash,JSON.stringify(body)]);return {body};}
  const found=await c.query('SELECT profile_id,kind,entity_key,revision,deleted,payload FROM millitop_tv.profile_sync_entities WHERE household_id=$1 AND profile_id=$2 AND kind=$3 AND entity_key=$4',[d.household_id,op.profileId,op.kind,op.key]);const current=entityDto(found.rows[0]);let parent=null;
  if(op.kind!=='profile'){const r=await c.query("SELECT deleted FROM millitop_tv.profile_sync_entities WHERE household_id=$1 AND profile_id=$2 AND kind='profile' AND entity_key='profile'",[d.household_id,op.profileId]);parent=r.rows[0]??null;}
  const decision=decideMutation(current,op,parent);if(decision.code!=='APPLY')return finish({accepted:false,code:decision.code,current});
  if(!current&&!op.deleted){const maximum=op.kind==='profile'?40:op.kind==='favorite'?500:op.kind==='shortcut'?100:10;const count=await c.query('SELECT count(*)::int AS total FROM millitop_tv.profile_sync_entities WHERE household_id=$1 AND kind=$2 AND NOT deleted AND ($3::uuid IS NULL OR profile_id=$3)',[d.household_id,op.kind,op.kind==='profile'?null:op.profileId]);if(count.rows[0].total>=maximum)return finish({accepted:false,code:'LIMIT_REACHED',current:null});}
  let payload=op.deleted?null:op.data;
  if(op.kind==='profile'&&!op.deleted){let digest=current?.data?.avatarDigest??null;
   if(Object.hasOwn(op.data,'avatarPng')){
    if(op.data.avatarPng===null){await c.query('DELETE FROM millitop_tv.profile_sync_avatars WHERE household_id=$1 AND profile_id=$2',[d.household_id,op.profileId]);digest=null;}
    else{const avatar=preparedAvatar;digest=avatar.digest;await c.query('INSERT INTO millitop_tv.profile_sync_avatars(household_id,profile_id,digest,png) VALUES($1,$2,$3,$4) ON CONFLICT(household_id,profile_id) DO UPDATE SET digest=EXCLUDED.digest,png=EXCLUDED.png,updated_at=now()',[d.household_id,op.profileId,digest,avatar.png]);}
   }
   payload={name:op.data.name,avatarDigest:digest};
  }
  // No resurrection under a tombstoned profile UUID. Child entities remain
  // retained for reconciliation but are unavailable to active clients.
  const revision=Number((await c.query('UPDATE millitop_tv.profile_sync_heads SET revision=revision+1 WHERE household_id=$1 RETURNING revision',[d.household_id])).rows[0].revision);
  if(!Number.isSafeInteger(revision))throw Error('Sync revision exceeds safe numeric range.');
  await c.query('INSERT INTO millitop_tv.profile_sync_entities(household_id,profile_id,kind,entity_key,revision,deleted,payload,updated_by_device) VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(household_id,profile_id,kind,entity_key) DO UPDATE SET revision=EXCLUDED.revision,deleted=EXCLUDED.deleted,payload=EXCLUDED.payload,updated_by_device=EXCLUDED.updated_by_device,updated_at=now()',[d.household_id,op.profileId,op.kind,op.key,revision,op.deleted,payload===null?null:JSON.stringify(payload),d.id]);
  await c.query('INSERT INTO millitop_tv.profile_sync_events(household_id,revision,profile_id,kind,entity_key,deleted,payload) VALUES($1,$2,$3,$4,$5,$6,$7)',[d.household_id,revision,op.profileId,op.kind,op.key,op.deleted,payload===null?null:JSON.stringify(payload)]);
  return finish({accepted:true,operationId:op.operationId,entity:{profileId:op.profileId,kind:op.kind,key:op.key,revision,deleted:op.deleted,data:payload}});
 });});
 app.post('/api/device/profile-sync/avatar',limit,(req,res,next)=>{if(!isUuid(req.body?.profileId))return res.status(400).json({error:'Invalid shared profile.'});return tx(req,res,next,async(c,d)=>{const r=await c.query("SELECT a.digest,a.png FROM millitop_tv.profile_sync_avatars a JOIN millitop_tv.profile_sync_entities e ON e.household_id=a.household_id AND e.profile_id=a.profile_id AND e.kind='profile' AND e.entity_key='profile' WHERE a.household_id=$1 AND a.profile_id=$2 AND NOT e.deleted",[d.household_id,req.body.profileId]);return r.rowCount?{body:{digest:r.rows[0].digest,pngBase64:r.rows[0].png.toString('base64')}}:{status:404,body:{error:'Avatar unavailable.'}};});});
}
