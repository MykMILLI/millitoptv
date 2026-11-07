// App diagnostics + usage analytics.
//
//   POST /api/device/telemetry          device-authenticated batch upload
//   GET  /api/admin/telemetry/summary   admin: top problems, events, versions
//
// The app redacts secrets before sending; the server re-checks and trims
// every field so a bad client cannot store credentials or huge payloads.
const LEVELS = new Set(['debug', 'info', 'warn', 'error']);
const MAX_BATCH = 200;
const SECRET_KEY = /(token|password|passwd|secret|api[_-]?key|authorization)/i;

export class TelemetryError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function redact(text) {
  return String(text)
    .replace(/(\w+:\/\/)[^/\s:@]+:[^/\s@]+@/g, '$1***:***@')
    .replace(/((?:api[_-]?key|access[_-]?token|token|password|passwd|pw|secret|x-emby-token|username|user)=)[^&\s"]+/gi, '$1***')
    .replace(/(Token=")[^"]*(")/gi, '$1***$2')
    .replace(/(Bearer\s+)[A-Za-z0-9._-]+/gi, '$1***')
    .replace(/\/(live|movie|series|timeshift)\/[^/\s]+\/[^/\s]+\//g, '/$1/***/***/');
}

function clip(value, max) {
  if (value === undefined || value === null) return null;
  const cleaned = redact(String(value)).trim();
  return cleaned ? cleaned.slice(0, max) : null;
}

function cleanDetails(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out = {};
  for (const [key, value] of Object.entries(raw).slice(0, 30)) {
    const k = String(key).slice(0, 60);
    if (SECRET_KEY.test(k)) { out[k] = '***'; continue; }
    if (typeof value === 'number' || typeof value === 'boolean' || value === null) out[k] = value;
    else out[k] = clip(typeof value === 'string' ? value : JSON.stringify(value), 500);
  }
  return out;
}

export function normalizeEvent(raw, { householdId, deviceId, sessionId, appVersion, platform }) {
  if (!raw || typeof raw !== 'object') return null;
  const level = String(raw.lvl ?? raw.level ?? '').toLowerCase();
  const message = clip(raw.msg ?? raw.message, 500);
  const category = clip(raw.cat ?? raw.category, 40);
  if (!LEVELS.has(level) || !message || !category) return null;
  const at = new Date(raw.t ?? raw.time ?? Date.now());
  const now = Date.now();
  // Clamp bad device clocks to "now" rather than dropping the row.
  const occurredAt = Number.isNaN(at.getTime()) || Math.abs(at.getTime() - now) > 30 * 86400000 ? new Date(now) : at;
  const profile = Number(raw.profile);
  return {
    householdId,
    deviceId,
    sessionId: clip(raw.session ?? sessionId, 64) ?? 'unknown',
    profileId: Number.isSafeInteger(profile) && profile >= 1 && profile <= 1000000 ? profile : null,
    appVersion: clip(raw.app ?? appVersion, 64),
    platform: clip(raw.platform ?? platform, 32),
    occurredAt: occurredAt.toISOString(),
    level,
    category,
    message,
    error: clip(raw.err ?? raw.error, 2000),
    hint: clip(raw.hint, 600),
    details: cleanDetails(raw.details),
  };
}

export function registerTelemetryRoutes(app, { store, deviceLimit, options = {} }) {
  const limit = deviceLimit ?? ((req, res, next) => next());
  const retentionDays = Number(options.retentionDays ?? 90);
  const logger = options.logger ?? console;
  let lastPrune = 0;

  async function device(req) {
    const authorization = req.get('authorization') ?? '';
    const token = authorization.startsWith('Bearer ') ? authorization.slice(7).trim() : '';
    const found = token ? await store.authenticateDevice(token) : null;
    if (!found) throw new TelemetryError(401, 'Device authentication required.');
    return found;
  }

  app.post('/api/device/telemetry', limit, async (req, res, next) => {
    try {
      const found = await device(req);
      const body = req.body ?? {};
      if (!Array.isArray(body.events)) throw new TelemetryError(400, 'events must be an array.');
      if (body.events.length > MAX_BATCH) throw new TelemetryError(413, `At most ${MAX_BATCH} events per batch.`);
      const context = {
        householdId: found.household_id,
        deviceId: found.id,
        sessionId: body.sessionId,
        appVersion: body.appVersion,
        platform: body.platform,
      };
      const rows = body.events.map(e => normalizeEvent(e, context)).filter(Boolean);
      const stored = await store.insertEvents(rows);
      if (retentionDays > 0 && Date.now() - lastPrune > 6 * 3600000) {
        lastPrune = Date.now();
        store.prune(retentionDays).catch(error => logger.error('Telemetry prune failed', error));
      }
      res.json({ ok: true, stored, rejected: body.events.length - rows.length });
    } catch (error) {
      if (error instanceof TelemetryError) return res.status(error.status).json({ error: error.message });
      next(error);
    }
  });

  // Mounted under /api/admin, so the existing admin auth middleware applies.
  app.get('/api/admin/telemetry/summary', async (req, res, next) => {
    try {
      const days = Math.min(90, Math.max(1, Number(req.query.days ?? 7) || 7));
      const householdId = /^[0-9a-f-]{36}$/i.test(String(req.query.household ?? '')) ? String(req.query.household) : null;
      res.json({ days, ...(await store.summary({ days, householdId })) });
    } catch (error) {
      next(error);
    }
  });
}
