import { createCipheriv, createDecipheriv, createHash, createHmac, hkdfSync, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';

// Keys are derived from a server-only secret. WATCH_PARTY_SECRET wins when
// set; otherwise the dashboard's database password secret is used as input
// keying material so no new Docker secret is required. Rotating that secret
// only invalidates live relay links and the stored SMTP password (re-enter it
// in the dashboard).
export function loadMasterSecret({ env = process.env, read = readFileSync } = {}) {
  const explicit = env.WATCH_PARTY_SECRET?.trim();
  if (explicit) return explicit;
  try {
    const value = read('/run/secrets/db_password', 'utf8').trim();
    if (value) return value;
  } catch {
    // Fall through to the explicit error below.
  }
  throw new Error('Watch party secret unavailable: set WATCH_PARTY_SECRET or mount db_password.');
}

export class WatchPartyKeys {
  constructor(master) {
    if (typeof master !== 'string' || master.length < 8) throw new Error('Watch party master secret is too short.');
    const derive = info => Buffer.from(hkdfSync('sha256', master, 'millitop-watch-party-v1', info, 32));
    this.relayKey = derive('relay-url');
    this.settingsKey = derive('settings');
  }

  sealRelay(value) { return seal(this.relayKey, value); }
  openRelay(text) { return open(this.relayKey, text); }
  sealSetting(value) { return seal(this.settingsKey, value); }
  openSetting(text) { return open(this.settingsKey, text); }
}

function seal(key, value) {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64url');
}

function open(key, text) {
  if (typeof text !== 'string' || text.length < 40 || text.length > 16384 || !/^[A-Za-z0-9_-]+$/.test(text)) return null;
  try {
    const raw = Buffer.from(text, 'base64url');
    const decipher = createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    const body = Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]);
    return JSON.parse(body.toString('utf8'));
  } catch {
    return null;
  }
}

export const hashToken = token => createHash('sha256').update(String(token)).digest('hex');
export const newToken = (prefix = '') => prefix + randomBytes(32).toString('base64url');
export const newRelayKey = () => randomBytes(18).toString('base64url');

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export function newJoinCode() {
  const bytes = randomBytes(8);
  let code = '';
  for (const byte of bytes) code += CODE_ALPHABET[byte % CODE_ALPHABET.length];
  return code;
}

export function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && timingSafeEqual(left, right);
}

// coturn "use-auth-secret" (TURN REST API) time-limited credentials.
export function turnCredentials(secret, subject, ttlSeconds = 6 * 3600, now = Date.now()) {
  const username = `${Math.floor(now / 1000) + ttlSeconds}:${subject}`;
  const credential = createHmac('sha1', secret).update(username).digest('base64');
  return { username, credential };
}
