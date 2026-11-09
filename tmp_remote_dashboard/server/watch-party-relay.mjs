// Stream relay for watch parties. Guests never see the upstream address or
// its credentials: every upstream URL (including HLS segment URLs found in
// playlists) is sealed with AES-GCM and only unsealed here.
//
// Sharing strategy, so guests do not multiply upstream connections:
//   * HLS: playlists are fetched per request (small); segments are fetched
//     once and served to every guest from a short-lived in-memory cache.
//   * Live MPEG-TS (typical IPTV): one upstream connection per party/media
//     revision is fanned out to every listener.
//   * Files (MP4/MKV/MP3/FLAC): byte-range passthrough per request.
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { Readable } from 'node:stream';

const PLAYLIST_TYPES = /mpegurl|vnd\.apple\.mpegurl/i;
const MAX_PLAYLIST_BYTES = 4 * 1024 * 1024;
const DEFAULT_UA = 'Lavf/60.16.100';
const PASS_HEADERS = ['content-type', 'content-length', 'content-range', 'accept-ranges', 'last-modified', 'etag'];

export function isPlaylistResponse(url, contentType, firstBytes) {
  if (contentType && PLAYLIST_TYPES.test(contentType)) return true;
  if (firstBytes && firstBytes.length >= 7 && /^(\uFEFF|\xEF\xBB\xBF)?\s*#EXTM3U/.test(firstBytes.subarray(0, 64).toString('latin1'))) return true;
  try { return /\.m3u8?$/i.test(new URL(url).pathname) && !contentType?.startsWith('video/'); } catch { return false; }
}

export function looksLikeTransportStream(url, contentType, firstBytes) {
  if (contentType && /mp2t|mpeg-ts|mpegts/i.test(contentType)) return true;
  if (firstBytes && firstBytes.length > 376 && firstBytes[0] === 0x47 && firstBytes[188] === 0x47 && firstBytes[376] === 0x47) return true;
  try { return /\.ts$/i.test(new URL(url).pathname); } catch { return false; }
}

// Rewrites every URI in an HLS playlist through [makeUrl].
export function rewritePlaylist(text, baseUrl, makeUrl) {
  const resolve = value => new URL(value, baseUrl).toString();
  return text.split(/\r?\n/).map(line => {
    const trimmed = line.trim();
    if (!trimmed) return line;
    if (trimmed.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_, uri) => {
        if (/^(data|skd):/i.test(uri)) return `URI="${uri}"`;
        return `URI="${makeUrl(resolve(uri), true)}"`;
      });
    }
    return makeUrl(resolve(trimmed), /\.m3u8?(\?|$)/i.test(trimmed));
  }).join('\n');
}

function blockedAddress(address) {
  const version = isIP(address);
  if (version === 4) {
    const [a, b] = address.split('.').map(Number);
    return a === 127 || a === 0 || (a === 169 && b === 254) || a >= 224;
  }
  if (version === 6) {
    const lower = address.toLowerCase();
    if (lower.startsWith('::ffff:')) return blockedAddress(lower.slice(7));
    return lower === '::1' || lower === '::' || lower.startsWith('fe80:') || lower.startsWith('ff');
  }
  return true;
}

// The host device is trusted to point at its own LAN servers (Jellyfin,
// Navidrome), so private ranges are allowed. Loopback, link-local
// (cloud metadata) and multicast are refused.
export async function assertRelayTarget(url, resolver = lookup) {
  const parsed = new URL(url);
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new RelayError(400, 'Unsupported stream protocol.');
  const host = parsed.hostname.replace(/^\[|\]$/g, '');
  const addresses = isIP(host) ? [{ address: host }] : await resolver(host, { all: true }).catch(() => []);
  if (!addresses.length) throw new RelayError(502, 'The stream server could not be found from tvadmin.');
  if (addresses.some(entry => blockedAddress(entry.address))) throw new RelayError(403, 'That stream address is not allowed for relaying.');
}

export class RelayError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

class SegmentCache {
  constructor({ maxBytes = 256 * 1024 * 1024, ttlMs = 45000 } = {}) {
    this.maxBytes = maxBytes; this.ttlMs = ttlMs; this.bytes = 0;
    this.entries = new Map(); this.inflight = new Map();
  }
  get(key) {
    const entry = this.entries.get(key);
    if (!entry) return null;
    if (Date.now() - entry.at > this.ttlMs) { this.delete(key); return null; }
    return entry;
  }
  delete(key) {
    const entry = this.entries.get(key);
    if (entry) { this.bytes -= entry.body.length; this.entries.delete(key); }
  }
  set(key, entry) {
    if (entry.body.length > 32 * 1024 * 1024) return;
    this.delete(key);
    this.entries.set(key, entry); this.bytes += entry.body.length;
    for (const [oldest] of this.entries) {
      if (this.bytes <= this.maxBytes) break;
      this.delete(oldest);
    }
  }
}

