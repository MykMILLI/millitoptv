export function safeDownloadUrl(value){
 if(typeof value!=='string'||value.length>2048)return null;
 const raw=value.trim();
 if(/^\/downloads\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(raw))return raw;
 try{const url=new URL(raw);if(url.protocol!=='https:'||url.username||url.password||url.hash)return null;return url.href;}catch{return null;}
}
export function formatSize(value){const n=Number(value);return Number.isFinite(n)&&n>0?`${(n/1048576).toFixed(1)} MiB`:'Size not recorded';}
export function registeredWindows(releases){return (Array.isArray(releases)?releases:[]).filter(r=>r&&/^windows(?:-|$)/i.test(r.platform||'windows-x64')).map(r=>({id:r.id,title:`Windows ${r.version}+${r.build}`,url:r.installer_url||r.installerUrl,sha256:r.sha256,sizeBytes:r.size_bytes??r.sizeBytes,platform:r.platform||'windows-x64',build:Number(r.build)||0,downloadLabel:'Download Windows installer (.exe)',hint:r.enabled?'Update offers enabled for assigned devices.':'Update offers paused; manual download does not enable them.'})).sort((a,b)=>b.build-a.build);}
