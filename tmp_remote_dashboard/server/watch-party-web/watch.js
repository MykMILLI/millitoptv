import { VoiceMesh } from './voice.js';

const $ = id => document.getElementById(id);
const pathCode = decodeURIComponent(location.pathname.split('/')[2] ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
const params = new URLSearchParams(location.search);
const inviteToken = params.get('invite');
if (inviteToken) history.replaceState(null, '', location.pathname);

const state = {
  code: pathCode,
  token: null,
  me: null,
  party: null,
  media: null,
  playback: null,
  participants: [],
  offsets: [],
  clockOffset: 0,
  engine: null,          // { kind: 'video'|'youtube', mediaRev, hls?, ts?, yt? }
  needsGesture: false,
  localPause: false,
  streamAbort: null,
  reconnectDelay: 1000,
  closed: false,
  lastSeekAt: 0
};

const storageKey = code => `millitop.watch.${code}`;

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------
async function api(method, path, body) {
  const response = await fetch(path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(state.token ? { Authorization: `Bearer ${state.token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: 'no-store'
  });
  let data = {};
  try { data = await response.json(); } catch {}
  if (!response.ok) {
    const error = new Error(data.error || `Request failed (${response.status}).`);
    error.status = response.status;
    throw error;
  }
  return data;
}

function serverNow() { return Date.now() + state.clockOffset; }

function noteServerTime(serverTimeMs) {
  if (!Number.isFinite(serverTimeMs)) return;
  // Network delay only makes the estimate smaller, so the largest recent
  // sample is the best estimate of the true offset.
  state.offsets.push(serverTimeMs - Date.now());
  if (state.offsets.length > 20) state.offsets.shift();
  state.clockOffset = Math.max(...state.offsets);
}

// ---------------------------------------------------------------------------
// Join flow
// ---------------------------------------------------------------------------
function show(view) {
  for (const id of ['join-view', 'ended-view', 'room-view']) $(id).hidden = id !== view;
}

function showError(id, message) {
  $(id).textContent = message;
  $(id).hidden = !message;
}

async function boot() {
  $('join-name').value = localStorage.getItem('millitop.watch.name') ?? '';
  if (!state.code) {
    $('code-field').hidden = false;
    show('join-view');
    $('join-code').focus();
    return;
  }
  $('join-code').value = state.code;
  const saved = sessionStorage.getItem(storageKey(state.code));
  if (saved) {
    state.token = saved;
    try {
      const session = await api('GET', '/api/watch/session');
      enterRoom(session);
      return;
    } catch {
      state.token = null;
      sessionStorage.removeItem(storageKey(state.code));
    }
  }
  try {
    const info = await api('GET', `/api/watch/lookup/${state.code}`);
    $('join-title').textContent = info.title;
    $('join-host').textContent = `${info.hostName} is hosting · ${info.people} ${info.people === 1 ? 'person' : 'people'} here`;
    if (info.nowPlaying) {
      $('join-now').hidden = false;
      $('join-now-title').textContent = info.nowPlaying.title;
      if (info.nowPlaying.posterUrl) { $('join-poster').src = info.nowPlaying.posterUrl; $('join-poster').hidden = false; }
    }
    if (info.locked && !inviteToken) showError('join-error', 'The host locked this party. You need an email invite to join.');
    show('join-view');
    $('join-name').focus();
  } catch (error) {
    ended(error.status === 404 ? 'This watch party has ended or the link is wrong.' : error.message);
  }
}

$('join-form').addEventListener('submit', async event => {
  event.preventDefault();
  showError('join-error', '');
  const name = $('join-name').value.trim();
  const code = (state.code || $('join-code').value).toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (!code) return showError('join-error', 'Enter the party code from your invite.');
  if (!name) return showError('join-error', 'Enter your name so everyone knows who joined.');
  $('join-button').disabled = true;
  try {
    const joined = await api('POST', '/api/watch/join', { code, displayName: name, invite: inviteToken ?? undefined, client: 'web' });
    localStorage.setItem('millitop.watch.name', name);
    state.code = code;
    state.token = joined.participant.token;
    sessionStorage.setItem(storageKey(code), state.token);
    if (location.pathname !== `/watch/${code}`) history.replaceState(null, '', `/watch/${code}`);
    enterRoom({ me: { id: joined.participant.id, name, role: 'guest', relayKey: joined.participant.relayKey }, ...joined });
  } catch (error) {
    showError('join-error', error.message);
  } finally {
    $('join-button').disabled = false;
  }
});

function ended(text, title = 'This watch party has ended') {
  state.closed = true;
  state.streamAbort?.abort();
  voice.leave().catch(() => {});
  teardownEngine();
  if (state.code) sessionStorage.removeItem(storageKey(state.code));
  $('ended-title').textContent = title;
  $('ended-text').textContent = text;
  show('ended-view');
}

// ---------------------------------------------------------------------------
// Room
// ---------------------------------------------------------------------------
const voice = new VoiceMesh({ api, audioHost: $('voice-audio'), onChange: () => renderVoice() });

function enterRoom(snapshot) {
  state.me = snapshot.me;
  show('room-view');
  applySnapshot(snapshot);
  $('messages').replaceChildren();
  for (const message of snapshot.messages ?? []) addMessage(message);
  connectEvents();
  setInterval(syncTick, 500);
}

function applySnapshot(snapshot) {
  noteServerTime(snapshot.serverTimeMs);
  if (snapshot.me) state.me = snapshot.me;
  state.party = snapshot.party ?? state.party;
  state.participants = snapshot.participants ?? state.participants;
  if ('playback' in snapshot) state.playback = snapshot.playback;
  if ('media' in snapshot) setMedia(snapshot.media);
  renderHeader();
  renderPeople();
  voice.sync(state.participants);
  renderVoice();
}

function renderHeader() {
  const party = state.party;
  if (!party) return;
  document.title = `${party.title} · Watch party`;
  $('room-title').textContent = party.title;
  $('room-host').textContent = `Hosted by ${party.hostName}${party.hostOnline ? '' : ' (reconnecting…)'}`;
}

function renderPeople() {
  const list = $('people');
  list.replaceChildren();
  for (const person of state.participants) {
    const li = document.createElement('li');
    const dot = document.createElement('span');
    dot.className = 'dot' + (person.online ? ' on' : '');
    dot.title = person.online ? 'Online' : 'Offline';
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = person.name + (person.id === state.me?.id ? ' (you)' : '');
    li.append(dot, name);
    if (person.role === 'host') { const tag = document.createElement('span'); tag.className = 'tag'; tag.textContent = 'Host'; li.append(tag); }
    if (person.voice) {
      const mic = document.createElement('span');
      const speaking = voice.speaking(person.id);
      mic.className = 'mic' + (speaking ? ' speaking' : '');
      mic.textContent = person.voice.listenOnly ? 'listening' : person.voice.muted ? 'muted' : speaking ? 'speaking' : 'in voice';
      li.append(mic);
    }
    list.append(li);
  }
  $('people-count').textContent = `${state.participants.length}`;
}

function renderVoice() {
  $('voice-join').hidden = voice.active;
  $('voice-mute').hidden = !voice.active || voice.listenOnly;
  $('voice-leave').hidden = !voice.active;
  $('voice-mute').textContent = voice.muted ? 'Unmute' : 'Mute';
  const inVoice = state.participants.filter(p => p.voice).length;
  $('voice-count').textContent = inVoice ? `${inVoice} in voice` : '';
  showError('voice-error', voice.active && voice.permissionError ? voice.permissionError : '');
  renderPeople();
}

$('voice-join').addEventListener('click', async () => {
  $('voice-join').disabled = true;
  try { await voice.join(state.me.id); voice.sync(state.participants); }
  catch (error) { showError('voice-error', error.message); }
  finally { $('voice-join').disabled = false; renderVoice(); }
});
$('voice-mute').addEventListener('click', () => voice.setMuted(!voice.muted).catch(() => {}));
$('voice-leave').addEventListener('click', () => voice.leave().catch(() => {}));

$('copy-link').addEventListener('click', async () => {
  const link = state.party?.joinUrl ?? location.href;
  try { await navigator.clipboard.writeText(link); $('copy-link').textContent = 'Link copied'; }
  catch { prompt('Copy this link', link); }
  setTimeout(() => { $('copy-link').textContent = 'Copy invite link'; }, 2500);
});

$('leave').addEventListener('click', async () => {
  try { await api('POST', '/api/watch/leave', {}); } catch {}
  ended('You left the watch party.', 'You left the party');
});

// ---------------------------------------------------------------------------
// Chat & reactions
// ---------------------------------------------------------------------------
function addMessage(message) {
  const li = document.createElement('li');
  const who = document.createElement('span');
  who.className = 'who';
  who.textContent = message.name;
  const body = document.createElement('span');
  body.textContent = message.body;
  li.append(who, body);
  appendChat(li);
}

function addNotice(text) {
  const li = document.createElement('li');
  li.className = 'notice';
  li.textContent = text;
  appendChat(li);
}

function appendChat(li) {
  const list = $('messages');
  const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
  list.append(li);
  while (list.children.length > 300) list.firstElementChild.remove();
  if (nearBottom) list.scrollTop = list.scrollHeight;
}

$('chat-form').addEventListener('submit', async event => {
  event.preventDefault();
  const input = $('chat-input');
  const body = input.value.trim();
  if (!body) return;
  input.value = '';
  try { await api('POST', '/api/watch/chat', { body }); }
  catch (error) { input.value = body; addNotice(error.message); }
});

for (const button of document.querySelectorAll('[data-emoji]')) {
  button.addEventListener('click', () => api('POST', '/api/watch/reaction', { emoji: button.dataset.emoji }).catch(() => {}));
}

function floatReaction(emoji, name) {
  const node = document.createElement('div');
  node.className = 'reaction-float';
  node.style.left = `${10 + Math.random() * 75}%`;
  node.textContent = emoji;
  const label = document.createElement('span');
  label.textContent = name;
  node.append(label);
  $('reactions-layer').append(node);
  setTimeout(() => node.remove(), 3400);
}

// ---------------------------------------------------------------------------
// Event stream (Server-Sent Events over fetch so the token stays in a header)
// ---------------------------------------------------------------------------
function setConnection(text, kind) {
  const pill = $('connection');
  pill.textContent = text;
  pill.className = 'pill' + (kind ? ` ${kind}` : '');
}

async function connectEvents() {
  if (state.closed) return;
  const controller = new AbortController();
  state.streamAbort = controller;
  try {
    const response = await fetch('/api/watch/events', {
      headers: { Authorization: `Bearer ${state.token}`, Accept: 'text/event-stream' },
      cache: 'no-store',
      signal: controller.signal
    });
    if (response.status === 401 || response.status === 410) {
      let data = {};
      try { data = await response.json(); } catch {}
      return ended(data.error || 'This watch party has ended.');
    }
    if (!response.ok || !response.body) throw new Error('stream');
    setConnection('Connected', 'ok');
    state.reconnectDelay = 1000;
    const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
    let buffer = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += value;
      let index;
      while ((index = buffer.indexOf('\n\n')) >= 0) {
        const raw = buffer.slice(0, index);
        buffer = buffer.slice(index + 2);
        dispatch(raw);
      }
    }
  } catch (error) {
    if (controller.signal.aborted) return;
  }
  if (state.closed) return;
  setConnection('Reconnecting…', 'warn');
  setTimeout(connectEvents, state.reconnectDelay);
  state.reconnectDelay = Math.min(state.reconnectDelay * 2, 15000);
}

function dispatch(raw) {
  let name = 'message';
  const data = [];
  for (const line of raw.split('\n')) {
    if (line.startsWith('event:')) name = line.slice(6).trim();
    else if (line.startsWith('data:')) data.push(line.slice(5).trimStart());
  }
  if (!data.length) return;
  let payload;
  try { payload = JSON.parse(data.join('\n')); } catch { return; }
  noteServerTime(payload.serverTimeMs);
  switch (name) {
    case 'hello':
    case 'state':
      applySnapshot(payload);
      break;
    case 'playback':
      state.playback = payload.playback;
      syncTick(true);
      break;
    case 'chat':
      addMessage(payload.message);
      break;
    case 'notice':
      addNotice(payload.text);
      break;
    case 'reaction':
      floatReaction(payload.emoji, payload.name);
      break;
    case 'signal':
      voice.handleSignal(payload);
      break;
    case 'removed':
      ended('The host removed you from this party.', 'You were removed');
      break;
    case 'ended':
      ended(payload.reason === 'host-timeout' ? 'The host disconnected.' : 'The host ended the party.');
      break;
  }
}

// ---------------------------------------------------------------------------
// Playback engines
// ---------------------------------------------------------------------------
const video = $('video');
video.volume = Number(localStorage.getItem('millitop.watch.volume') ?? 100) / 100;
$('volume').value = String(Math.round(video.volume * 100));
$('volume').addEventListener('input', () => {
  const value = Number($('volume').value);
  video.volume = value / 100;
  state.engine?.yt?.setVolume?.(value);
  localStorage.setItem('millitop.watch.volume', String(value));
});
$('fullscreen').addEventListener('click', () => {
  const wrap = $('player-wrap');
  if (document.fullscreenElement) document.exitFullscreen();
  else wrap.requestFullscreen?.();
});
$('resync').addEventListener('click', () => { state.localPause = false; syncTick(true, true); });
$('tap-to-play').addEventListener('click', () => {
  state.needsGesture = false;
  $('tap-to-play').hidden = true;
  if (state.engine?.kind === 'youtube') state.engine.yt?.playVideo?.();
  syncTick(true, true);
});

function stageMessage(text) {
  $('stage-message').textContent = text ?? '';
  $('stage-message').hidden = !text;
}

function teardownEngine() {
  const engine = state.engine;
  state.engine = null;
  if (!engine) return;
  try { engine.hls?.destroy(); } catch {}
  try { engine.ts?.destroy(); } catch {}
  try { engine.yt?.destroy(); } catch {}
  video.pause();
  video.removeAttribute('src');
  video.load();
  $('yt-host').hidden = true;
  $('yt-host').replaceChildren(Object.assign(document.createElement('div'), { id: 'yt-player' }));
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[data-src="${src}"]`);
    if (existing) { existing.dataset.loaded ? resolve() : existing.addEventListener('load', resolve); return; }
    const script = document.createElement('script');
    script.src = src;
    script.dataset.src = src;
    script.onload = () => { script.dataset.loaded = '1'; resolve(); };
    script.onerror = () => reject(new Error(`Could not load ${src}`));
    document.head.append(script);
  });
}

function setMedia(media) {
  const sameRev = state.engine && media && state.engine.mediaRev === media.rev;
  state.media = media;
  renderNowPlaying();
  if (sameRev) return;
  teardownEngine();
  state.localPause = false;
  if (!media) { stageMessage('Waiting for the host to start something…'); return; }
  stageMessage('Loading…');
  if (media.kind === 'youtube') return startYouTube(media);
  return startRelay(media);
}

function renderNowPlaying() {
  const media = state.media;
  $('now-title').textContent = media ? media.title : 'Waiting for the host to start something…';
  $('now-sub').textContent = media ? [media.subtitle, media.queueLabel].filter(Boolean).join(' · ') : '';
  $('live-badge').hidden = !media?.live;
  $('resync').hidden = !media || media.live;
  const audio = media?.audioOnly === true;
  $('audio-art').hidden = !audio;
  if (audio) {
    $('audio-title').textContent = media.title;
    $('audio-poster').hidden = !media.posterUrl;
    if (media.posterUrl) $('audio-poster').src = media.posterUrl;
  }
}

async function startRelay(media) {
  const engine = { kind: 'video', mediaRev: media.rev };
  state.engine = engine;
  const url = `/watch-relay/${state.me.relayKey}/${media.rev}/main`;
  const type = media.relay?.type ?? 'file';
  video.hidden = false;
  if (media.posterUrl && !media.audioOnly) video.poster = media.posterUrl; else video.removeAttribute('poster');
  try {
    if (type === 'hls' && !video.canPlayType('application/vnd.apple.mpegurl')) {
      await loadScript('/watch-assets/hls.min.js');
      if (state.engine !== engine) return;
      if (!window.Hls?.isSupported()) throw new Error('This browser cannot play this stream.');
      const hls = new window.Hls({ enableWorker: true, lowLatencyMode: false, backBufferLength: 60, maxBufferLength: 30 });
      engine.hls = hls;
      hls.on(window.Hls.Events.ERROR, (_, data) => {
        if (!data.fatal) return;
        if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) hls.startLoad();
        else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) hls.recoverMediaError();
        else playbackFailed();
      });
      hls.loadSource(url);
      hls.attachMedia(video);
    } else if (type === 'ts') {
      await loadScript('/watch-assets/mpegts.min.js');
      if (state.engine !== engine) return;
      if (!window.mpegts?.isSupported()) throw new Error('This browser cannot play live TV streams.');
      const player = window.mpegts.createPlayer({ type: 'mpegts', isLive: media.live === true, url }, {
        enableWorker: true, liveBufferLatencyChasing: true, liveBufferLatencyMaxLatency: 8, liveBufferLatencyMinRemain: 2, lazyLoad: false
      });
      engine.ts = player;
      player.on(window.mpegts.Events.ERROR, () => playbackFailed());
      player.attachMediaElement(video);
      player.load();
    } else {
      video.src = url;
    }
    video.addEventListener('error', playbackFailed, { once: true });
    video.addEventListener('canplay', () => { if (state.engine === engine) stageMessage(''); }, { once: true });
    syncTick(true, true);
  } catch (error) {
    stageMessage(error.message);
  }
}

