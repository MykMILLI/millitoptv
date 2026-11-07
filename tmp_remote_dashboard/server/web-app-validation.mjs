import { isIP } from 'node:net';
export const appIcons = new Set(['web','emby','jellyfin']);
export const isUuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
function localHost(host) {
  const h=host.toLowerCase().replace(/^\[|\]$/g,'');
  if(h==='localhost'||h.endsWith('.localhost')||h.endsWith('.local')||h.endsWith('.lan'))return true;
  if(isIP(h)===4){const [a,b]=h.split('.').map(Number);return a===10||a===127||(a===192&&b===168)||(a===172&&b>=16&&b<=31);}
  return isIP(h)===6&&(h==='::1'||h.startsWith('fc')||h.startsWith('fd')||h.startsWith('fe80:'));
}
export function validateWebUrl(value) {
  if(typeof value!=='string'||!value.trim()||value.length>2048||/[\x00-\x20\x7f"\\]/.test(value))throw new Error('Enter a full HTTPS URL, or an HTTP URL for a local network service.');
  let url;try{url=new URL(value);}catch{throw new Error('Enter a valid full URL.');}
  if(!url.hostname||url.username||url.password||!(url.protocol==='https:'||(url.protocol==='http:'&&localHost(url.hostname))))throw new Error('Only HTTPS, or HTTP on a local network host, is permitted. Embedded credentials are prohibited.');
  for(const key of url.searchParams.keys())if(/^(access[_-]?token|refresh[_-]?token|token|password|passwd|api[_-]?key|secret|authorization)$/i.test(key))throw new Error('Do not store credentials or access tokens in an app URL. Sign in through the browser.');
  if(/(?:^|[&#?])(access_token|refresh_token|password|token)=/i.test(url.hash))throw new Error('Remove credentials from the URL fragment.');
  if(url.href.length>2048)throw new Error('URL is too long.');
  return url.href;
}
export function validateWebApp(body,{revision=false}={}) {
  if(!body||typeof body!=='object'||Array.isArray(body)||typeof body.title!=='string'||!body.title.trim()||body.title.trim().length>80||/[\x00-\x1f\x7f]/.test(body.title))throw new Error('Enter an app name of 1–80 characters.');
  if(typeof body.enabled!=='boolean'||!appIcons.has(body.icon))throw new Error('Select a supported icon and enabled state.');
  if(revision&&(!Number.isInteger(body.revision)||body.revision<1||body.revision>=2147483647))throw new Error('Refresh the app before editing.');
  return {title:body.title.trim(),url:validateWebUrl(body.url),icon:body.icon,enabled:body.enabled,...(revision?{revision:body.revision}:{})};
}
export function validateAssignments(body) {
  const ids=body?.deviceIds;
  if(!Array.isArray(ids)||ids.length<1||ids.length>100||!ids.every(isUuid)||new Set(ids).size!==ids.length||typeof body.enabled!=='boolean')throw new Error('Choose 1–100 distinct devices and an assignment enabled state.');
  return {deviceIds:ids,enabled:body.enabled};
}
