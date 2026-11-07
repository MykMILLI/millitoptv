import { randomUUID } from 'node:crypto';
import { SquareAccounts,BillingError,squareId,customerSummary } from './square-accounts.mjs';
import { isUuid,validateProject,hashPin,verifyPin,tokenHash,newBillingSession,publicProject,safeAccount } from './billing-security.mjs';
export function billingRateKey(req){const match=/^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(req.get('authorization')??'');return match?'billing-'+tokenHash(match[1]):'invalid-billing-token';}
export function registerBillingRoutes(app,pool,limits,{square=new SquareAccounts()}={}){
 if(typeof limits?.device!=='function'||typeof limits?.unlock!=='function')throw new Error('Billing rate limiters required.');
 const admin=(req,res)=>{if(!req.admin?.id){res.status(401).json({error:'Dashboard authentication required.'});return false;}return true;};
 const fail=(res,next,e)=>{if(e instanceof BillingError)return res.status(e.status).json({error:e.message});next(e);};
 async function transaction(work){let c;try{c=await pool.connect();await c.query('BEGIN');await c.query("SET LOCAL statement_timeout='15s'");const result=await work(c);await c.query('COMMIT');return result;}catch(e){if(c)await c.query('ROLLBACK').catch(()=>{});throw e;}finally{c?.release();}}
 const audit=(c,actor,account,action,details={})=>c.query('INSERT INTO millitop_tv.billing_events(id,actor_user_id,account_id,action,details) VALUES($1,$2,$3,$4,$5)',[randomUUID(),actor,account,action,JSON.stringify(details)]);
 async function identify(c,req){
  const token=/^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(req.get('authorization')??'');if(!token)throw new BillingError('Device authentication required.',401);
  const r=await c.query(`SELECT d.id,d.household_id,h.name AS household_name FROM millitop_tv.device_credentials k JOIN millitop_tv.devices d ON d.id=k.device_id JOIN millitop_tv.households h ON h.id=d.household_id WHERE k.token_hash=$1 AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at>now()) AND d.revoked_at IS NULL AND h.active FOR SHARE OF k,d,h`,[tokenHash(token[1])]);
  if(!r.rowCount)throw new BillingError('Device credential is invalid or revoked.',401);return r.rows[0];
 }
 async function deviceContext(req,{expected=null,unlockRequired=true}={}){
  return transaction(async c=>{
   const device=await identify(c,req);
   const row=await c.query('SELECT * FROM millitop_tv.billing_accounts WHERE household_id=$1 AND active FOR SHARE',[device.household_id]);
   if(!row.rowCount)return {device,account:null,locked:false};
   const account=row.rows[0];if(expected&&account.id!==expected)throw new BillingError('Account link changed. Refresh Account.',409);
   let locked=false;
   if(account.access_mode==='pin'&&unlockRequired){
    const raw=req.get('x-millitop-billing-session')??'';
    if(!/^[A-Za-z0-9_-]{43}$/.test(raw)){locked=true;}else{
     const session=await c.query('SELECT token_hash FROM millitop_tv.billing_sessions WHERE token_hash=$1 AND account_id=$2 AND device_id=$3 AND expires_at>now() AND revoked_at IS NULL',[tokenHash(raw),account.id,device.id]);locked=!session.rowCount;
    }
   }
   return {device,account,locked};
  });
 }
 async function ready(req){const context=await deviceContext(req);if(!context.account)throw new BillingError('No billing customer is linked to this household.',404);if(context.locked)throw new BillingError('Unlock Account before accessing billing data.',403);return context;}
 async function recheck(req,id){const context=await deviceContext(req,{expected:id});if(!context.account||context.locked)throw new BillingError('Account access changed. Refresh or unlock Account.',403);return context;}
 app.get('/api/admin/billing/square-status',async(req,res,next)=>{if(!admin(req,res))return;try{res.json({connected:true,...await square.identity()});}catch(e){if(e instanceof BillingError)return res.json({connected:false,error:e.message});next(e);}});
 app.get('/api/admin/billing/customers',async(req,res,next)=>{if(!admin(req,res))return;try{res.json(await square.customers(req.query.cursor));}catch(e){fail(res,next,e);}});
 app.get('/api/admin/billing/accounts',async(req,res,next)=>{if(!admin(req,res))return;try{const rows=await pool.query('SELECT b.*,h.name AS household_name FROM millitop_tv.billing_accounts b JOIN millitop_tv.households h ON h.id=b.household_id ORDER BY b.active DESC,b.created_at DESC LIMIT 500');res.json(rows.rows.map(safeAccount));}catch(e){next(e);}});
 app.post('/api/admin/billing/accounts',async(req,res,next)=>{
  if(!admin(req,res))return;const b=req.body??{};
  if(!isUuid(b.householdId)||!['household','pin'].includes(b.accessMode)||b.accessAcknowledged!==true)return res.status(400).json({error:'Select a household, access mode and explicitly acknowledge who can view its billing.'});
  try{
   const [identity,customer,pin]=await Promise.all([square.identity(),square.customer(squareId(b.customerId)),b.accessMode==='pin'?hashPin(b.pin):Promise.resolve(null)]);
   const account=await transaction(async c=>{
    const household=await c.query('SELECT id FROM millitop_tv.households WHERE id=$1 AND active FOR SHARE',[b.householdId]);if(!household.rowCount)throw new BillingError('Active household not found.',404);
    await c.query("SELECT pg_advisory_xact_lock(hashtext('billing-household-'||$1))",[b.householdId]);
    const existing=await c.query('SELECT * FROM millitop_tv.billing_accounts WHERE household_id=$1 AND active FOR UPDATE',[b.householdId]);
    let id;let result;
    if(existing.rowCount&&existing.rows[0].merchant_id===identity.merchantId&&existing.rows[0].customer_id===customer.id&&existing.rows[0].environment===identity.environment){
     id=existing.rows[0].id;
     result=await c.query('UPDATE millitop_tv.billing_accounts SET customer_name=$2,access_mode=$3,pin_salt=$4,pin_hash=$5,revision=revision+1,updated_at=now() WHERE id=$1 RETURNING *',[id,customerSummary(customer).name,b.accessMode,pin?.salt??null,pin?.hash??null]);
     await c.query('UPDATE millitop_tv.billing_sessions SET revoked_at=now() WHERE account_id=$1 AND revoked_at IS NULL',[id]);
    }else{
     await c.query('UPDATE millitop_tv.billing_accounts SET active=false,updated_at=now() WHERE household_id=$1 AND active',[b.householdId]);
     id=randomUUID();result=await c.query('INSERT INTO millitop_tv.billing_accounts(id,household_id,merchant_id,environment,customer_id,customer_name,access_mode,pin_salt,pin_hash,created_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *',[id,b.householdId,identity.merchantId,identity.environment,customer.id,customerSummary(customer).name,b.accessMode,pin?.salt??null,pin?.hash??null,req.admin.id]);
    }
    await audit(c,req.admin.id,id,'billing.customer_linked',{accessMode:b.accessMode});return result.rows[0];
   });res.status(201).json(safeAccount(account));
  }catch(e){if(e.code==='23505')return res.status(409).json({error:'That Square customer is already actively linked. Review the existing household binding.'});if(e instanceof BillingError)return fail(res,next,e);if(e.message?.startsWith('Use a 6'))return res.status(400).json({error:e.message});next(e);}
 });
 app.post('/api/admin/billing/accounts/:id/disable',async(req,res,next)=>{if(!admin(req,res))return;if(!isUuid(req.params.id))return res.status(400).json({error:'Invalid account ID.'});try{await transaction(async c=>{await c.query('UPDATE millitop_tv.billing_accounts SET active=false,updated_at=now() WHERE id=$1',[req.params.id]);await c.query('UPDATE millitop_tv.billing_sessions SET revoked_at=now() WHERE account_id=$1 AND revoked_at IS NULL',[req.params.id]);await audit(c,req.admin.id,req.params.id,'billing.account_disabled');});res.json({disabled:true});}catch(e){next(e);}});
 app.get('/api/admin/billing/projects',async(req,res,next)=>{if(!admin(req,res))return;if(req.query.accountId&&!isUuid(req.query.accountId))return res.status(400).json({error:'Invalid account filter.'});try{const r=await pool.query(`SELECT p.*,b.customer_name,h.name AS household_name FROM millitop_tv.billing_projects p JOIN millitop_tv.billing_accounts b ON b.id=p.account_id JOIN millitop_tv.households h ON h.id=b.household_id WHERE ($1::uuid IS NULL OR p.account_id=$1) ORDER BY p.updated_at DESC LIMIT 500`,[req.query.accountId??null]);res.json(r.rows.map(p=>({...publicProject(p),accountId:p.account_id,internalNote:p.internal_note,householdName:p.household_name,customerName:p.customer_name})));}catch(e){next(e);}});
 app.post('/api/admin/billing/accounts/:id/projects',async(req,res,next)=>{if(!admin(req,res))return;if(!isUuid(req.params.id))return res.status(400).json({error:'Invalid account ID.'});let b;try{b=validateProject(req.body);}catch(e){return res.status(400).json({error:e.message});}try{const p=await transaction(async c=>{const account=await c.query('SELECT id FROM millitop_tv.billing_accounts WHERE id=$1 AND active FOR SHARE',[req.params.id]);if(!account.rowCount)throw new BillingError('Select an active linked account.',404);const id=randomUUID();const r=await c.query('INSERT INTO millitop_tv.billing_projects(id,account_id,title,description,internal_note,status,created_by) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *',[id,req.params.id,b.title,b.description,b.internalNote,b.status,req.admin.id]);await audit(c,req.admin.id,req.params.id,'project.created',{projectId:id});return r.rows[0];});res.status(201).json(publicProject(p));}catch(e){fail(res,next,e);}});
 app.post('/api/admin/billing/projects/:id',async(req,res,next)=>{if(!admin(req,res))return;if(!isUuid(req.params.id))return res.status(400).json({error:'Invalid project ID.'});let b;try{b=validateProject(req.body,{edit:true});}catch(e){return res.status(400).json({error:e.message});}try{const p=await transaction(async c=>{const r=await c.query('UPDATE millitop_tv.billing_projects SET title=$3,description=$4,internal_note=$5,status=$6,revision=revision+1,updated_at=now() WHERE id=$1 AND revision=$2 RETURNING *',[req.params.id,b.revision,b.title,b.description,b.internalNote,b.status]);if(!r.rowCount)throw new BillingError('Project changed. Refresh before editing.',409);await audit(c,req.admin.id,r.rows[0].account_id,'project.updated',{projectId:req.params.id,status:b.status});return r.rows[0];});res.json(publicProject(p));}catch(e){fail(res,next,e);}});
 app.post('/api/admin/billing/projects/:id/updates',async(req,res,next)=>{if(!admin(req,res))return;const b=req.body??{};if(!isUuid(req.params.id)||typeof b.body!=='string'||!b.body.trim()||b.body.length>12000||typeof b.customerVisible!=='boolean')return res.status(400).json({error:'Enter an update and choose its visibility.'});try{const item=await transaction(async c=>{const project=await c.query('SELECT id,account_id FROM millitop_tv.billing_projects WHERE id=$1 FOR SHARE',[req.params.id]);if(!project.rowCount)throw new BillingError('Project not found.',404);const id=randomUUID();const r=await c.query('INSERT INTO millitop_tv.billing_project_updates(id,project_id,body,customer_visible,created_by) VALUES($1,$2,$3,$4,$5) RETURNING id,body,customer_visible,created_at',[id,req.params.id,b.body.trim(),b.customerVisible,req.admin.id]);await audit(c,req.admin.id,project.rows[0].account_id,'project.note_added',{projectId:req.params.id,customerVisible:b.customerVisible});return r.rows[0];});res.status(201).json(item);}catch(e){fail(res,next,e);}});
 app.post('/api/device/account/unlock',limits.device,limits.unlock,async(req,res,next)=>{try{const context=await deviceContext(req,{unlockRequired:false});if(!context.account)throw new BillingError('No linked billing account.',404);if(context.account.access_mode!=='pin')return res.json({unlocked:true,token:null});if(!await verifyPin(req.body?.pin,context.account.pin_salt,context.account.pin_hash))throw new BillingError('Account PIN was not accepted.',403);const token=newBillingSession();await transaction(async c=>{const latest=await c.query('SELECT id FROM millitop_tv.billing_accounts WHERE id=$1 AND active AND revision=$2 FOR SHARE',[context.account.id,context.account.revision]);if(!latest.rowCount)throw new BillingError('Account changed. Retry.',409);await c.query('INSERT INTO millitop_tv.billing_sessions(token_hash,account_id,device_id,expires_at) VALUES($1,$2,$3,now()+interval \'15 minutes\')',[tokenHash(token),context.account.id,context.device.id]);await c.query("DELETE FROM millitop_tv.billing_sessions WHERE token_hash IN (SELECT token_hash FROM millitop_tv.billing_sessions WHERE expires_at<now()-interval '1 day' LIMIT 500)");});res.json({unlocked:true,token,expiresInSeconds:900});}catch(e){fail(res,next,e);}});
 app.post('/api/device/account',limits.device,async(req,res,next)=>{
  try{
   const context=await deviceContext(req);
   if(!context.account)return res.json({linked:false});
   if(context.locked)return res.json({linked:true,locked:true});
   const account=context.account;
   const projects=await pool.query(`SELECT id,title,description,status,revision,created_at,updated_at FROM millitop_tv.billing_projects WHERE account_id=$1 ORDER BY updated_at DESC LIMIT 200`,[account.id]);
   const ids=projects.rows.map(p=>p.id);
   const notes=ids.length?(await pool.query('SELECT id,project_id,body,created_at FROM millitop_tv.billing_project_updates WHERE project_id=ANY($1::uuid[]) AND customer_visible ORDER BY created_at DESC LIMIT 500',[ids])).rows:[];
   let financial;try{const [customer,invoices]=await Promise.all([square.customer(account.customer_id),square.invoices(account)]);financial={available:true,customer:customerSummary(customer),...invoices};}catch(e){financial={available:false,error:e instanceof BillingError?e.message:'Financial information could not be verified. No balance was inferred.'};}
   await recheck(req,account.id);
   res.json({linked:true,locked:false,accountId:account.id,householdName:context.device.household_name,financial,projects:projects.rows.map(p=>({...publicProject(p),updates:notes.filter(n=>n.project_id===p.id).map(n=>({id:n.id,body:n.body,createdAt:n.created_at}))}))});
  }catch(e){fail(res,next,e);}
 });
 app.post('/api/device/account/pay',limits.device,async(req,res,next)=>{try{const context=await ready(req);const result=await square.payUrl(context.account,squareId(req.body?.invoiceId));await recheck(req,context.account.id);res.json(result);}catch(e){fail(res,next,e);}});
 app.post('/api/device/account/payments',limits.device,async(req,res,next)=>{
  try{const context=await ready(req);
   if(req.body?.invoiceId){const result=await square.invoicePayments(context.account,squareId(req.body.invoiceId));await recheck(req,context.account.id);return res.json({...result,nextOffset:null});}
   const offset=req.body?.offset??0;if(!Number.isInteger(offset)||offset<0||offset>1000)throw new BillingError('Invalid history offset.',400);
   const invoices=await square.invoices(context.account),batch=invoices.invoices.slice(offset,offset+10),payments=[];let complete=invoices.complete;
   for(const item of batch){const result=await square.invoicePayments(context.account,item.id);payments.push(...result.payments);complete=complete&&result.complete;}
   const more=offset+batch.length<invoices.invoices.length;await recheck(req,context.account.id);
   res.json({payments:[...new Map(payments.map(p=>[p.id,p])).values()],complete:complete&&!more,nextOffset:more?offset+batch.length:null,checkedAt:new Date().toISOString(),scope:'invoice-linked payments'});
  }catch(e){fail(res,next,e);}
 });
}