function playbackFailed() {
  const media = state.media;
  if (!media) return;
  stageMessage(media.relay?.type === 'file'
    ? 'Your browser cannot play this file format. Ask the host to pick a different version, or join from the MILLITOP TV app.'
    : 'The stream stopped. Trying again…');
  if (media.relay?.type !== 'file') setTimeout(() => { if (state.media === media) { teardownEngine(); startRelay(media); } }, 4000);
}

async function startYouTube(media) {
  const engine = { kind: 'youtube', mediaRev: media.rev, ready: false };
  state.engine = engine;
  video.hidden = true;
  $('yt-host').hidden = false;
  if (!window.YT?.Player) {
    const ready = new Promise(resolve => { window.onYouTubeIframeAPIReady = resolve; });
    await loadScript('https://www.youtube.com/iframe_api');
    await ready;
  }
  if (state.engine !== engine) return;
  engine.yt = new window.YT.Player('yt-player', {
    videoId: media.youtubeId,
    playerVars: { autoplay: 1, controls: 0, disablekb: 1, modestbranding: 1, rel: 0, playsinline: 1, origin: location.origin },
    events: {
      onReady: () => { engine.ready = true; engine.yt.setVolume(Number($('volume').value)); stageMessage(''); syncTick(true, true); },
      onError: () => stageMessage('This YouTube video cannot be played here (the owner may block embedding).')
    }
  });
}

