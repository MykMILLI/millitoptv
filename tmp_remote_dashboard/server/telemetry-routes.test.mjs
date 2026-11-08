import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { registerTelemetryRoutes, normalizeEvent, redact } from './telemetry-routes.mjs';

const HH = '33333333-3333-4333-8333-333333333333';
const DEV = '55555555-5555-4555-8555-555555555555';

class MemoryStore {
  constructor() { this.rows = []; }
  async authenticateDevice(token) { return token === 'tok' ? { id: DEV, household_id: HH } : null; }
  async insertEvents(rows) { this.rows.push(...rows); return rows.length; }
  async prune() {}
  async summary() { return { totals: { error: this.rows.filter(r => r.level === 'error').length } }; }
  async recentEvents({ sinceId = null, category = null, level = null, limit = 100 } = {}) {
    return this.rows
      .map((row, index) => ({ id: index + 1, ...row }))
      .filter(row => (sinceId == null || row.id > sinceId))
      .filter(row => (!category || row.category === category))
      .filter(row => (!level || row.level === level))
      .slice(0, limit);
  }
}

async function harness() {
  const store = new MemoryStore();
  const app = express();
  app.use(express.json({ limit: '1mb' }));
  registerTelemetryRoutes(app, { store, options: { logger: { error() {} } } });
  const server = await new Promise(r => { const s = app.listen(0, '127.0.0.1', () => r(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (body, token = 'tok') => fetch(`${base}/api/device/telemetry`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  return { store, base, post, close: () => server.close() };
}

test('redact removes credentials from URLs and headers', () => {
  assert.equal(redact('http://u:p@host/x'), 'http://***:***@host/x');
  assert.equal(redact('http://h/player_api.php?username=bob&password=secret'), 'http://h/player_api.php?username=***&password=***');
  assert.equal(redact('http://h/movie/bob/secret/1.mp4'), 'http://h/movie/***/***/1.mp4');
  assert.equal(redact('MediaBrowser Token="abc"'), 'MediaBrowser Token="***"');
});

test('normalizeEvent validates and trims fields', () => {
  const ctx = { householdId: HH, deviceId: DEV, sessionId: 's1', appVersion: '1.0', platform: 'windows' };
  assert.equal(normalizeEvent({ lvl: 'loud', cat: 'x', msg: 'y' }, ctx), null);
  const row = normalizeEvent({ lvl: 'error', cat: 'catalog', msg: 'x'.repeat(900), details: { apiKey: 'k', ms: 5 }, t: '1999-01-01T00:00:00Z' }, ctx);
  assert.equal(row.message.length, 500);
  assert.equal(row.details.apiKey, '***');
  assert.equal(row.details.ms, 5);
  assert.ok(new Date(row.occurredAt).getFullYear() >= 2024, 'bad clock clamped');
});

test('device upload requires auth and stores valid rows', async () => {
  const h = await harness();
  try {
    assert.equal((await h.post({ events: [] }, null)).status, 401);
    assert.equal((await h.post({ events: 'nope' })).status, 400);
    assert.equal((await h.post({ events: Array.from({ length: 201 }, () => ({})) })).status, 413);
    const res = await h.post({
      sessionId: 'abc', appVersion: '2.0+5', platform: 'windows',
      events: [
        { t: new Date().toISOString(), lvl: 'error', cat: 'jellyfin', msg: 'GET /Items failed', err: 'SocketException http://u:p@h', hint: 'Check network' },
        { t: new Date().toISOString(), lvl: 'info', cat: 'analytics', msg: 'media.play', details: { seconds: 30 } },
        { lvl: 'bogus' },
      ],
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.stored, 2);
    assert.equal(body.rejected, 1);
    assert.equal(h.store.rows[0].householdId, HH);
    assert.equal(h.store.rows[0].error, 'SocketException http://***:***@h');
    assert.equal(h.store.rows[1].platform, 'windows');
  } finally {
    h.close();
  }
});

test('admin recent events endpoint filters and cursors', async () => {
  const h = await harness();
  try {
    await h.post({
      sessionId: 'abc',
      appVersion: '2.0+5',
      platform: 'android',
      events: [
        { t: new Date().toISOString(), lvl: 'info', cat: 'analytics', msg: 'screen.view' },
        { t: new Date().toISOString(), lvl: 'warn', cat: 'playback', msg: 'live_tv.buffer.end', details: { bufferedMs: 6200 } },
      ],
    });
    const first = await fetch(`${h.base}/api/admin/telemetry/events?category=playback`);
    assert.equal(first.status, 200);
    const one = await first.json();
    assert.equal(one.events.length, 1);
    assert.equal(one.events[0].category, 'playback');
    const second = await fetch(`${h.base}/api/admin/telemetry/events?sinceId=${one.nextSinceId}`);
    assert.equal(second.status, 200);
    const two = await second.json();
    assert.equal(two.events.length, 0);
  } finally {
    h.close();
  }
});
