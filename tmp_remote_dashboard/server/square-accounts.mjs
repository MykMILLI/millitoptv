import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
export class BillingError extends Error {constructor(message,status=503){super(message);this.status=status;}}
export const squareVersion='2026-09-16';
export function loadSquareConfig(){
 try{
  const config=JSON.parse(readFileSync('/run/secrets/square_config.json','utf8'));
  const token=readFileSync('/run/secrets/square_access_token','utf8').trim();
  if(!['sandbox','production'].includes(config.environment)||!token||token.length>8192)throw Error();
  return {environment:config.environment,token};
 }catch{throw new BillingError('Square is not configured on the server. Contact support.');}
}
export function squareId(value){if(typeof value!=='string'||!value||value.length>192||!/^[A-Za-z0-9:_-]+$/.test(value))throw new BillingError('Invalid Square identifier.',400);return value;}
export function moneyValue(value){
 if(!value||!Number.isSafeInteger(value.amount)||typeof value.currency!=='string'||!/^[A-Z]{3}$/.test(value.currency))throw new BillingError('Square returned an unsupported money value. No balance was inferred.');
 return {amountMinor:String(value.amount),currency:value.currency};
}
const buyerStatuses=new Set(['UNPAID','PARTIALLY_PAID','PAID','PAYMENT_PENDING','PARTIALLY_REFUNDED','REFUNDED','CANCELED']);
export function invoiceForCustomer(invoice,customerId){
 if(invoice?.primary_recipient?.customer_id!==customerId)throw new BillingError('Invoice ownership could not be verified.',404);
 return invoice;
}
export function checkoutUrl(invoice,customerId,environment){
 invoiceForCustomer(invoice,customerId);
 if(!['UNPAID','PARTIALLY_PAID'].includes(invoice.status))throw new BillingError('This invoice is not currently payable. Refresh its status.',409);
 let url;try{url=new URL(invoice.public_url);}catch{throw new BillingError('Square has not supplied a payment link for this invoice.',409);}
 const host=environment==='production'?'squareup.com':'squareupsandbox.com';
 if(url.protocol!=='https:'||url.username||url.password||!(url.hostname===host||url.hostname.endsWith('.'+host))||!url.pathname.startsWith('/pay-invoice/'))throw new BillingError('Square payment URL could not be verified. Contact support.');
 return url.href;
}
export function invoiceSummary(invoice,customerId){
 invoiceForCustomer(invoice,customerId);
 if(!buyerStatuses.has(invoice.status))return null;
 let total=0n,completed=0n,currency=null;
 const requests=invoice.payment_requests;
 if(!Array.isArray(requests)||!requests.length)throw new BillingError('Invoice totals are unavailable. No balance was inferred.');
 const dueDates=[];
 for(const request of requests){
  const amount=moneyValue(request.computed_amount_money);
  const paid=request.total_completed_amount_money?moneyValue(request.total_completed_amount_money):{amountMinor:'0',currency:amount.currency};
  if(paid.currency!==amount.currency||(currency&&currency!==amount.currency))throw new BillingError('Mixed invoice currencies could not be summarized.');
  currency=amount.currency;total+=BigInt(amount.amountMinor);completed+=BigInt(paid.amountMinor);
  if(request.due_date&&BigInt(amount.amountMinor)>BigInt(paid.amountMinor))dueDates.push(request.due_date);
 }
 const remaining=['UNPAID','PARTIALLY_PAID','PAYMENT_PENDING'].includes(invoice.status)?(total>completed?total-completed:0n):0n;
 return {id:invoice.id,number:invoice.invoice_number??'',title:invoice.title??'Invoice',description:invoice.description??'',status:invoice.status,
  currency,totalMinor:String(total),completedMinor:String(completed),remainingMinor:String(remaining),
  dueDate:dueDates.sort()[0]??null,updatedAt:invoice.updated_at??null,
  canPay:remaining>0n&&['UNPAID','PARTIALLY_PAID'].includes(invoice.status)&&typeof invoice.public_url==='string'};
}
export function summarizeBalances(invoices,complete){
 if(!complete)return null;
 const totals=new Map();
 for(const invoice of invoices){const old=totals.get(invoice.currency)??{due:0n,pending:0n};if(invoice.status==='PAYMENT_PENDING')old.pending+=BigInt(invoice.remainingMinor);else old.due+=BigInt(invoice.remainingMinor);totals.set(invoice.currency,old);}
 return [...totals].map(([currency,value])=>({currency,dueMinor:String(value.due),pendingMinor:String(value.pending)}));
}
export function customerSummary(customer){return {name:customer.company_name||[customer.given_name,customer.family_name].filter(Boolean).join(' ')||'Customer',email:customer.email_address??null,phone:customer.phone_number??null,
 address:customer.address?{line1:customer.address.address_line_1??'',line2:customer.address.address_line_2??'',city:customer.address.locality??'',region:customer.address.administrative_district_level_1??'',postalCode:customer.address.postal_code??'',country:customer.address.country??''}:null};}
