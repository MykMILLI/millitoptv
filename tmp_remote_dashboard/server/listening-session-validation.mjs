import {randomBytes} from 'node:crypto';
export const uuid = value => typeof value==='string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export function text(value,max,name,{empty=false}={}){if(typeof value!=='string'||value.includes('\0')||(!empty&&!value.trim())||value.length>max)throw new Error('Invalid '+name+'.');return value.trim();}
const codeAlphabet='ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export function joinCode(){const bytes=randomBytes(8);let out='';for(const b of bytes)out+=codeAlphabet[b%codeAlphabet.length];return out;}
export function validJoinCode(value){return typeof value==='string' && /^[A-Z0-9]{6,10}$/.test(value);}
export function trackRef(value){
 if(!value||typeof value!=='object')throw new Error('Invalid track.');
 const id=text(value.id,200,'track id');
 const title=text(value.title,200,'track title');
 const artist=typeof value.artist==='string'?text(value.artist,200,'artist',{empty:true}):'';
 const artworkUrl=typeof value.artworkUrl==='string'&&value.artworkUrl.length<=2048?value.artworkUrl:null;
 return {id,title,artist,artworkUrl};
}
export function nowPlayingBody(value){
 if(value==null)return {trackRef:null,positionMs:0,isPlaying:false};
 if(typeof value!=='object')throw new Error('Invalid playback state.');
 const positionMs=Number.isFinite(value.positionMs)&&value.positionMs>=0?Math.floor(value.positionMs):0;
 const isPlaying=typeof value.isPlaying==='boolean'?value.isPlaying:false;
 return {trackRef:value.track?trackRef(value.track):null,positionMs,isPlaying};
}
export function createBody(b){return {title:text(b?.title,120,'session title'),profileId:b?.profileId!=null?mustUuid(b.profileId,'host profile'):null,displayName:text(b?.displayName,60,'display name'),nowPlaying:nowPlayingBody(b?.nowPlaying)};}
export function joinBody(b){const code=typeof b?.joinCode==='string'?b.joinCode.toUpperCase():'';if(!validJoinCode(code))throw new Error('Enter a valid join code.');return {joinCode:code,profileId:b.profileId!=null?mustUuid(b.profileId,'profile'):null,displayName:text(b.displayName,60,'display name')};}
export function mustUuid(value,name){if(!uuid(value))throw new Error('Invalid '+name+'.');return value;}
export function messageBody(b){return {sessionId:mustUuid(b?.sessionId,'session'),body:text(b?.body,2000,'message')};}
export function requestBody(b){return {sessionId:mustUuid(b?.sessionId,'session'),track:trackRef(b?.track)};}
export function resolveBody(b){if(!['approve','reject'].includes(b?.action))throw new Error('Invalid action.');return {sessionId:mustUuid(b?.sessionId,'session'),requestId:mustUuid(b?.requestId,'request'),action:b.action};}
export function playbackBody(b){return {sessionId:mustUuid(b?.sessionId,'session'),nowPlaying:nowPlayingBody(b?.nowPlaying),advance:!!b?.advance};}
export function signalBody(b){
 if(!['join-announce','offer','answer','ice-candidate','leave'].includes(b?.kind))throw new Error('Invalid signal kind.');
 if(b.payload!=null&&(typeof b.payload!=='object'||Array.isArray(b.payload)))throw new Error('Invalid signal payload.');
 return {sessionId:mustUuid(b?.sessionId,'session'),toDeviceId:b.toDeviceId!=null?mustUuid(b.toDeviceId,'recipient device'):null,kind:b.kind,payload:b.payload??{}};
}
export function inviteBody(b){return {sessionId:mustUuid(b?.sessionId,'session'),email:text(b?.email,320,'email').toLowerCase()};}
export function cursorId(value){if(value==null||value==='')return 0;const n=Number(value);if(!Number.isSafeInteger(n)||n<0)throw new Error('Invalid page cursor.');return n;}
