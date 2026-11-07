import { readFileSync,writeFileSync,renameSync,chmodSync,chownSync,statSync,existsSync,unlinkSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
let encoded;
try{
 encoded=readFileSync(0,'utf8');const data=JSON.parse(Buffer.from(encoded.trim(),'base64').toString('utf8'));
 if(!['sandbox','production'].includes(data.environment)||typeof data.token!=='string'||data.token.trim().length<10||data.token.length>8192||/\s/.test(data.token.trim()))throw Error('Invalid Square configuration.');
 const origin=data.environment==='production'?'https://connect.squareup.com':'https://connect.squareupsandbox.com';
 async function get(path){const response=await fetch(origin+path,{headers:{Authorization:'Bearer '+data.token.trim(),'Square-Version':'2026-09-16'},redirect:'error',signal:AbortSignal.timeout(20000)});if(!response.ok)throw Error('Square authorization/read scopes failed (HTTP '+response.status+'). No secret stored.');return response.json();}
 const [merchants,locations]=await Promise.all([get('/v2/merchants'),get('/v2/locations'),get('/v2/customers?limit=1')]);
 if(!Array.isArray(merchants.merchant)||merchants.merchant.length!==1||!Array.isArray(locations.locations)||locations.locations.length===0)throw Error('A single seller with an authorized location is required.');
 await get('/v2/invoices?location_id='+encodeURIComponent(locations.locations[0].id)+'&limit=1');
 const reference=statSync('/target/db_password');const mode=0o400|(reference.mode&0o040);
 for(const [name,value] of [['square_access_token',data.token.trim()+'\n'],['square_config.json',JSON.stringify({environment:data.environment,apiVersion:'2026-09-16'})+'\n']]){
  const target='/target/'+name,temp=target+'.tmp-'+randomUUID();
  try{writeFileSync(temp,value,{mode,flag:'wx'});chownSync(temp,reference.uid,reference.gid);chmodSync(temp,mode);renameSync(temp,target);}finally{if(existsSync(temp))unlinkSync(temp);}
 }
 console.log('SQUARE_SERVER_SECRET_CONFIGURED');console.log(JSON.stringify({environment:data.environment,merchantId:merchants.merchant[0].id,locationCount:locations.locations.length}));data.token='';encoded='';
}catch(e){console.error('SQUARE_CONFIGURATION_STOPPED: '+e.message);process.exitCode=1;}