// One upstream connection shared by every listener of a live stream.
class LiveFanout {
  constructor({ key, open, onEmpty, maxBuffered = 8 * 1024 * 1024 }) {
    this.key = key; this.open = open; this.onEmpty = onEmpty; this.maxBuffered = maxBuffered;
    this.listeners = new Set(); this.headers = null; this.controller = null; this.started = null; this.idleTimer = null;
  }
  async add(res) {
    clearTimeout(this.idleTimer);
    if (!this.started) this.started = this.start();
    await this.started;
    if (!this.headers) throw new RelayError(502, 'The live stream ended.');
    res.status(200);
    res.setHeader('Content-Type', this.headers['content-type'] || 'video/mp2t');
    res.setHeader('Cache-Control', 'no-store');
    res.flushHeaders?.();
    this.listeners.add(res);
    res.on('close', () => this.remove(res));
  }
  remove(res) {
    this.listeners.delete(res);
    if (!this.listeners.size) {
      clearTimeout(this.idleTimer);
      this.idleTimer = setTimeout(() => this.stop(), 8000);
      this.idleTimer.unref?.();
    }
  }
  async start() {
    this.controller = new AbortController();
    const response = await this.open(this.controller.signal);
    this.headers = Object.fromEntries(response.headers);
    const reader = response.body.getReader();
    (async () => {
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          const chunk = Buffer.from(value);
          for (const res of this.listeners) {
            if (res.writableLength > this.maxBuffered) { res.destroy(); continue; }
            res.write(chunk);
          }
        }
      } catch {
        // Upstream aborted or failed; listeners are closed below.
      } finally {
        for (const res of this.listeners) res.end();
        this.listeners.clear();
        this.stop();
      }
    })();
  }
  stop() {
    clearTimeout(this.idleTimer);
    try { this.controller?.abort(); } catch {}
    this.onEmpty(this.key, this);
  }
}

export class WatchPartyRelay {
  constructor({ keys, resolveRelay, fetchImpl = fetch, resolver = lookup, log = console }) {
    this.keys = keys; this.resolveRelay = resolveRelay; this.fetch = fetchImpl; this.resolver = resolver; this.log = log;
    this.cache = new SegmentCache();
    this.fanouts = new Map();
  }

  relayPath(relayKey, mediaRev, target, playlist, partyId) {
    const blob = this.keys.sealRelay({ u: target, p: partyId, r: mediaRev });
    let name = 'seg';
    try {
      const ext = /\.([a-z0-9]{1,5})$/i.exec(new URL(target).pathname)?.[1]?.toLowerCase();
      name = playlist ? 'index.m3u8' : ext ? `seg.${ext}` : 'seg';
    } catch {}
    return `/watch-relay/${relayKey}/${mediaRev}/s/${blob}/${name}`;
  }

  upstreamHeaders(source, req) {
    const headers = { 'user-agent': DEFAULT_UA, accept: '*/*', ...source.headers };
    const range = req?.get?.('range');
    if (range && /^bytes=\d*-\d*$/.test(range)) headers.range = range;
    return headers;
  }

  // Redirects are followed by hand so every hop passes the address guard.
  async fetchUpstream(url, source, req, signal) {
    let current = url;
    let response;
    for (let hop = 0; ; hop += 1) {
      await assertRelayTarget(current, this.resolver);
      response = await this.fetch(current, { headers: this.upstreamHeaders(source, req), redirect: 'manual', signal });
      const location = response.headers.get('location');
      if (response.status < 300 || response.status >= 400 || !location) break;
      try { await response.body?.cancel(); } catch {}
      if (hop >= 5) throw new RelayError(502, 'The stream server redirected too many times.');
      current = new URL(location, current).toString();
    }
    if (current !== url) Object.defineProperty(response, 'finalUrl', { value: current });
    if (response.status >= 400) {
      try { await response.body?.cancel(); } catch {}
      throw new RelayError(502, `The stream server answered ${response.status}.`);
    }
    return response;
  }