export class SquareAccounts {
 constructor({fetchImpl=fetch,configuration=loadSquareConfig}={}){this.fetch=fetchImpl;this.configuration=configuration;this.identityCache=null;}
 async call(method,path,body){
  if(!((method==='GET'&&/^\/v2\/(merchants|locations|customers|invoices|orders|payments)(?:\/[^?]+)?(?:\?.*)?$/.test(path))||(method==='POST'&&path==='/v2/invoices/search')))throw new BillingError('Square operation is outside this read-only integration.',400);
  const config=this.configuration();const origin=config.environment==='production'?'https://connect.squareup.com':'https://connect.squareupsandbox.com';
  let response;try{response=await this.fetch(origin+path,{method,headers:{Authorization:'Bearer '+config.token,'Square-Version':squareVersion,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(20000),redirect:'error'});}catch{throw new BillingError('Square could not be reached. No financial state was inferred.');}
  if(!response.ok)throw new BillingError(response.status===401||response.status===403?'Square authorization/scopes need attention.':'Square temporarily could not complete the account request.');
  const text=await response.text();if(text.length>8388608)throw new BillingError('Square response exceeded the safe limit.');
  try{return JSON.parse(text);}catch{throw new BillingError('Square returned an invalid account response.');}
 }
 async identity(){
  const config=this.configuration(),key=createHash('sha256').update(config.environment+'|'+config.token).digest('hex');
  if(this.identityCache?.key===key&&this.identityCache.until>Date.now())return this.identityCache.value;
  const [merchants,locations]=await Promise.all([this.call('GET','/v2/merchants'),this.call('GET','/v2/locations')]);
  if(!Array.isArray(merchants.merchant)||merchants.merchant.length!==1||merchants.cursor||!Array.isArray(locations.locations)||locations.locations.length===0)throw new BillingError('This integration requires one authorized Square seller.');
  const value={merchantId:merchants.merchant[0].id,environment:config.environment,locations:locations.locations.map(l=>({id:l.id,name:l.name,status:l.status,timezone:l.timezone??'UTC'}))};
  this.identityCache={key,value,until:Date.now()+30000};return value;
 }
 async customer(id){const result=await this.call('GET','/v2/customers/'+encodeURIComponent(squareId(id)));if(!result.customer||result.customer.id!==id||result.customer.is_deleted===true)throw new BillingError('Square customer could not be verified.',404);return result.customer;}
 async customers(cursor){
  if(cursor&&(typeof cursor!=='string'||cursor.length>2048))throw new BillingError('Invalid customer cursor.',400);
  const result=await this.call('GET','/v2/customers?limit=100'+(cursor?'&cursor='+encodeURIComponent(cursor):''));
  return {customers:(result.customers??[]).map(c=>({id:c.id,...customerSummary(c)})),cursor:result.cursor??null};
 }
 async assertBinding(account){const identity=await this.identity();if(identity.merchantId!==account.merchant_id||identity.environment!==account.environment)throw new BillingError('Square seller/environment differs from this account link. Contact support.');return identity;}
 async invoices(account){
  const identity=await this.assertBinding(account),items=[];let complete=true,pages=0;
  const clock=Date.now();
  for(const location of identity.locations){
   let cursor;
   do{
    if(pages>=20||items.length>=1000||Date.now()-clock>45000){complete=false;break;}
    const response=await this.call('POST','/v2/invoices/search',{query:{filter:{location_ids:[location.id],customer_ids:[account.customer_id]},sort:{field:'INVOICE_SORT_DATE',order:'DESC'}},limit:100,...(cursor?{cursor}:{})});pages++;
    for(const invoice of response.invoices??[]){invoiceForCustomer(invoice,account.customer_id);if(invoice.location_id!==location.id)throw new BillingError('Invoice location could not be verified.');const item=invoiceSummary(invoice,account.customer_id);if(item)items.push(item);}
    cursor=response.cursor;
   }while(cursor);
   if(!complete)break;
  }
  items.sort((a,b)=>(b.updatedAt??'').localeCompare(a.updatedAt??''));
  return {invoices:items,complete,balances:summarizeBalances(items,complete),checkedAt:new Date().toISOString()};
 }
 async invoice(account,id){const identity=await this.assertBinding(account);const data=await this.call('GET','/v2/invoices/'+encodeURIComponent(squareId(id)));const invoice=invoiceForCustomer(data.invoice,account.customer_id);if(invoice.id!==id)throw new BillingError('Requested invoice could not be verified.',404);if(!identity.locations.some(l=>l.id===invoice.location_id))throw new BillingError('Invoice location is outside the authorized seller.',404);return invoice;}
 async payUrl(account,id){const invoice=await this.invoice(account,id);const summary=invoiceSummary(invoice,account.customer_id);if(!summary?.canPay)throw new BillingError('Invoice is not currently payable.',409);return {url:checkoutUrl(invoice,account.customer_id,account.environment),invoiceId:invoice.id};}
 async invoicePayments(account,id){
  const invoice=await this.invoice(account,id);if(!invoice.order_id)return {payments:[],complete:false};
  const order=(await this.call('GET','/v2/orders/'+encodeURIComponent(squareId(invoice.order_id)))).order;
  if(!order||order.id!==invoice.order_id)throw new BillingError('Invoice order could not be verified.');
  const payments=[];let complete=true;
  for(const tender of (order.tenders??[]).slice(0,50)){
   const paymentId=tender.payment_id??tender.id;if(!paymentId){complete=false;continue;}
   try{
    const p=(await this.call('GET','/v2/payments/'+encodeURIComponent(squareId(paymentId)))).payment;
    if(!p||p.order_id!==invoice.order_id)throw new BillingError('Payment order could not be verified.');
    payments.push({id:p.id,invoiceId:invoice.id,status:p.status,createdAt:p.created_at??null,updatedAt:p.updated_at??null,
     amount:moneyValue(p.total_money??p.amount_money),refunded:p.refunded_money?moneyValue(p.refunded_money):null});
   }catch{complete=false;}
  }
  if((order.tenders??[]).length>50)complete=false;
  return {payments,complete,checkedAt:new Date().toISOString()};
 }
}
