// Input validation for watch party routes. Every function throws an Error
// whose message is safe to show to the caller.

export class ValidationError extends Error {
  constructor(message) { super(message); this.status = 400; }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
const EMAIL = /^[^\s@<>()[\]\\,;:"]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;

export const MEDIA_KINDS = new Set(['movie', 'episode', 'live', 'youtube', 'podcast', 'music', 'video']);
export const isUuid = value => typeof value === 'string' && UUID.test(value);

export function text(value, name, { min = 1, max = 120, optional = false, multiline = false } = {}) {
  if (value === undefined || value === null || value === '') {
    if (optional) return null;
    throw new ValidationError(`${name} is required.`);
  }
  if (typeof value !== 'string') throw new ValidationError(`${name} must be text.`);
  const trimmed = multiline ? value.replace(/\r\n/g, '\n').trim() : value.replace(/\s+/g, ' ').trim();
  if (trimmed.length < min || trimmed.length > max) throw new ValidationError(`${name} must contain ${min}–${max} characters.`);
  if (CONTROL.test(trimmed) || (!multiline && /\n/.test(trimmed))) throw new ValidationError(`${name} contains unsupported characters.`);
  return trimmed;
}

export function joinCode(value) {
  if (typeof value !== 'string') throw new ValidationError('Enter the party code.');
  const code = value.toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (!/^[A-Z2-9]{8}$/.test(code)) throw new ValidationError('Party codes have 8 letters and numbers.');
  return code;
}

export function email(value) {
  const trimmed = text(value, 'Email address', { min: 3, max: 320 }).toLowerCase();
  if (!EMAIL.test(trimmed)) throw new ValidationError(`"${trimmed.slice(0, 80)}" is not a valid email address.`);
  return trimmed;
}

export function emailList(value) {
  const list = Array.isArray(value) ? value : typeof value === 'string' ? value.split(/[\s,;]+/) : [];
  const cleaned = [...new Set(list.filter(item => typeof item === 'string' && item.trim()).map(email))];
  if (!cleaned.length) throw new ValidationError('Add at least one email address.');
  if (cleaned.length > 20) throw new ValidationError('Invite up to 20 people at a time.');
  return cleaned;
}

function httpUrl(value, name, { optional = true, allowHttp = true } = {}) {
  if (value === undefined || value === null || value === '') {
    if (optional) return null;
    throw new ValidationError(`${name} is required.`);
  }
  if (typeof value !== 'string' || value.length > 8192) throw new ValidationError(`${name} is invalid.`);
  let url;
  try { url = new URL(value); } catch { throw new ValidationError(`${name} is invalid.`); }
  if (!(url.protocol === 'https:' || (allowHttp && url.protocol === 'http:'))) throw new ValidationError(`${name} must use HTTP or HTTPS.`);
  if (url.username || url.password) throw new ValidationError(`${name} must not contain embedded credentials.`);
  return url.toString();
}

const ALLOWED_UPSTREAM_HEADERS = new Set(['user-agent', 'referer', 'origin', 'x-emby-token', 'x-mediabrowser-token', 'authorization']);

export function upstream(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) throw new ValidationError('Stream details are invalid.');
  const url = httpUrl(value.url, 'Stream URL', { optional: false });
  const headers = {};
  if (value.headers !== undefined) {
    if (typeof value.headers !== 'object' || value.headers === null || Array.isArray(value.headers)) throw new ValidationError('Stream headers are invalid.');
    for (const [key, raw] of Object.entries(value.headers)) {
      const name = key.toLowerCase();
      if (!ALLOWED_UPSTREAM_HEADERS.has(name)) continue;
      if (typeof raw !== 'string' || raw.length > 2048 || /[\r\n]/.test(raw)) throw new ValidationError('Stream headers are invalid.');
      headers[name] = raw;
    }
  }
  return { url, headers };
}

export function media(value) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new ValidationError('Media details are required.');
  const kind = typeof value.kind === 'string' ? value.kind : '';
  if (!MEDIA_KINDS.has(kind)) throw new ValidationError('Unsupported media type.');
  const result = {
    kind,
    title: text(value.title, 'Title', { max: 200 }),
    subtitle: text(value.subtitle, 'Subtitle', { max: 200, optional: true }),
    posterUrl: httpUrl(value.posterUrl, 'Poster', { allowHttp: false }),
    durationMs: number(value.durationMs, 'Duration', { min: 0, max: 48 * 3600 * 1000, optional: true }),
    live: value.live === true || kind === 'live',
    audioOnly: value.audioOnly === true || kind === 'music',
    queueLabel: text(value.queueLabel, 'Queue label', { max: 40, optional: true }),
    youtubeId: null
  };
  if (kind === 'youtube') {
    if (typeof value.youtubeId !== 'string' || !/^[A-Za-z0-9_-]{11}$/.test(value.youtubeId)) throw new ValidationError('YouTube video id is invalid.');
    result.youtubeId = value.youtubeId;
  }
  const source = upstream(value.upstream);
  if (!source && kind !== 'youtube') throw new ValidationError('A stream URL is required for this media.');
  return { publicMedia: result, upstream: source };
}

