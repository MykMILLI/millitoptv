import test from 'node:test';import assert from 'node:assert/strict';
import {uuid,joinCode,validJoinCode,trackRef,createBody,joinBody,messageBody,requestBody,signalBody,inviteBody} from './listening-session-validation.mjs';
import {registerListeningSessionRoutes} from './listening-session-routes.mjs';
const id='11111111-1111-4111-8111-111111111111',hh='22222222-2222-4222-8222-222222222222',other='33333333-3333-4333-8333-333333333333';

test('join codes are uppercase alphanumeric and avoid ambiguous characters',()=>{for(let i=0;i<20;i++){const code=joinCode();assert.ok(validJoinCode(code));assert.ok(!/[01OIL]/.test(code));}});
test('reject malformed join code',()=>assert.throws(()=>joinBody({joinCode:'bad',displayName:'A'})));
test('accept well-formed join code case-insensitively',()=>assert.equal(joinBody({joinCode:'abcdef23',displayName:'Sam'}).joinCode,'ABCDEF23'));
test('track reference requires id and title',()=>assert.throws(()=>trackRef({title:'Song'})));
test('track reference trims and bounds fields',()=>assert.deepEqual(trackRef({id:'t1',title:'Song',artist:'Artist'}),{id:'t1',title:'Song',artist:'Artist',artworkUrl:null}));
test('create body requires a title and display name',()=>assert.throws(()=>createBody({displayName:'Sam'})));
test('create body accepts optional now playing',()=>{const b=createBody({title:'Friday Night',displayName:'Sam',nowPlaying:{track:{id:'t1',title:'Song'},isPlaying:true}});assert.equal(b.title,'Friday Night');assert.equal(b.nowPlaying.isPlaying,true);});
test('message body validates session id and length',()=>{assert.throws(()=>messageBody({sessionId:'bad',body:'hi'}));assert.throws(()=>messageBody({sessionId:id,body:'a'.repeat(2001)}));assert.equal(messageBody({sessionId:id,body:'hi'}).body,'hi');});
test('song request requires a track',()=>assert.throws(()=>requestBody({sessionId:id})));
test('signal body rejects unknown kinds',()=>assert.throws(()=>signalBody({sessionId:id,kind:'video'})));
test('signal body allows broadcast with null recipient',()=>assert.equal(signalBody({sessionId:id,kind:'join-announce'}).toDeviceId,null));
test('invite body lower-cases email',()=>assert.equal(inviteBody({sessionId:id,email:'Friend@Example.com'}).email,'friend@example.com'));

function harness({auth=true,memberRole=null}={}){
 const handlers=new Map(),queries=[];
 const app={post:(p,...h)=>handlers.set('POST '+p,h.at(-1))};
 const c={release(){},async query(sql,args){
  queries.push({sql,args});
  if(sql.includes('device_credentials'))return {rowCount:auth?1:0,rows:auth?[{id,household_id:hh}]:[]};
  if(sql.includes('FROM millitop_tv.listening_sessions')&&sql.includes("status='active'"))return {rowCount:1,rows:[{id,host_household_id:hh,host_device_id:memberRole==='host'?id:other,host_profile_id:null,title:'Party',join_code:'ABCDEF23',status:'active',now_playing:{},now_playing_token:'t1',revision:1}]};
  if(sql.includes('FROM millitop_tv.listening_session_members')&&sql.includes('left_at IS NULL')&&!sql.includes('count'))return {rowCount:memberRole?1:0,rows:memberRole?[{session_id:id,device_id:id,display_name:'Sam',role:memberRole}]:[]};
  if(sql.includes('count(*)::int AS total'))return {rowCount:1,rows:[{total:0}]};
  return {rowCount:0,rows:[]};
 }};
 registerListeningSessionRoutes(app,{connect:async()=>c},(req,res,next)=>next());
 return {handlers,queries};
}
function response(){return {code:200,value:null,status(v){this.code=v;return this;},json(v){this.value=v;return this;}};}
const authHeader=()=>['Bearer','a'.repeat(43)].join(' ');

test('missing device credential denies chat',async()=>{
 const h=harness({auth:false}),res=response();
 await h.handlers.get('POST /api/device/listening-sessions/messages')({body:{sessionId:id,body:'hi'},get:()=>''},res,()=>assert.fail());
 assert.equal(res.code,401);
});
test('non-member cannot post a message',async()=>{
 const h=harness({memberRole:null}),res=response();
 await h.handlers.get('POST /api/device/listening-sessions/messages')({body:{sessionId:id,body:'hi'},get:()=>authHeader()},res,()=>assert.fail());
 assert.equal(res.code,403);
});
test('member can post a message',async()=>{
 const h=harness({memberRole:'guest'}),res=response();
 await h.handlers.get('POST /api/device/listening-sessions/messages')({body:{sessionId:id,body:'hi'},get:()=>authHeader()},res,()=>assert.fail());
 assert.equal(res.code,201);
 assert.equal(res.value.accepted,true);
});
test('only the host can push playback updates',async()=>{
 const h=harness({memberRole:'guest'}),res=response();
 await h.handlers.get('POST /api/device/listening-sessions/playback')({body:{sessionId:id,nowPlaying:{track:{id:'t1',title:'Song'}}},get:()=>authHeader()},res,()=>assert.fail());
 assert.equal(res.code,403);
});
test('query failure rolls back and does not return success',async()=>{
 const h=harness({memberRole:'guest'}),res=response();
 const broken={release(){},async query(sql,args){if(sql.includes('INSERT INTO millitop_tv.listening_session_messages'))throw new Error('database outage');return h.queries.length?{rowCount:1,rows:[{id,host_household_id:hh,host_device_id:other,title:'Party',join_code:'ABCDEF23',status:'active',now_playing:{},now_playing_token:'t1',revision:1,display_name:'Sam',role:'guest'}]}:{rowCount:1,rows:[{id,household_id:hh}]};}};
 const app2={post:(p,...hh)=>app2.handlers.set(p,hh.at(-1)),handlers:new Map()};
 app2.post=(p,...hh)=>app2.handlers.set('POST '+p,hh.at(-1));
 registerListeningSessionRoutes(app2,{connect:async()=>broken},(req,res,next)=>next());
 let failed=false;
 await app2.handlers.get('POST /api/device/listening-sessions/messages')({body:{sessionId:id,body:'hi'},get:()=>authHeader()},res,()=>{failed=true;});
 assert.ok(failed);
 assert.equal(res.value,null);
});