// ---------------------------------------------------------------------------
// Sync: follow the host's position, play state and speed.
// ---------------------------------------------------------------------------
function targetPositionMs() {
  const pb = state.playback;
  if (!pb) return null;
  const elapsed = pb.playing && !pb.buffering ? Math.max(0, serverNow() - pb.updatedAtMs) * (pb.rate || 1) : 0;
  return pb.positionMs + elapsed;
}

function syncTick(force = false, hard = false) {
  const media = state.media;
  const engine = state.engine;
  const pb = state.playback;
  if (!media || !engine || engine.mediaRev !== media.rev) return;
  const hostPlaying = !pb || pb.mediaRev !== media.rev ? true : pb.playing;
  const label = !pb || pb.mediaRev !== media.rev ? 'Waiting for host…' : pb.buffering ? 'Host is buffering…' : pb.playing ? 'In sync' : 'Paused by host';

  if (engine.kind === 'youtube') {
    const yt = engine.yt;
    if (!engine.ready || !yt?.getPlayerState) return;
    const target = targetPositionMs();
    if (target !== null && pb?.mediaRev === media.rev) {
      const drift = yt.getCurrentTime() * 1000 - target;
      if (Math.abs(drift) > (hard ? 400 : 1500) && Date.now() - state.lastSeekAt > 2000) { yt.seekTo(target / 1000, true); state.lastSeekAt = Date.now(); }
    }
    const playingNow = yt.getPlayerState() === 1;
    if (hostPlaying && !playingNow && !state.localPause) yt.playVideo();
    if (!hostPlaying && playingNow) yt.pauseVideo();
    $('sync-state').textContent = label;
    return;
  }

  if (!media.live && pb && pb.mediaRev === media.rev) {
    const target = targetPositionMs();
    const current = video.currentTime * 1000;
    const drift = current - target;
    const canSeek = video.readyState >= 1 && Date.now() - state.lastSeekAt > 1500;
    if (canSeek && (Math.abs(drift) > 2500 || (hard && Math.abs(drift) > 400) || (!pb.playing && Math.abs(drift) > 800))) {
      video.currentTime = Math.max(0, (target + (pb.playing ? 250 : 0)) / 1000);
      state.lastSeekAt = Date.now();
      video.playbackRate = pb.rate || 1;
    } else if (pb.playing && Math.abs(drift) > 200) {
      video.playbackRate = (pb.rate || 1) * (drift > 0 ? 0.95 : 1.05);
    } else {
      video.playbackRate = pb.rate || 1;
    }
  }
  if (hostPlaying && video.paused && !state.localPause && video.readyState >= 2 && !state.needsGesture) {
    video.play().catch(error => {
      if (error?.name === 'NotAllowedError') { state.needsGesture = true; $('tap-to-play').hidden = false; }
    });
  }
  if (!hostPlaying && !video.paused) video.pause();
  $('sync-state').textContent = media.live ? 'Live' : label;
}

video.addEventListener('waiting', () => { $('sync-state').textContent = 'Buffering…'; });
video.addEventListener('loadedmetadata', () => syncTick(true, true));

boot();