  // Classifies a source so guests choose the right player engine.
  async probe(source) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await this.fetchUpstream(source.url, source, null, controller.signal);
      const reader = response.body.getReader();
      let collected = Buffer.alloc(0);
      while (collected.length < 1024) {
        const { done, value } = await reader.read();
        if (done) break;
        collected = Buffer.concat([collected, Buffer.from(value)]);
      }
      controller.abort();
      const contentType = response.headers.get('content-type') || '';
      if (isPlaylistResponse(response.finalUrl || response.url || source.url, contentType, collected)) return { type: 'hls', reachable: true };
      if (looksLikeTransportStream(response.finalUrl || response.url || source.url, contentType, collected)) return { type: 'ts', reachable: true };
      return { type: 'file', reachable: true, contentType };
    } catch (error) {
      return { type: guessType(source.url), reachable: false, error: error instanceof RelayError ? error.message : 'tvadmin could not reach this stream.' };
    } finally {
      clearTimeout(timer);
    }
  }

  // Express handler for /watch-relay/:relayKey/:mediaRev/(main|s/:blob/:name)
  async handle(req, res) {
    const { relayKey, mediaRev } = req.params;
    const rev = Number(mediaRev);
    const context = await this.resolveRelay(relayKey);
    if (!context) return res.status(403).type('text/plain').send('This watch party link is no longer valid.');
    if (!Number.isInteger(rev) || rev !== context.mediaRev || !context.upstream) {
      return res.status(409).type('text/plain').send('The host changed what is playing.');
    }
    let target = context.upstream.url;
    let wantsPlaylist = false;
    if (req.params.blob) {
      const sealed = this.keys.openRelay(req.params.blob);
      if (!sealed || sealed.p !== context.partyId || sealed.r !== rev) return res.status(403).type('text/plain').send('Invalid relay segment.');
      target = sealed.u;
      wantsPlaylist = req.params.name === 'index.m3u8';
    }
    const isMain = !req.params.blob;
    if (isMain && context.relayType === 'ts' && context.live) return this.serveLive(req, res, context, target);
    if (!isMain && !wantsPlaylist && context.relayType === 'hls') return this.serveCachedSegment(req, res, context, target);
    return this.servePassthrough(req, res, context, target, { allowPlaylist: isMain || wantsPlaylist });
  }

  async serveLive(req, res, context, target) {
    const key = `${context.partyId}:${context.mediaRev}`;
    let fanout = this.fanouts.get(key);
    if (!fanout) {
      fanout = new LiveFanout({
        key,
        open: signal => this.fetchUpstream(target, context.upstream, null, signal),
        onEmpty: (k, instance) => { if (this.fanouts.get(k) === instance) this.fanouts.delete(k); }
      });
      this.fanouts.set(key, fanout);
    }
    await fanout.add(res);
  }

  async serveCachedSegment(req, res, context, target) {
    if (req.get('range')) return this.servePassthrough(req, res, context, target, { allowPlaylist: false });
    let entry = this.cache.get(target);
    if (!entry) {
      let pending = this.cache.inflight.get(target);
      if (!pending) {
        pending = (async () => {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 30000);
          try {
            const response = await this.fetchUpstream(target, context.upstream, null, controller.signal);
            const body = Buffer.from(await response.arrayBuffer());
            const value = { at: Date.now(), body, type: response.headers.get('content-type') || 'video/mp2t' };
            if (response.status === 200) this.cache.set(target, value);
            return value;
          } finally {
            clearTimeout(timer);
          }
        })().finally(() => this.cache.inflight.delete(target));
        this.cache.inflight.set(target, pending);
      }
      entry = await pending;
    }
    res.status(200).setHeader('Content-Type', entry.type);
    res.setHeader('Content-Length', String(entry.body.length));
    res.setHeader('Cache-Control', 'private, max-age=30');
    res.end(entry.body);
  }

  async servePassthrough(req, res, context, target, { allowPlaylist }) {
    const controller = new AbortController();
    res.on('close', () => controller.abort());
    const response = await this.fetchUpstream(target, context.upstream, req, controller.signal);
    const contentType = response.headers.get('content-type') || '';
    const finalUrl = response.finalUrl || response.url || target;
    if (allowPlaylist && (context.relayType === 'hls' || PLAYLIST_TYPES.test(contentType) || /\.m3u8?(\?|$)/i.test(new URL(finalUrl).pathname))) {
      const textBody = await readLimited(response, MAX_PLAYLIST_BYTES);
      if (textBody.replace(/^\uFEFF/, '').trimStart().startsWith('#EXTM3U')) {
        const rewritten = rewritePlaylist(textBody.replace(/^\uFEFF/, ''), finalUrl, (url, playlist) =>
          this.relayPath(req.params.relayKey, context.mediaRev, url, playlist, context.partyId));
        res.status(200).setHeader('Content-Type', 'application/vnd.apple.mpegurl');
        res.setHeader('Cache-Control', 'no-store');
        return res.send(rewritten);
      }
      res.status(200).setHeader('Content-Type', contentType || 'application/octet-stream');
      return res.send(textBody);
    }
    res.status(response.status);
    for (const name of PASS_HEADERS) {
      const value = response.headers.get(name);
      if (value) res.setHeader(name, value);
    }
    res.setHeader('Cache-Control', 'private, no-store');
    if (!response.body) return res.end();
    const stream = Readable.fromWeb(response.body);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }

  stats() {
    return { cachedSegments: this.cache.entries.size, cachedBytes: this.cache.bytes, liveStreams: this.fanouts.size };
  }
}

function guessType(url) {
  try {
    const path = new URL(url).pathname.toLowerCase();
    if (/\.m3u8?$/.test(path)) return 'hls';
    if (path.endsWith('.ts')) return 'ts';
  } catch {}
  return 'file';
}

async function readLimited(response, limit) {
  const reader = response.body.getReader();
  const chunks = []; let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > limit) { await reader.cancel(); throw new RelayError(502, 'The playlist is too large.'); }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks).toString('utf8');
}
