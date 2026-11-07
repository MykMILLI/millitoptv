import test from 'node:test';import assert from 'node:assert/strict';
import { SquareAccounts,BillingError,invoiceSummary,summarizeBalances,checkoutUrl,customerSummary } from './square-accounts.mjs';
import { hashPin,verifyPin,tokenHash,publicProject,validateProject } from './billing-security.mjs';
import { registerBillingRoutes } from './billing-routes.mjs';
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222';
const HH_A='33333333-3333-4333-8333-333333333333',HH_B='44444444-4444-4444-8444-444444444444';
const DA='55555555-5555-4555-8555-555555555555',DB='66666666-6666-4666-8666-666666666666';
const TOK_A='mtv_'+'a'.repeat(43),TOK_B='mtv_'+'b'.repeat(43);
function invoice(customer='CUST-A',id='INV-A',amount=10000,paid=2500,status='PARTIALLY_PAID'){
 return {id,primary_recipient:{customer_id:customer},location_id:'LOC',order_id:id==='INV-A'?'ORDER-A':'ORDER-B',invoice_number:id,title:'Service invoice',status,updated_at:'2026-10-24T10:00:00Z',public_url:'https://squareupsandbox.com/pay-invoice/'+id,
  payment_requests:[{computed_amount_money:{amount,currency:'USD'},total_completed_amount_money:{amount:paid,currency:'USD'},due_date:'2026-11-01'}]};
}
function squareMock({foreignSearch=false,pending=false,error=false,large=false,merchant='SELLER'}={}){
 const calls=[];
 const client=new SquareAccounts({configuration:()=>({environment:'sandbox',token:'TEST_TOKEN'}),fetchImpl:async(url,options)=>{
  calls.push({url,method:options.method,body:options.body});if(error)return new Response('{}',{status:503});
  const path=new URL(url).pathname;let data;
  if(path==='/v2/merchants')data={merchant:[{id:merchant}]};
  else if(path==='/v2/locations')data={locations:[{id:'LOC',name:'Test',timezone:'America/New_York'}]};
  else if(path==='/v2/customers/CUST-A')data={customer:{id:'CUST-A',given_name:'Alice',email_address:'alice@example.invalid',note:'PRIVATE SELLER NOTE'}};
  else if(path==='/v2/customers/CUST-B')data={customer:{id:'CUST-B',given_name:'Bob'}};
  else if(path==='/v2/invoices/search'){
   const customer=JSON.parse(options.body).query.filter.customer_ids[0];data={invoices:foreignSearch?[invoice(),invoice('CUST-B','INV-B')]:[invoice(customer,customer==='CUST-A'?'INV-A':'INV-B',10000,pending?0:2500,pending?'PAYMENT_PENDING':'PARTIALLY_PAID')],...(large?{cursor:'more'}:{})};
  }else if(path==='/v2/invoices/INV-A')data={invoice:invoice()};
  else if(path==='/v2/invoices/INV-B')data={invoice:invoice('CUST-B','INV-B')};
  else if(path==='/v2/orders/ORDER-A')data={order:{id:'ORDER-A',tenders:[{id:'PAY-A'}]}};
  else if(path==='/v2/payments/PAY-A')data={payment:{id:'PAY-A',order_id:'ORDER-A',customer_id:'DIFFERENT-PAYER',buyer_email_address:'private@example.invalid',card_details:{card:{last_4:'9999'}},status:'COMPLETED',total_money:{amount:2500,currency:'USD'},created_at:'2026-10-24T10:00:00Z'}};
  else return new Response('{}',{status:404});
  return new Response(JSON.stringify(data),{status:200});
 }});return {client,calls};
}
const account={id:A,household_id:HH_A,merchant_id:'SELLER',environment:'sandbox',customer_id:'CUST-A',access_mode:'household',active:true,revision:1};
test('invoice balance uses exact minor-unit arithmetic and partial payments',()=>{const value=invoiceSummary(invoice(),'CUST-A');assert.equal(value.remainingMinor,'7500');assert.equal(value.totalMinor,'10000');assert.equal(value.canPay,true);});
test('currencies are not combined and incomplete totals are not shown as account balances',()=>{const a=invoiceSummary(invoice(),'CUST-A');assert.equal(summarizeBalances([a],false),null);const b={...a,currency:'CAD'};assert.equal(summarizeBalances([a,b],true).length,2);});
test('pending payments are separated and cannot be paid twice through this endpoint',()=>{const value=invoiceSummary(invoice('CUST-A','INV-A',10000,0,'PAYMENT_PENDING'),'CUST-A');assert.equal(value.canPay,false);assert.equal(summarizeBalances([value],true)[0].pendingMinor,'10000');});
test('draft invoices do not leak to the customer portal',()=>assert.equal(invoiceSummary(invoice('CUST-A','INV-A',10000,0,'DRAFT'),'CUST-A'),null));
test('refund/cancel states do not reopen an invoice balance',()=>{for(const status of ['PAID','REFUNDED','PARTIALLY_REFUNDED','CANCELED'])assert.equal(invoiceSummary(invoice('CUST-A','INV-A',10000,0,status),'CUST-A').remainingMinor,'0');});
test('unsafe or uncertain money is rejected rather than rounded',()=>{const value=invoice();value.payment_requests[0].computed_amount_money.amount=Number.MAX_SAFE_INTEGER+1;assert.throws(()=>invoiceSummary(value,'CUST-A'),BillingError);});
test('only verified Square invoice checkout hosts are opened',()=>{assert.match(checkoutUrl(invoice(),'CUST-A','sandbox'),/^https:\/\/squareupsandbox\.com\/pay-invoice\//);for(const url of ['https://evil.invalid/pay-invoice/a','https://squareupsandbox.com.evil.invalid/pay-invoice/a','javascript:alert(1)','http://squareupsandbox.com/pay-invoice/a'])assert.throws(()=>checkoutUrl({...invoice(),public_url:url},'CUST-A','sandbox'),BillingError);});
test('customer and project DTOs never contain internal notes or PIN hashes',()=>{assert.ok(!JSON.stringify(customerSummary({given_name:'A',note:'secret',id:'CUST-A'})).includes('secret'));const p=publicProject({id:A,title:'Install',description:'Public',internal_note:'ADMIN SECRET',pin_hash:'hash',status:'in_progress'});assert.ok(!JSON.stringify(p).includes('ADMIN SECRET'));assert.equal(p.closed,false);assert.equal(publicProject({...p,status:'completed'}).closed,true);});
test('PIN verification uses server hashes and rejects invalid values',async()=>{const pin=await hashPin('123456');assert.equal(await verifyPin('123456',pin.salt,pin.hash),true);assert.equal(await verifyPin('654321',pin.salt,pin.hash),false);assert.equal(await verifyPin('bad',pin.salt,pin.hash),false);await assert.rejects(()=>hashPin('123'));});
test('project validation requires an explicit supported status and revision',()=>{const base={title:'Project',description:'Public',internalNote:'Private',status:'planned'};assert.equal(validateProject(base).status,'planned');assert.throws(()=>validateProject({...base,status:'paid'}));assert.throws(()=>validateProject(base,{edit:true}));});
test('Square invoice search is constrained to the bound customer and location',async()=>{const {client,calls}=squareMock();const result=await client.invoices(account);assert.equal(result.invoices.length,1);const query=JSON.parse(calls.find(c=>c.url.endsWith('/v2/invoices/search')).body).query;assert.deepEqual(query.filter,{location_ids:['LOC'],customer_ids:['CUST-A']});});
test('foreign invoices in an upstream response fail closed',async()=>{await assert.rejects(()=>squareMock({foreignSearch:true}).client.invoices(account),BillingError);});
test('seller/environment changes cannot reuse a previous customer link',async()=>{await assert.rejects(()=>squareMock({merchant:'OTHER'}).client.invoices(account),BillingError);});
test('invoice payment links are verified against the account even with a guessed invoice ID',async()=>{await assert.rejects(()=>squareMock().client.payUrl(account,'INV-B'),BillingError);});
test('payment history follows verified invoice order and omits unrelated payer/card data',async()=>{const result=await squareMock().client.invoicePayments(account,'INV-A');assert.equal(result.payments[0].amount.amountMinor,'2500');const text=JSON.stringify(result);assert.ok(!text.includes('DIFFERENT-PAYER')&&!text.includes('private@example.invalid')&&!text.includes('9999'));});
test('pagination cap returns unknown total instead of an understated account balance',async()=>{const result=await squareMock({large:true}).client.invoices(account);assert.equal(result.complete,false);assert.equal(result.balances,null);});
test('Square client refuses payment/refund or invoice-write operations',async()=>{const {client,calls}=squareMock();await assert.rejects(()=>client.call('POST','/v2/payments',{}),BillingError);await assert.rejects(()=>client.call('POST','/v2/refunds',{}),BillingError);assert.equal(calls.length,0);});
function harness({pinAccount=false,locked=false,financialError=false}={}){
 const handlers=new Map(),queries=[];let committed=0;const accounts=[{...account,pin_hash:'HASH-SECRET',pin_salt:'SALT-SECRET',access_mode:pinAccount?'pin':'household'},{...account,id:B,household_id:HH_B,customer_id:'CUST-B',access_mode:pinAccount?'pin':'household'}];
 const devices=new Map([[tokenHash(TOK_A),{id:DA,household_id:HH_A,household_name:'Home A'}],[tokenHash(TOK_B),{id:DB,household_id:HH_B,household_name:'Home B'}]]);
 const c={query:async(sql,args=[])=>{queries.push({sql,args});if(sql==='COMMIT')committed++;
  if(sql.includes('FROM millitop_tv.device_credentials')){const d=devices.get(args[0]);return {rowCount:d?1:0,rows:d?[d]:[]};}
  if(sql.includes('SELECT * FROM millitop_tv.billing_accounts WHERE household_id')){const a=accounts.find(a=>a.household_id===args[0]&&a.active);return {rowCount:a?1:0,rows:a?[a]:[]};}
  if(sql.includes('SELECT token_hash FROM millitop_tv.billing_sessions'))return {rowCount:!locked&&args[1]===A&&args[2]===DA?1:0,rows:!locked&&args[1]===A&&args[2]===DA?[{token_hash:args[0]}]:[]};
  if(sql.includes('FROM millitop_tv.billing_projects WHERE account_id'))return {rowCount:1,rows:[{id:args[0]===A?A:B,title:args[0]===A?'A PROJECT':'B PROJECT',description:'Public',status:'in_progress',internal_note:'HIDDEN INTERNAL',created_at:'now',updated_at:'now',revision:1}]};
  if(sql.includes('FROM millitop_tv.billing_project_updates'))return {rowCount:1,rows:[{id:A,project_id:args[0][0],body:'Public progress',created_at:'now'}]};
  return {rowCount:0,rows:[]};},release(){}};
 const app={get:(path,...h)=>handlers.set('GET '+path,h.at(-1)),post:(path,...h)=>handlers.set('POST '+path,h.at(-1))};
 const square=squareMock({error:financialError}).client;registerBillingRoutes(app,{connect:async()=>c,query:c.query},{device:(_q,_r,next)=>next(),unlock:(_q,_r,next)=>next()},{square});
 const res={code:200,body:null,status(v){this.code=v;return this;},json(v){this.body=v;return this;}};
 const req=(token=TOK_A,body={})=>({body,params:{},query:{},get:key=>key==='authorization'?'Bearer '+token:key==='x-millitop-billing-session'?'s'.repeat(43):undefined});
 return {handlers,queries,res,req,accounts,square,get committed(){return committed;}};
}
test('account endpoint requires a device credential',async()=>{const h=harness();await h.handlers.get('POST /api/device/account')(h.req('invalid'),h.res,e=>{throw e;});assert.equal(h.res.code,401);assert.equal(h.res.body.linked,undefined);});
test('household A cannot select household B or customer B using request fields',async()=>{const h=harness();await h.handlers.get('POST /api/device/account')(h.req(TOK_A,{householdId:HH_B,customerId:'CUST-B'}),h.res,e=>{throw e;});assert.equal(h.res.code,200);const text=JSON.stringify(h.res.body);assert.ok(text.includes('A PROJECT'));assert.ok(!text.includes('B PROJECT')&&!text.includes('HIDDEN INTERNAL')&&!text.includes('HASH-SECRET'));assert.equal(h.res.body.financial.customer.name,'Alice');});
test('a second enrolled household receives its own project/customer data',async()=>{const h=harness();await h.handlers.get('POST /api/device/account')(h.req(TOK_B),h.res,e=>{throw e;});assert.equal(h.res.body.financial.customer.name,'Bob');assert.ok(JSON.stringify(h.res.body).includes('B PROJECT'));assert.ok(!JSON.stringify(h.res.body).includes('A PROJECT'));});
test('PIN-protected accounts reveal no financial/project data while locked',async()=>{const h=harness({pinAccount:true,locked:true});await h.handlers.get('POST /api/device/account')(h.req(),h.res,e=>{throw e;});assert.deepEqual(h.res.body,{linked:true,locked:true});});
test('Square outage preserves project visibility without fabricating a zero balance',async()=>{const h=harness({financialError:true});await h.handlers.get('POST /api/device/account')(h.req(),h.res,e=>{throw e;});assert.equal(h.res.body.financial.available,false);assert.equal(h.res.body.financial.balances,undefined);assert.equal(h.res.body.projects.length,1);});
test('foreign invoice IDs are denied by the device pay endpoint',async()=>{const h=harness();await h.handlers.get('POST /api/device/account/pay')(h.req(TOK_A,{invoiceId:'INV-B'}),h.res,e=>{throw e;});assert.equal(h.res.code,404);assert.equal(h.res.body.url,undefined);});
test('admin billing endpoints do not trust unauthenticated calls',async()=>{const h=harness();await h.handlers.get('GET /api/admin/billing/accounts')({},h.res,e=>{throw e;});assert.equal(h.res.code,401);assert.equal(h.queries.length,0);});

test('billing unlock sessions cannot be reused across household devices',async()=>{const h=harness({pinAccount:true});await h.handlers.get('POST /api/device/account')(h.req(TOK_B),h.res,e=>{throw e;});assert.deepEqual(h.res.body,{linked:true,locked:true});});
test('an account unlinked during Square retrieval is rechecked before any data is sent',async()=>{const h=harness();const original=h.square.invoices.bind(h.square);h.square.invoices=async a=>{const data=await original(a);h.accounts[0].active=false;return data;};await h.handlers.get('POST /api/device/account')(h.req(TOK_A),h.res,e=>{throw e;});assert.equal(h.res.code,403);assert.equal(h.res.body.financial,undefined);});
