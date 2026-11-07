import React,{useState} from 'react';
import previews from './standalone-downloads.json';
import {safeDownloadUrl,formatSize,registeredWindows} from './download-links.mjs';

function DownloadActions({item}){
 const [message,setMessage]=useState(''),[address,setAddress]=useState('');
 const href=safeDownloadUrl(item.url);
 async function copy(){const absolute=new URL(href,window.location.origin).href;setAddress(absolute);try{await navigator.clipboard.writeText(absolute);setMessage('Download link copied.');}catch{setMessage('Select and copy the download address below.');}}
 return <div>
  {href?<div style={{display:'flex',gap:12,flexWrap:'wrap',alignItems:'center'}}><a href={href} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">{item.downloadLabel||'Download file'}</a><button type="button" className="secondary" onClick={copy}>Copy download link</button></div>:<p role="alert">Download URL is missing or invalid. No download link is available.</p>}
  <p>{item.platform} · {formatSize(item.sizeBytes)}</p>
  <p style={{overflowWrap:'anywhere'}}>SHA-256: <code>{/^[a-f0-9]{64}$/i.test(item.sha256||'')?item.sha256:'Not recorded'}</code></p>
  {item.hint&&<p>{item.hint}</p>}
  {message&&<p role="status">{message}</p>}
  {address&&<label>Download address<input type="text" readOnly value={address} onFocus={e=>e.target.select()}/></label>}
 </div>;
}
export function RegisteredReleaseDownload({release}){const item=registeredWindows([release])[0];return item?<DownloadActions item={item}/>:null;}
export default function StandaloneDownloadsPanel({releases=[]}){
 const latest=registeredWindows(releases)[0];
 return <section aria-labelledby="standalone-downloads-title">
  <h3 id="standalone-downloads-title">Quick downloads for a new device</h3>
  <p>Download first, install on the intended device, then pair it to your household. Downloads do not register, enable or assign an update.</p>
  <h4>Latest registered Windows installer</h4>
  {latest?<article className="device-card"><h4>{latest.title}</h4><DownloadActions item={latest}/></article>:<p>No registered Windows installer is available.</p>}
  <h4>Android sideload builds, previews and corresponding source</h4>
  <p>Android APKs use the development signing key and are intended for sideload testing, not store distribution. Source archives include the GPLv3 license and build instructions. These downloads are not assigned as automatic updates.</p>
  {previews.downloads.map(item=><article className="device-card" key={item.id}><h4>{item.title}</h4><p>{item.category==='source'?'Corresponding source':'Development/sideload build'} · {item.version}</p><DownloadActions item={item}/></article>)}
  <p>Windows ZIP: extract the entire folder before running millitop_tv.exe; keep its DLLs and data folder together. This is not an installer, and a new PC may need runtime prerequisites. Android APK: ARM64 development package, not a production-signed release. Updating an existing preview requires a matching signing key; do not uninstall it to bypass an update error.</p>
 </section>;
}
