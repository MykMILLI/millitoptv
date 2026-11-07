import {createHash,randomUUID} from 'node:crypto';
import {uuid,text,requestBody,replyBody,articleBody,cardBody,revision,cursor,page} from './community-validation.mjs';
export function registerCommunityRoutes(app,pool,deviceLimit,{discovery=null}={}){
 if(typeof deviceLimit!=='function')throw new Error('Device limiter required.');
 const admin=(req,res)=>{if(!req.admin?.id){res.status(401).json({error:'Dashboard authentication required.'});return false;}return true;};
 const bad=(res,e)=>res.status(400).json({error:e.message});
 async function tx(req,res,next,device,work){let c;try{
  c=await pool.connect();await c.query('BEGIN');await c.query("SET LOCAL statement_timeout='15s'");
  let identity=null;
  if(device){const match=/^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(req.get('authorization')||'');if(!match){await c.query('ROLLBACK');return res.status(401).json({error:'Device authentication required.'});}
   const r=await c.query(`SELECT d.id,d.household_id FROM millitop_tv.device_credentials k JOIN millitop_tv.devices d ON d.id=k.device_id JOIN millitop_tv.households h ON h.id=d.household_id WHERE k.token_hash=$1 AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at>now()) AND d.revoked_at IS NULL AND h.active FOR SHARE OF k,d,h`,[createHash('sha256').update(match[1]).digest('hex')]);
   if(!r.rowCount){await c.query('ROLLBACK');return res.status(401).json({error:'Device credential is invalid or revoked.'});}identity=r.rows[0];
  }
  const result=await work(c,identity);await c.query('COMMIT');res.status(result.status??200).json(result.body);
 }catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});next(e);}finally{c?.release();}}
 const event=(c,user,device,id,action,details={})=>c.query('INSERT INTO millitop_tv.community_events(id,actor_user_id,actor_device_id,entity_id,action,details) VALUES($1,$2,$3,$4,$5,$6)',[randomUUID(),user,device,id,action,JSON.stringify(details)]);
 const ok=body=>({body});
 async function targets(c,ids){if(!ids.length)return;const r=await c.query('SELECT id FROM millitop_tv.households WHERE id=ANY($1::uuid[]) AND active FOR SHARE',[ids]);if(r.rowCount!==ids.length)throw new Error('A selected household is unavailable.');}
 app.post('/api/device/support/create',deviceLimit,(req,res,next)=>{
  let b;try{b=requestBody(req.body);}catch(e){return bad(res,e);}
  return tx(req,res,next,true,async(c,d)=>{
   await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[b.requestId]);
   const old=await c.query('SELECT id,device_id,kind,title,body FROM millitop_tv.support_requests WHERE id=$1',[b.requestId]);
   if(old.rowCount){const o=old.rows[0];if(o.device_id!==d.id||o.kind!==b.kind||o.title!==b.title||o.body!==b.body)return {status:409,body:{error:'Request ID already used. Do not change a pending submission.'}};return ok({accepted:true,id:o.id,alreadySaved:true});}
   await c.query('INSERT INTO millitop_tv.support_requests(id,household_id,device_id,kind,title,body) VALUES($1,$2,$3,$4,$5,$6)',[b.requestId,d.household_id,d.id,b.kind,b.title,b.body]);
   await event(c,null,d.id,b.requestId,'support.created');return {status:201,body:{accepted:true,id:b.requestId}};
  });
 });
 async function listing(c,household,after){const rows=(await c.query(`SELECT id,kind,title,status,revision,created_at,updated_at FROM millitop_tv.support_requests WHERE ($1::uuid IS NULL OR household_id=$1) AND ($2::timestamptz IS NULL OR (created_at,id)<($2::timestamptz,$3::uuid)) ORDER BY created_at DESC,id DESC LIMIT 51`,[household,after?.at??null,after?.id??null])).rows;return page(rows);}
 app.post('/api/device/support/list',deviceLimit,(req,res,next)=>{let after;try{after=cursor(req.body?.cursor);}catch(e){return bad(res,e);}return tx(req,res,next,true,async(c,d)=>ok(await listing(c,d.household_id,after)));});
 app.get('/api/admin/support',async(req,res,next)=>{if(!admin(req,res))return;let after;try{after=cursor(req.query.cursor);}catch(e){return bad(res,e);}return tx(req,res,next,false,async c=>ok(await listing(c,null,after)));});
 async function detail(c,id,household,isAdmin){const r=await c.query(`SELECT r.*,h.name AS household_name,d.name AS device_name FROM millitop_tv.support_requests r JOIN millitop_tv.households h ON h.id=r.household_id JOIN millitop_tv.devices d ON d.id=r.device_id WHERE r.id=$1 AND ($2::uuid IS NULL OR r.household_id=$2) FOR SHARE OF r`,[id,household]);if(!r.rowCount)return {status:404,body:{error:'Conversation not found.'}};
  const replies=(await c.query('SELECT id,body,author_kind,public,created_at FROM millitop_tv.support_replies WHERE request_id=$1 AND ($2 OR public) ORDER BY created_at,id LIMIT 501',[id,isAdmin])).rows;
  return ok({request:r.rows[0],replies:replies.slice(0,500),limited:replies.length>500});}
 app.post('/api/device/support/detail',deviceLimit,(req,res,next)=>{if(!uuid(req.body?.requestId))return bad(res,new Error('Invalid conversation.'));return tx(req,res,next,true,(c,d)=>detail(c,req.body.requestId,d.household_id,false));});
 app.get('/api/admin/support/:id',async(req,res,next)=>{if(!admin(req,res))return;if(!uuid(req.params.id))return bad(res,new Error('Invalid conversation.'));return tx(req,res,next,false,c=>detail(c,req.params.id,null,true));});
 async function reply(c,d,user,b,isPublic){await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[b.messageId]);
  const parent=await c.query('SELECT id FROM millitop_tv.support_requests WHERE id=$1 AND ($2::uuid IS NULL OR household_id=$2) FOR UPDATE',[b.requestId,d?.household_id??null]);if(!parent.rowCount)return {status:404,body:{error:'Conversation not found.'}};
  const old=await c.query('SELECT id,request_id,body,actor_device_id,actor_user_id,public FROM millitop_tv.support_replies WHERE id=$1',[b.messageId]);
  if(old.rowCount){const o=old.rows[0];if(o.request_id!==b.requestId||o.body!==b.body||o.actor_device_id!==(d?.id??null)||o.actor_user_id!==user||o.public!==isPublic)return {status:409,body:{error:'Reply ID already used.'}};return ok({accepted:true,id:o.id,alreadySaved:true});}
  const count=await c.query('SELECT count(*)::int AS total FROM millitop_tv.support_replies WHERE request_id=$1',[b.requestId]);if(count.rows[0].total>=500)return {status:409,body:{error:'This conversation reached its message limit. Start a new request.'}};
  await c.query('INSERT INTO millitop_tv.support_replies(id,request_id,body,author_kind,actor_user_id,actor_device_id,public) VALUES($1,$2,$3,$4,$5,$6,$7)',[b.messageId,b.requestId,b.body,d?'household':'admin',user,d?.id??null,isPublic]);
  await c.query("UPDATE millitop_tv.support_requests SET updated_at=now(),revision=revision+1,status=CASE WHEN $2 AND status IN ('closed','waiting_customer') THEN 'open' ELSE status END WHERE id=$1",[b.requestId,!!d]);
  await event(c,user,d?.id??null,b.requestId,isPublic?'support.reply':'support.internal_note');return {status:201,body:{accepted:true,id:b.messageId}};
 }
 app.post('/api/device/support/reply',deviceLimit,(req,res,next)=>{let b;try{b=replyBody(req.body);}catch(e){return bad(res,e);}return tx(req,res,next,true,(c,d)=>reply(c,d,null,b,true));});
 app.post('/api/admin/support/reply',async(req,res,next)=>{if(!admin(req,res))return;let b;try{b=replyBody(req.body);if(typeof req.body.public!=='boolean')throw new Error('Choose public reply or internal note.');}catch(e){return bad(res,e);}return tx(req,res,next,false,c=>reply(c,null,req.admin.id,b,req.body.public));});
 app.post('/api/admin/support/:id/status',async(req,res,next)=>{if(!admin(req,res))return;let rev;try{if(!uuid(req.params.id)||!['open','in_progress','waiting_customer','closed'].includes(req.body?.status))throw new Error('Invalid status.');rev=revision(req.body.revision);}catch(e){return bad(res,e);}return tx(req,res,next,false,async c=>{const r=await c.query('UPDATE millitop_tv.support_requests SET status=$3,revision=revision+1,updated_at=now() WHERE id=$1 AND revision=$2 RETURNING id',[req.params.id,rev,req.body.status]);if(!r.rowCount)return {status:409,body:{error:'Conversation changed. Refresh first.'}};await event(c,req.admin.id,null,req.params.id,'support.status');return ok({accepted:true});});});
 for(const type of ['articles','cards']){
  const table=type==='articles'?'help_articles':'discovery_cards';
  app.get('/api/admin/content/'+type,async(req,res,next)=>{if(!admin(req,res))return;return tx(req,res,next,false,async c=>{const rows=(await c.query(`SELECT * FROM millitop_tv.${table} ORDER BY updated_at DESC,id LIMIT 201`)).rows;return ok({items:rows.slice(0,200),limited:rows.length>200});});});
  app.post('/api/admin/content/'+type,async(req,res,next)=>{if(!admin(req,res))return;let b,id,rev;try{b=type==='articles'?articleBody(req.body):cardBody(req.body);id=req.body.id??randomUUID();if(!uuid(id))throw new Error('Invalid content ID.');rev=req.body.id?revision(b.revision):null;}catch(e){return bad(res,e);}
   return tx(req,res,next,false,async c=>{await targets(c,b.households);let result;
    if(rev===null){await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',['community.'+type]);const count=await c.query(`SELECT count(*)::int AS total FROM millitop_tv.${table}`);if(count.rows[0].total>=200)return {status:409,body:{error:'Content limit reached. Edit an existing entry.'}};
     result=type==='articles'?await c.query('INSERT INTO millitop_tv.help_articles(id,title,category,markdown,published,household_ids,created_by) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *',[id,b.title,b.category,b.markdown,b.published,b.households,req.admin.id]):await c.query('INSERT INTO millitop_tv.discovery_cards(id,title,description,section,trailer_url,thumbnail_url,position,published,household_ids,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *',[id,b.title,b.description,b.section,b.url,b.thumbnail,b.position,b.published,b.households,req.admin.id]);
    }else{result=type==='articles'?await c.query('UPDATE millitop_tv.help_articles SET title=$3,category=$4,markdown=$5,published=$6,household_ids=$7,revision=revision+1,updated_at=now() WHERE id=$1 AND revision=$2 RETURNING *',[id,rev,b.title,b.category,b.markdown,b.published,b.households]):await c.query('UPDATE millitop_tv.discovery_cards SET title=$3,description=$4,section=$5,trailer_url=$6,thumbnail_url=$7,position=$8,published=$9,household_ids=$10,revision=revision+1,updated_at=now() WHERE id=$1 AND revision=$2 RETURNING *',[id,rev,b.title,b.description,b.section,b.url,b.thumbnail,b.position,b.published,b.households]);}
    if(!result.rowCount)return {status:409,body:{error:'Content changed. Refresh before editing.'}};await event(c,req.admin.id,null,id,'content.'+type+'.saved',{revision:result.rows[0].revision,published:b.published});return ok(result.rows[0]);
   });
  });
 }
 app.post('/api/device/content',deviceLimit,(req,res,next)=>{let q;try{q=text(req.body?.query??'',160,'search',{empty:true});}catch(e){return bad(res,e);}return tx(req,res,next,true,async(c,d)=>{
  const articles=(await c.query(`SELECT id,title,category,revision,updated_at,substring(markdown from greatest(1,strpos(lower(markdown),lower($2))-80) for 240) AS snippet FROM millitop_tv.help_articles WHERE published AND (cardinality(household_ids)=0 OR $1=ANY(household_ids)) AND ($2='' OR strpos(lower(title||' '||markdown),lower($2))>0) ORDER BY title,id LIMIT 51`,[d.household_id,q])).rows;
  const cards=(await c.query('SELECT id,title,description,section,trailer_url,thumbnail_url FROM millitop_tv.discovery_cards WHERE published AND (cardinality(household_ids)=0 OR $1=ANY(household_ids)) ORDER BY position,title,id LIMIT 101',[d.household_id])).rows;
  const automatic=req.body?.discoveryProtocol===1&&discovery;const combined=automatic?[...discovery.cards(),...cards]:cards;return ok({protocol:1,articles:articles.slice(0,50),articlesLimited:articles.length>50,cards:combined.slice(0,100),cardsLimited:combined.length>100,discovery:automatic?discovery.status():null});
 });});
 app.post('/api/device/article',deviceLimit,(req,res,next)=>{if(!uuid(req.body?.id))return bad(res,new Error('Invalid article.'));return tx(req,res,next,true,async(c,d)=>{const r=await c.query('SELECT id,title,category,markdown,revision,updated_at FROM millitop_tv.help_articles WHERE id=$1 AND published AND (cardinality(household_ids)=0 OR $2=ANY(household_ids))',[req.body.id,d.household_id]);return r.rowCount?ok(r.rows[0]):{status:404,body:{error:'Article unavailable or no longer published.'}};});});
}