export function number(value, name, { min = 0, max = Number.MAX_SAFE_INTEGER, optional = false, integer = true } = {}) {
  if (value === undefined || value === null) {
    if (optional) return null;
    throw new ValidationError(`${name} is required.`);
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max || (integer && !Number.isInteger(parsed))) throw new ValidationError(`${name} is out of range.`);
  return parsed;
}

export function playback(value) {
  if (typeof value !== 'object' || value === null) throw new ValidationError('Playback state is required.');
  return {
    mediaRev: number(value.mediaRev, 'Media revision', { min: 1 }),
    positionMs: number(value.positionMs, 'Position', { min: 0, max: 48 * 3600 * 1000 }),
    playing: value.playing === true,
    buffering: value.buffering === true,
    rate: number(value.rate ?? 1, 'Playback speed', { min: 0.25, max: 4, integer: false })
  };
}

export function signal(value) {
  if (typeof value !== 'object' || value === null) throw new ValidationError('Signal is required.');
  if (!isUuid(value.to)) throw new ValidationError('Signal recipient is invalid.');
  if (!['description', 'candidate', 'hangup'].includes(value.kind)) throw new ValidationError('Signal type is invalid.');
  const payload = value.payload ?? {};
  const size = JSON.stringify(payload).length;
  if (size > 32000) throw new ValidationError('Signal is too large.');
  return { to: value.to, kind: value.kind, payload };
}

export function smtpSettings(value) {
  if (typeof value !== 'object' || value === null) throw new ValidationError('SMTP settings are required.');
  const security = ['ssl', 'starttls', 'none'].includes(value.security) ? value.security : null;
  if (!security) throw new ValidationError('Choose SSL/TLS, STARTTLS or none.');
  return {
    enabled: value.enabled !== false,
    host: text(value.host, 'SMTP server', { max: 253 }),
    port: number(value.port, 'SMTP port', { min: 1, max: 65535 }),
    security,
    username: text(value.username, 'SMTP username', { max: 320, optional: true }),
    password: value.password === undefined || value.password === null || value.password === '' ? undefined : text(value.password, 'SMTP password', { max: 1024 }),
    fromEmail: email(value.fromEmail),
    fromName: text(value.fromName, 'From name', { max: 80, optional: true }) ?? 'MILLITOP TV',
    replyTo: value.replyTo ? email(value.replyTo) : null
  };
}

export function voiceSettings(value) {
  if (typeof value !== 'object' || value === null) throw new ValidationError('Voice settings are required.');
  const urls = (Array.isArray(value.turnUrls) ? value.turnUrls : String(value.turnUrls ?? '').split(/[\s,]+/))
    .map(item => String(item).trim()).filter(Boolean);
  for (const url of urls) {
    if (!/^turns?:[A-Za-z0-9.-]+(:\d{1,5})?(\?transport=(udp|tcp))?$/.test(url)) throw new ValidationError(`TURN URL "${url.slice(0, 80)}" is invalid.`);
  }
  if (urls.length > 4) throw new ValidationError('Add up to 4 TURN URLs.');
  return {
    turnUrls: urls,
    turnSecret: value.turnSecret === undefined || value.turnSecret === null || value.turnSecret === '' ? undefined : text(value.turnSecret, 'TURN secret', { min: 8, max: 256 }),
    stunUrls: ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478']
  };
}

export function limitSettings(value) {
  if (typeof value !== 'object' || value === null) throw new ValidationError('Limits are required.');
  return {
    maxParticipants: number(value.maxParticipants ?? 12, 'Maximum participants', { min: 2, max: 50 }),
    allowPublicJoin: value.allowPublicJoin !== false
  };
}
