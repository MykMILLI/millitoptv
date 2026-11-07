import { randomUUID, createHash } from 'node:crypto';
import { rateLimit } from 'express-rate-limit';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const hash = v => createHash('sha256').update(v).digest('hex');
export function registerMessageRoutes(app, pool) {
  const limit = rateLimit({windowMs:60000,limit:120,standardHeaders:'draft-8',legacyHeaders:false});
  async function device(connection, req) {
    const token = /^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(req.get('authorization') || '');
    if (!token) return null;
    const result = await connection.query(`SELECT d.id FROM millitop_tv.device_credentials c
      JOIN millitop_tv.devices d ON d.id=c.device_id
      JOIN millitop_tv.households h ON h.id=d.household_id
      WHERE c.token_hash=$1 AND c.revoked_at IS NULL
      AND (c.expires_at IS NULL OR c.expires_at>now())
      AND d.revoked_at IS NULL AND h.active=true FOR SHARE OF d`,[hash(token[1])]);
    return result.rows[0]?.id || null;
  }
  app.post('/api/admin/messages', async (req,res,next)=>{
    const {title,body,requiresAck,householdId,requestId}=req.body || {};
    if(typeof title!=='string'||!title.trim()||title.trim().length>200||
      typeof body!=='string'||!body.trim()||body.trim().length>30000||
      typeof requiresAck!=='boolean'||typeof requestId!=='string'||!uuid.test(requestId)||
      (householdId!==null && (typeof householdId!=='string'||!uuid.test(householdId))))
      return res.status(400).json({error:'Enter a title, message, and valid audience.'});
    let c;
    try {
      c=await pool.connect(); await c.query('BEGIN');
      // Serialize repeat submissions with the same request ID.
      await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[requestId]);
      const existing=await c.query('SELECT id,created_by FROM millitop_tv.messages WHERE id=$1',[requestId]);
      if(existing.rowCount){
        if(existing.rows[0].created_by!==req.admin.id){await c.query('ROLLBACK');return res.status(409).json({error:'Publication ID conflict.'});}
        const revision=await c.query('SELECT id FROM millitop_tv.message_revisions WHERE message_id=$1 ORDER BY revision DESC LIMIT 1',[requestId]);
        await c.query('COMMIT'); return res.json({id:requestId,revisionId:revision.rows[0]?.id,alreadyPublished:true});
      }
      if(householdId){
        const h=await c.query('SELECT id FROM millitop_tv.households WHERE id=$1 AND active FOR SHARE',[householdId]);
        if(!h.rowCount){await c.query('ROLLBACK');return res.status(404).json({error:'Household not found.'});}
      }
      await c.query(`INSERT INTO millitop_tv.messages(id,draft_title,draft_body,draft_requires_ack,created_by)
        VALUES($1,$2,$3,$4,$5)`,[requestId,title.trim(),body.trim(),requiresAck,req.admin.id]);
      const revision=await c.query(`INSERT INTO millitop_tv.message_revisions(message_id,revision,title,body,requires_ack,published_by)
        VALUES($1,1,$2,$3,$4,$5) RETURNING id`,[requestId,title.trim(),body.trim(),requiresAck,req.admin.id]);
      const rid=revision.rows[0].id;
      const deliveries=await c.query(`INSERT INTO millitop_tv.deliveries(revision_id,device_id)
        SELECT $1,d.id FROM millitop_tv.devices d JOIN millitop_tv.households h ON h.id=d.household_id
        WHERE d.revoked_at IS NULL AND h.active AND ($2::uuid IS NULL OR h.id=$2)
        ON CONFLICT(revision_id,device_id) DO NOTHING RETURNING id`,[rid,householdId]);
      await c.query(`INSERT INTO millitop_tv.audit_log(actor_user_id,action,entity_type,entity_id,details)
        VALUES($1,'message.published','message',$2,$3::jsonb)`,[req.admin.id,requestId,JSON.stringify({recipients:deliveries.rowCount,householdId})]);
      await c.query('COMMIT');res.status(201).json({id:requestId,revisionId:rid,recipients:deliveries.rowCount});
    }catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});next(e);}finally{c?.release();}
  });
  app.get('/api/admin/messages',async(req,res,next)=>{
    try{
      const r=await pool.query(`SELECT m.id,r.id AS revision_id,r.title,r.body,r.requires_ack,r.published_at,
        count(d.id)::int AS recipients,count(d.delivered_at)::int AS delivered,
        count(d.opened_at)::int AS opened,count(d.acknowledged_at)::int AS acknowledged
        FROM millitop_tv.messages m JOIN millitop_tv.message_revisions r ON r.message_id=m.id
        LEFT JOIN millitop_tv.deliveries d ON d.revision_id=r.id
        GROUP BY m.id,r.id ORDER BY r.published_at DESC LIMIT 200`);res.json(r.rows);
    }catch(e){next(e);}
  });
  app.get('/api/admin/messages/:id/receipts',async(req,res,next)=>{
    if(!uuid.test(req.params.id))return res.status(400).json({error:'Invalid message ID.'});
    try{
      const r=await pool.query(`SELECT d.id,d.device_id,v.name AS device_name,h.name AS household_name,
        r.revision,d.assigned_at,d.delivered_at,d.opened_at,d.acknowledged_at,d.acknowledged_profile_id
        FROM millitop_tv.deliveries d JOIN millitop_tv.message_revisions r ON r.id=d.revision_id
        JOIN millitop_tv.devices v ON v.id=d.device_id JOIN millitop_tv.households h ON h.id=v.household_id
        WHERE r.message_id=$1 ORDER BY h.name,v.name,r.revision`,[req.params.id]);res.json(r.rows);
    }catch(e){next(e);}
  });
  app.post('/api/device/messages',limit,async(req,res,next)=>{
    const cursor=req.body?.cursor??null;
    if(cursor!==null&&(typeof cursor!=='string'||!uuid.test(cursor)))return res.status(400).json({error:'Invalid cursor.'});
    let c;
    try{
      c=await pool.connect();await c.query('BEGIN');const id=await device(c,req);
      if(!id){await c.query('ROLLBACK');return res.status(401).json({error:'Device authentication failed.'});}
      const r=await c.query(`SELECT d.id AS "deliveryId",r.id AS "revisionId",r.title,r.body,
        r.requires_ack AS "requiresAck",r.published_at AS "publishedAt"
        FROM millitop_tv.deliveries d JOIN millitop_tv.message_revisions r ON r.id=d.revision_id
        WHERE d.device_id=$1 AND ($2::uuid IS NULL OR d.id>$2)
        ORDER BY d.id LIMIT 100`,[id,cursor]);
      await c.query('COMMIT');res.json({messages:r.rows,nextCursor:r.rowCount===100?r.rows.at(-1).deliveryId:null});
    }catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});next(e);}finally{c?.release();}
  });
  app.post('/api/device/receipts',limit,async(req,res,next)=>{
    const events=req.body?.events;
    if(!Array.isArray(events)||!events.length||events.length>100||events.some(e=>
      !e||typeof e.id!=='string'||!uuid.test(e.id)||typeof e.deliveryId!=='string'||!uuid.test(e.deliveryId)||
      !['delivered','opened','acknowledged'].includes(e.kind)||
      (e.profileId!=null&&(typeof e.profileId!=='string'||e.profileId.length>120))))
      return res.status(400).json({error:'Invalid receipts.'});
    let c;
    try{
      c=await pool.connect();await c.query('BEGIN');const id=await device(c,req);
      if(!id){await c.query('ROLLBACK');return res.status(401).json({error:'Device authentication failed.'});}
      const accepted=[];
      for(const e of events){
        const delivery=await c.query(`SELECT d.id,r.requires_ack FROM millitop_tv.deliveries d
          JOIN millitop_tv.message_revisions r ON r.id=d.revision_id
          WHERE d.id=$1 AND d.device_id=$2 FOR UPDATE OF d`,[e.deliveryId,id]);
        if(!delivery.rowCount || (e.kind==='acknowledged'&&!delivery.rows[0].requires_ack)){
          await c.query('ROLLBACK');return res.status(403).json({error:'Receipt is not permitted.'});
        }
        await c.query(`INSERT INTO millitop_tv.receipt_events(id,delivery_id,device_id,kind,profile_id)
          VALUES($1,$2,$3,$4,$5) ON CONFLICT(id) DO NOTHING`,[e.id,e.deliveryId,id,e.kind,e.profileId??null]);
        const stored=await c.query(`SELECT delivery_id,device_id,kind,profile_id FROM millitop_tv.receipt_events WHERE id=$1`,[e.id]);
        const s=stored.rows[0];
        if(!s||s.delivery_id!==e.deliveryId||s.device_id!==id||s.kind!==e.kind||s.profile_id!==(e.profileId??null)){
          await c.query('ROLLBACK');return res.status(409).json({error:'Receipt ID conflict.'});
        }
        await c.query(`UPDATE millitop_tv.deliveries SET
          delivered_at=COALESCE(delivered_at,now()),
          opened_at=CASE WHEN $3 IN ('opened','acknowledged') THEN COALESCE(opened_at,now()) ELSE opened_at END,
          acknowledged_profile_id=CASE WHEN $3='acknowledged' AND acknowledged_at IS NULL THEN $4 ELSE acknowledged_profile_id END,
          acknowledged_at=CASE WHEN $3='acknowledged' THEN COALESCE(acknowledged_at,now()) ELSE acknowledged_at END
          WHERE id=$1 AND device_id=$2`,[e.deliveryId,id,e.kind,e.profileId??null]);
        accepted.push(e.id);
      }
      await c.query('COMMIT');res.json({accepted});
    }catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});next(e);}finally{c?.release();}
  });
}
