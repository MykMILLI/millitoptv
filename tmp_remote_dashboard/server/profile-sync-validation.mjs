import {createHash} from 'node:crypto';
import {inflateSync} from 'node:zlib';
import {validateWebApp,validateWebUrl,isUuid} from './web-app-validation.mjs';
export const kinds=new Set(['profile','shortcut','favorite','preference']);
export function validRevision(v){if(!Number.isSafeInteger(v)||v<0)throw new Error('Invalid revision.');return v;}
function object(v){if(!v||typeof v!=='object'||Array.isArray(v))throw new Error('Expected an object.');return v;}
function fields(v,allowed){object(v);if(Object.keys(v).some(k=>!allowed.includes(k)))throw new Error('Unsupported data field.');}
function clean(v,max){if(typeof v!=='string'||!v.trim()||v.length>max||/[\x00-\x1f\x7f]/.test(v))throw new Error('Invalid text.');return v.trim();}
function crc(buf){let c=0xffffffff;for(const b of buf){c^=b;for(let n=0;n<8;n++)c=(c>>>1)^((c&1)?0xedb88320:0);}return (c^0xffffffff)>>>0;}
export function validateAvatar(encoded){if(typeof encoded!=='string'||encoded.length>699052||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded))throw new Error('Invalid avatar encoding.');
 const png=Buffer.from(encoded,'base64');if(png.length>524288||png.length<57||!png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))throw new Error('Use a small static PNG avatar.');let pos=8,width,height,channels;const idat=[];let chunks=0,ended=false;
 while(pos<png.length){if(++chunks>2000||pos+12>png.length)throw new Error('Invalid PNG structure.');const size=png.readUInt32BE(pos);if(size>524288||pos+size+12>png.length)throw new Error('Invalid PNG chunk.');const type=png.toString('ascii',pos+4,pos+8),data=png.subarray(pos+8,pos+8+size);if(crc(png.subarray(pos+4,pos+8+size))!==png.readUInt32BE(pos+8+size))throw new Error('PNG checksum failed.');
  if(chunks===1){if(type!=='IHDR'||size!==13)throw new Error('Invalid PNG header.');width=data.readUInt32BE(0);height=data.readUInt32BE(4);channels=data[9]===6?4:data[9]===2?3:0;if(!width||!height||width>512||height>512||!channels||data[8]!==8||data[10]!==0||data[11]!==0||data[12]!==0)throw new Error('Use non-interlaced RGB/RGBA PNG up to 512px.');}
  if((chunks>1&&type==='IHDR')||!['IHDR','IDAT','IEND','sRGB','gAMA','cHRM','sBIT','pHYs'].includes(type))throw new Error('Unsupported PNG metadata or animation.');if(type==='sRGB'&&size!==1||type==='gAMA'&&size!==4||type==='cHRM'&&size!==32||type==='pHYs'&&size!==9||type==='sBIT'&&size!==channels)throw new Error('Invalid PNG metadata.');if(type==='IDAT')idat.push(data);if(type==='IEND'){if(size!==0||pos+12!==png.length)throw new Error('Invalid PNG end.');ended=true;}pos+=size+12;
 }
 if(!ended||!idat.length)throw new Error('Incomplete PNG.');const expected=(width*channels+1)*height;const decoded=inflateSync(Buffer.concat(idat),{maxOutputLength:expected+1});if(decoded.length!==expected)throw new Error('PNG dimensions differ from data.');for(let row=0;row<height;row++)if(decoded[row*(width*channels+1)]>4)throw new Error('Invalid PNG filter.');return {png,digest:createHash('sha256').update(png).digest('hex')};
}
export function normalizeOperation(raw,{inspectAvatar=true}={}){fields(raw,['operationId','profileId','kind','key','baseRevision','deleted','data']);if(!isUuid(raw.operationId)||!isUuid(raw.profileId)||!kinds.has(raw.kind)||typeof raw.deleted!=='boolean')throw new Error('Invalid operation identity.');const op={operationId:raw.operationId.toLowerCase(),profileId:raw.profileId.toLowerCase(),kind:raw.kind,key:clean(raw.key,240),baseRevision:validRevision(raw.baseRevision),deleted:raw.deleted,data:null};
 if(op.kind==='profile'&&op.key!=='profile')throw new Error('Invalid profile key.');
 if(op.kind==='shortcut'&&!(op.key==='emby'||op.key==='jellyfin'||op.key.startsWith('local:')&&isUuid(op.key.slice(6))))throw new Error('Only portable web shortcuts are supported in this protocol.');
 if(isUuid(op.key)){op.key=op.key.toLowerCase();}if(op.kind==='shortcut'&&op.key.startsWith('local:'))op.key=op.key.toLowerCase();
 if(op.kind==='favorite'&&!/^tmdb:(movie|tv):[1-9]\d*$/.test(op.key)&&!isUuid(op.key))throw new Error('Invalid favorite ID.');
 if(op.kind==='preference'&&!['home.familyMoments','home.appOrder','home.sleepUrl','gallery.options'].includes(op.key))throw new Error('Unsupported portable preference.');
 if(op.deleted){if(raw.data!=null)throw new Error('Deletion must not include data.');return op;}
 if(op.kind==='profile'){fields(raw.data,['name','avatarPng']);op.data={name:clean(raw.data.name,40)};if(Object.hasOwn(raw.data,'avatarPng')){if(raw.data.avatarPng!==null){if(inspectAvatar)validateAvatar(raw.data.avatarPng);else if(typeof raw.data.avatarPng!=='string'||raw.data.avatarPng.length>699052)throw new Error('Avatar encoding too large.');}op.data.avatarPng=raw.data.avatarPng;}}
 if(op.kind==='shortcut'){fields(raw.data,['title','url','icon','enabled']);op.data=validateWebApp(raw.data);const u=new URL(op.data.url);if(['localhost','127.0.0.1','[::1]'].includes(u.hostname.toLowerCase()))throw new Error('Loopback shortcuts must stay device-local.');}
 if(op.kind==='favorite'){fields(raw.data,['title']);op.data={title:clean(raw.data.title,160)};}
 if(op.kind==='preference'){fields(raw.data,['value']);const v=raw.data.value;if(op.key==='home.familyMoments'){if(typeof v!=='boolean')throw new Error('Expected a boolean.');op.data={value:v};}
  if(op.key==='home.appOrder'){if(!Array.isArray(v)||v.length>300||new Set(v).size!==v.length||v.some(x=>typeof x!=='string'||x.length>200||!/^((web|native):)[A-Za-z0-9:._-]+$/.test(x)))throw new Error('Invalid app ordering.');op.data={value:v};}
  if(op.key==='home.sleepUrl'){const url=validateWebUrl(v);if(new URL(url).protocol!=='https:')throw new Error('Sleep Sounds requires HTTPS.');op.data={value:url};}
  if(op.key==='gallery.options'){fields(v,['seconds','videos','shuffle','repeat','sound','limitVideos']);if(!Number.isInteger(v.seconds)||v.seconds<3||v.seconds>300||['videos','shuffle','repeat','sound','limitVideos'].some(k=>typeof v[k]!=='boolean'))throw new Error('Invalid portable slideshow settings.');op.data={value:{seconds:v.seconds,videos:v.videos,shuffle:v.shuffle,repeat:v.repeat,sound:v.sound,limitVideos:v.limitVideos}};}
 }
 return op;
}
export const operationHash=op=>createHash('sha256').update(JSON.stringify(op)).digest('hex');
export function decideMutation(current,op,parent){if(op.kind!=='profile'&&(!parent||parent.deleted))return {code:'PROFILE_UNAVAILABLE'};if(op.kind==='profile'&&current?.deleted&&!op.deleted)return {code:'TOMBSTONED'};if((current?.revision??0)!==op.baseRevision)return {code:'CONFLICT'};return {code:'APPLY'};}
export function entityDto(row){return row?{profileId:row.profile_id,kind:row.kind,key:row.entity_key,revision:Number(row.revision),deleted:row.deleted,data:row.payload}:null;}
