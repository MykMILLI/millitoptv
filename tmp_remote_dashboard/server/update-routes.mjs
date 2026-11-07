import { randomUUID, createHash } from 'node:crypto';
import { rateLimit } from 'express-rate-limit';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isId = value => typeof value === 'string' && uuid.test(value);
const states = new Set(['offered','deferred','downloading','downloaded','installing','awaiting_confirmation','failed']);

export function registerUpdateRoutes(app, pool) {
  const limit = rateLimit({windowMs:60000,limit:120,standardHeaders:'draft-8',legacyHeaders:false});
  async function transaction(res, next, work) {
    let c; const pending = [];
    const deferred = Object.create(res);
    deferred.status = code => { pending.push(['status',code]); return deferred; };
    deferred.json = body => { pending.push(['json',body]); return deferred; };
    try { c = await pool.connect(); await c.query('BEGIN'); await work(c, deferred); await c.query('COMMIT');
      for (const [method,value] of pending) res[method](value); }
    catch(e) { if(c) await c.query('ROLLBACK').catch(()=>{}); next(e); }
    finally { c?.release(); }
  }
  async function identify(c, req) {
    const token = /^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(req.get('authorization') || '');
    if (!token) return null;
    const r = await c.query(`SELECT d.id FROM millitop_tv.device_credentials c
      JOIN millitop_tv.devices d ON d.id=c.device_id
      JOIN millitop_tv.households h ON h.id=d.household_id
      WHERE c.token_hash=$1 AND c.revoked_at IS NULL
      AND (c.expires_at IS NULL OR c.expires_at>now())
      AND d.revoked_at IS NULL AND h.active FOR SHARE OF d`,
      [createHash('sha256').update(token[1]).digest('hex')]);
    return r.rows[0]?.id;
  }
  // These routes must be registered AFTER the existing /api/admin authentication middleware.
  app.get('/api/admin/releases', async(req,res,next)=>{
    try { res.json((await pool.query('SELECT * FROM millitop_tv.app_releases ORDER BY created_at DESC LIMIT 200')).rows); }
    catch(e){next(e);}
  });
  app.post('/api/admin/releases', async(req,res,next)=>{
    const b=req.body || {}; let url;
    try {url=new URL(b.installerUrl);} catch {return res.status(400).json({error:'Invalid installer URL.'});}
    if(typeof b.version!=='string' || !/^\d{1,5}\.\d{1,5}\.\d{1,5}$/.test(b.version) ||
      !Number.isInteger(b.build) || b.build<1 || b.build>2147483647 ||
      typeof b.notes!=='string' || b.notes.length>12000 ||
      typeof b.sha256!=='string' || !/^[a-f0-9]{64}$/.test(b.sha256) ||
      !Number.isSafeInteger(b.sizeBytes) || b.sizeBytes<1 ||
      url.protocol!=='https:' || url.username || url.password || url.hash ||
      b.installerUrl.length>2048)
      return res.status(400).json({error:'Invalid release metadata. HTTPS and lowercase SHA-256 are required.'});
    try {
      const r=await pool.query(`INSERT INTO millitop_tv.app_releases
        (id,version,build,notes,installer_url,sha256,size_bytes,created_by)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(version,build,platform) DO NOTHING RETURNING *`,
        [randomUUID(),b.version,b.build,b.notes,url.href,b.sha256,b.sizeBytes,req.admin.id]);
      if(!r.rowCount)return res.status(409).json({error:'This version/build already exists. Metadata is immutable.'});
      res.status(201).json(r.rows[0]);
    }catch(e){next(e);}
  });
  app.post('/api/admin/releases/:id/enabled',async(req,res,next)=>{
    if(!isId(req.params.id)||typeof req.body?.enabled!=='boolean')return res.status(400).json({error:'Invalid release or enabled flag.'});
    try{
      const r=await pool.query('UPDATE millitop_tv.app_releases SET enabled=$2 WHERE id=$1 RETURNING *',[req.params.id,req.body.enabled]);
      if(!r.rowCount)return res.status(404).json({error:'Release not found.'});
      res.json(r.rows[0]);
    }catch(e){next(e);}
  });
  app.post('/api/admin/releases/:id/assign',async(req,res,next)=>{
    const ids=req.body?.deviceIds;
    if(!isId(req.params.id)||!Array.isArray(ids)||!ids.length||ids.length>100||!ids.every(isId))
      return res.status(400).json({error:'Select between 1 and 100 device IDs.'});
    return transaction(res,next,async(c,res)=>{
      const release=await c.query('SELECT id FROM millitop_tv.app_releases WHERE id=$1 FOR SHARE',[req.params.id]);
      if(!release.rowCount)return res.status(404).json({error:'Release not found.'});
      const unique=[...new Set(ids)];
      const devices=await c.query(`SELECT d.id FROM millitop_tv.devices d JOIN millitop_tv.households h ON h.id=d.household_id
        WHERE d.id=ANY($1::uuid[]) AND d.revoked_at IS NULL AND h.active FOR SHARE OF d`,[unique]);
      if(devices.rowCount!==unique.length)return res.status(400).json({error:'One or more devices are unavailable.'});
      for(const id of unique)await c.query(`INSERT INTO millitop_tv.app_update_assignments(id,release_id,device_id)
        VALUES($1,$2,$3) ON CONFLICT(release_id,device_id) DO NOTHING`,[randomUUID(),req.params.id,id]);
      res.json({assignedDeviceIds:unique});
    });
  });
  app.get('/api/admin/update-status',async(req,res,next)=>{
    try{
      const r=await pool.query(`SELECT a.*,r.version,r.build,r.enabled,d.name AS device_name,
        d.app_version AS reported_version,d.last_seen_at
        FROM millitop_tv.app_update_assignments a JOIN millitop_tv.app_releases r ON r.id=a.release_id
        JOIN millitop_tv.devices d ON d.id=a.device_id ORDER BY a.assigned_at DESC LIMIT 1000`);
      // A heartbeat alone is not an installation health acknowledgement. Never label it verified here.
      res.json(r.rows);
    }catch(e){next(e);}
  });
  app.post('/api/device/updates/check',limit,async(req,res,next)=>transaction(res,next,async(c,res)=>{
    const id=await identify(c,req);
    if(!id)return res.status(401).json({error:'Device authentication failed.'});
    const r=await c.query(`SELECT a.id AS "assignmentId",r.id AS "releaseId",r.version,r.build,r.notes,
      r.installer_url AS "installerUrl",r.sha256,r.size_bytes::text AS "sizeBytes",r.platform
      FROM millitop_tv.app_update_assignments a JOIN millitop_tv.app_releases r ON r.id=a.release_id
      WHERE a.device_id=$1 AND r.enabled ORDER BY a.assigned_at DESC LIMIT 1`,[id]);
    res.json({update:r.rows[0] || null});
  }));
  app.post('/api/device/updates/report',limit,async(req,res,next)=>{
    const b=req.body || {};
    if(!isId(b.eventId)||!isId(b.assignmentId)||!states.has(b.status)||
      (b.error!==undefined && (typeof b.error!=='string'||b.error.length>1000)))
      return res.status(400).json({error:'Invalid update report.'});
    return transaction(res,next,async(c,res)=>{
      const id=await identify(c,req);
      if(!id)return res.status(401).json({error:'Device authentication failed.'});
      const a=await c.query('SELECT id FROM millitop_tv.app_update_assignments WHERE id=$1 AND device_id=$2 FOR UPDATE',[b.assignmentId,id]);
      if(!a.rowCount)return res.status(404).json({error:'Assignment not found.'});
      const event=await c.query(`INSERT INTO millitop_tv.app_update_events(id,assignment_id,status)
        VALUES($1,$2,$3) ON CONFLICT(id) DO NOTHING RETURNING id`,[b.eventId,b.assignmentId,b.status]);
      if(!event.rowCount){
        const old=await c.query('SELECT assignment_id,status FROM millitop_tv.app_update_events WHERE id=$1',[b.eventId]);
        if(old.rows[0].assignment_id!==b.assignmentId||old.rows[0].status!==b.status)
          return res.status(409).json({error:'Event ID conflict.'});
      }else await c.query(`UPDATE millitop_tv.app_update_assignments SET status=$2,last_error=$3,updated_at=now() WHERE id=$1`,
        [b.assignmentId,b.status,b.status==='failed' ? (b.error || 'No details supplied.') : null]);
      res.json({accepted:true,eventId:b.eventId});
    });
  });
  app.post('/api/device/updates/confirm',limit,async(req,res,next)=>{
    const b=req.body || {};
    if(!isId(b.assignmentId)||typeof b.version!=='string'||!/^\d+\.\d+\.\d+$/.test(b.version)||
       !Number.isInteger(b.build)||b.build<1||b.startupVerified!==true)
      return res.status(400).json({error:'Invalid startup confirmation.'});
    return transaction(res,next,async(c,res)=>{
      const id=await identify(c,req);
      if(!id)return res.status(401).json({error:'Device authentication failed.'});
      const r=await c.query(`SELECT a.id,a.status,r.version,r.build,d.app_version,
        (d.last_seen_at>now()-interval '90 seconds') AS recent
        FROM millitop_tv.app_update_assignments a
        JOIN millitop_tv.app_releases r ON r.id=a.release_id
        JOIN millitop_tv.devices d ON d.id=a.device_id
        WHERE a.id=$1 AND a.device_id=$2 FOR UPDATE OF a`,[b.assignmentId,id]);
      const row=r.rows[0];
      if(!row)return res.status(404).json({error:'Assignment not found.'});
      if(row.version!==b.version||row.build!==b.build||!row.recent||
         row.app_version!==`${b.version}+${b.build}`)
        return res.status(409).json({error:'Expected version has not reported a recent heartbeat.'});
      if(row.status==='verified')return res.json({verified:true});
      if(!['installing','awaiting_confirmation'].includes(row.status))
        return res.status(409).json({error:'An installation handoff must be reported before confirmation.'});
      await c.query(`UPDATE millitop_tv.app_update_assignments
        SET status='verified',verified_at=now(),updated_at=now(),last_error=NULL WHERE id=$1`,[row.id]);
      await c.query(`INSERT INTO millitop_tv.app_update_events(id,assignment_id,status)
        VALUES($1,$2,'verified')`,[randomUUID(),row.id]);
      res.json({verified:true});
    });
  });

}
