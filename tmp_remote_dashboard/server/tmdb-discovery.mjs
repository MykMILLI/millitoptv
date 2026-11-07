import {readFile,writeFile,mkdir,rename} from 'node:fs/promises';
import {dirname} from 'node:path';
const SIX_HOURS=6*60*60*1000,MAX_STALE=48*60*60*1000;
export const NOTICE='This product uses the TMDB API but is not endorsed or certified by TMDB.';
export function youtubeTrailer(videos){return (videos??[]).filter(v=>v.site==='YouTube'&&v.type==='Trailer'&&v.official===true&&/^[A-Za-z0-9_-]{11}$/.test(v.key)).sort((a,b)=>(b.iso_639_1==='en')-(a.iso_639_1==='en')||String(b.published_at??'').localeCompare(String(a.published_at??'')))[0]?.key??null;}
export function artwork(item,key){const path=item.backdrop_path??item.poster_path;if(typeof path==='string'&&/^\/[A-Za-z0-9_-]+\.(jpg|png|webp)$/.test(path))return 'https://image.tmdb.org/t/p/'+(item.backdrop_path?'w780':'w500')+path;return 'https://i.ytimg.com/vi/'+key+'/hqdefault.jpg';}
export class TmdbDiscovery {
 constructor({fetcher=fetch,secretReader=()=>readFile('/run/secrets/tmdb_credentials.json','utf8'),cacheFile='/var/lib/millitop/discovery/tmdb-cache.json',now=()=>Date.now()}={}){this.fetcher=fetcher;this.secretReader=secretReader;this.cacheFile=cacheFile;this.now=now;this.cache=null;this.refreshing=null;this.timer=null;this.lastError=null;this.lastAttempt=null;this.enabled=true;this.stopped=false;}
 async request(path,credential,query={}){
  if(!/^\/(trending\/(movie|tv)\/week|movie\/popular|tv\/popular|(movie|tv)\/\d+\/videos)$/.test(path))throw Error('Unsupported provider route');
  const u=new URL('https://api.themoviedb.org/3'+path);u.searchParams.set('language','en-US');for(const [k,v]of Object.entries(query))u.searchParams.set(k,String(v));
  const headers={accept:'application/json','user-agent':'Millitop-TV-Discovery/1'};
  if(credential.type==='ReadToken')headers.Authorization='Bearer '+credential.credential;else if(credential.type==='ApiKey')u.searchParams.set('api_key',credential.credential);else throw Error('Unsupported credential type');
  const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),12000);
  try{const r=await this.fetcher(u,{headers,redirect:'error',signal:controller.signal});if(r.status===404&&path.endsWith('/videos'))return {results:[]};if(!r.ok)throw Error('Provider request rejected');const body=await r.text();if(Buffer.byteLength(body)>2097152)throw Error('Provider response too large');return JSON.parse(body);}finally{clearTimeout(timeout);}
 }
 status(){const age=this.cache?this.now()-this.cache.fetchedAt:null;return {provider:'TMDB',enabled:this.enabled,refreshing:!!this.refreshing,lastAttempt:this.lastAttempt,lastSuccess:this.cache?.fetchedAt??null,lastError:this.lastError,stale:age===null||age>SIX_HOURS,expired:age===null||age>MAX_STALE,count:age!==null&&age<=MAX_STALE?this.cache.cards.length:0,notice:NOTICE,language:'en-US',refreshHours:6,maxCacheHours:48};}
 cards(){if(!this.enabled||!this.cache||this.now()-this.cache.fetchedAt>MAX_STALE)return [];return this.cache.cards;}
 async loadCache(){if(!this.cacheFile)return;try{const settings=JSON.parse(await readFile(this.cacheFile+'.settings','utf8'));if(typeof settings.enabled==='boolean')this.enabled=settings.enabled;}catch{}try{const raw=await readFile(this.cacheFile,'utf8');if(Buffer.byteLength(raw)>1048576)throw Error('Cache too large');const parsed=JSON.parse(raw);if(!Number.isFinite(parsed.fetchedAt)||parsed.fetchedAt>this.now()+60000||!Array.isArray(parsed.cards)||parsed.cards.length>100)throw Error('Invalid cache');for(const c of parsed.cards){if(!/^tmdb:(movie|tv):\d+$/.test(c.id)||c.source!=='TMDB'||!['trending','movies','shows'].includes(c.row)||!/^https:\/\/www\.youtube\.com\/watch\?v=[A-Za-z0-9_-]{11}$/.test(c.trailer_url)||!/^https:\/\/(image\.tmdb\.org\/t\/p\/(w780|w500)\/[A-Za-z0-9_-]+\.(jpg|png|webp)|i\.ytimg\.com\/vi\/[A-Za-z0-9_-]{11}\/hqdefault\.jpg)$/.test(c.thumbnail_url))throw Error('Invalid cached URL');}this.cache=parsed;}catch{this.cache=null;}}
 async refresh(){if(this.refreshing)return this.refreshing;this.refreshing=this.perform();try{return await this.refreshing;}finally{this.refreshing=null;}}
 async perform(){if(!this.enabled)return false;this.lastAttempt=this.now();try{
  const credential=JSON.parse(await this.secretReader());if(!credential.credential||typeof credential.credential!=='string')throw Error('Credential unavailable');
  const lists=await Promise.all([this.request('/trending/movie/week',credential),this.request('/movie/popular',credential),this.request('/tv/popular',credential)]);
  const rows=[['trending','movie'],['movies','movie'],['shows','tv']],seen=new Set(),cards=[];
  for(let n=0;n<rows.length;n++){
   const [row,type]=rows[n];const candidates=(lists[n].results??[]).filter(v=>Number.isInteger(v.id)&&v.id>0&&v.adult!==true).slice(0,20);
   let selected=0;
   // Bounded sequential resolution avoids a startup burst against TMDB.
   for(const item of candidates){if(selected>=8)break;const id='tmdb:'+type+':'+item.id;if(seen.has(id))continue;
    const title=type==='movie'?item.title:item.name;if(typeof title!=='string'||!title.trim())continue;
    const videos=await this.request('/'+type+'/'+item.id+'/videos',credential);const key=youtubeTrailer(videos.results);if(!key)continue;
    cards.push({id,title:title.slice(0,160),description:String(item.overview??'').slice(0,1000),section:type==='movie'?'movies':'shows',row,source:'TMDB',trailer_url:'https://www.youtube.com/watch?v='+key,thumbnail_url:artwork(item,key)});seen.add(id);selected++;
   }
  }
  if(!cards.length)throw Error('No eligible official trailers found');
  const snapshot={fetchedAt:this.now(),cards};
  if(this.cacheFile){await mkdir(dirname(this.cacheFile),{recursive:true});const tmp=this.cacheFile+'.tmp';await writeFile(tmp,JSON.stringify(snapshot),{mode:0o600});await rename(tmp,this.cacheFile);}
  this.cache=snapshot;this.lastError=null;return true;
 }catch{this.lastError='Automatic refresh failed. Check provider credentials/connectivity and retry.';return false;}}
 async setEnabled(enabled){if(this.cacheFile){await mkdir(dirname(this.cacheFile),{recursive:true});const p=this.cacheFile+'.settings.tmp';await writeFile(p,JSON.stringify({enabled}),{mode:0o600});await rename(p,this.cacheFile+'.settings');}this.enabled=enabled;if(enabled)void this.refresh();}
 async initialize(){await this.loadCache();await this.refresh();this.schedule();}
 schedule(){clearTimeout(this.timer);if(this.stopped)return;this.timer=setTimeout(()=>{void this.refresh().finally(()=>this.schedule());},this.lastError?15*60*1000:SIX_HOURS);this.timer.unref?.();}
 start(){this.stopped=false;void this.initialize().catch(()=>{this.lastError='Automatic discovery initialization failed.';this.schedule();});}
 stop(){this.stopped=true;clearTimeout(this.timer);}
}
export function registerTmdbDiscoveryRoutes(app,provider){
 const admin=(req,res)=>{if(!req.admin?.id){res.status(401).json({error:'Dashboard authentication required.'});return false;}return true;};
 app.get('/api/admin/discovery/status',(req,res)=>{if(admin(req,res))res.json(provider.status());});
 app.post('/api/admin/discovery/refresh',(req,res)=>{if(!admin(req,res))return;void provider.refresh();res.status(202).json({accepted:true,status:provider.status()});});
 app.post('/api/admin/discovery/enabled',async(req,res)=>{if(!admin(req,res))return;if(typeof req.body?.enabled!=='boolean')return res.status(400).json({error:'Choose enabled or disabled.'});try{await provider.setEnabled(req.body.enabled);res.json(provider.status());}catch{res.status(500).json({error:'Discovery settings could not be saved.'});}});
}
