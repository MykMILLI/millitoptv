import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import express from 'express';
import { DvrRecorder, DvrSigner, validateStreamUrl } from './dvr-recorder.mjs';
import { registerDvrRoutes } from './dvr-routes.mjs';

const HH_A = '33333333-3333-4333-8333-333333333333';
const HH_B = '44444444-4444-4444-8444-444444444444';
const DEV_A1 = '55555555-5555-4555-8555-555555555555';
const DEV_A2 = '66666666-6666-4666-8666-666666666666';
const DEV_B = '77777777-7777-4777-8777-777777777777';
const tokens = { tokA1: { id: DEV_A1, household_id: HH_A }, tokA2: { id: DEV_A2, household_id: HH_A }, tokB: { id: DEV_B, household_id: HH_B } };
const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0;

class MemoryStore {
  constructor() { this.recordings = new Map(); this.schedules = new Map(); }
  async authenticateDevice(token) { return tokens[token] ?? null; }
  async countActive(h) { return [...this.recordings.values()].filter(r => r.household_id === h && r.status === 'recording').length; }
  async findActiveByChannel(h, c) { return [...this.recordings.values()].find(r => r.household_id === h && r.channel_id === c && r.status === 'recording') ?? null; }
  async insertRecording(r) {
    const row = { id: r.id, household_id: r.householdId, profile_id: r.profileId, started_by_device: r.deviceId, schedule_id: r.scheduleId, source_id: r.sourceId, channel_id: r.channelId, channel_name: r.channelName, title: r.title, status: 'recording', started_at: new Date(), ended_at: null, size_bytes: 0, note: null, deleted_at: null };
    this.recordings.set(r.id, row); return { ...row };
  }
  async finishRecording(id, { status, sizeBytes, note }) { const r = this.recordings.get(id); if (!r) return null; Object.assign(r, { status, size_bytes: sizeBytes, note: note ?? null, ended_at: r.ended_at ?? new Date() }); return { ...r }; }
  async getRecording(id) { const r = this.recordings.get(id); return r ? { ...r } : null; }
  async listRecordings(h, { activeOnly = false } = {}) { return [...this.recordings.values()].filter(r => r.household_id === h && !r.deleted_at && (!activeOnly || r.status === 'recording')).map(r => ({ ...r })); }
  async markDeleted(h, id) { const r = this.recordings.get(id); if (!r || r.household_id !== h) return false; r.deleted_at = new Date(); return true; }
  async listRecordingRowsForRecovery() { return [...this.recordings.values()].filter(r => r.status === 'recording'); }
  async listSchedules(h) { return [...this.schedules.values()].filter(s => s.household_id === h && ['scheduled', 'recording'].includes(s.status)); }
  async upsertSchedule(s) { const row = { id: s.id, household_id: s.householdId, profile_id: s.profileId, created_by_device: s.deviceId, source_id: s.sourceId, channel_id: s.channelId, channel_name: s.channelName, title: s.title, stream_url: s.streamUrl, start_utc: new Date(s.startUtc), end_utc: new Date(s.endUtc), status: 'scheduled', recording_id: null }; this.schedules.set(s.id, row); return { ...row }; }
  async cancelSchedule(h, id) { const s = this.schedules.get(id); if (!s || s.household_id !== h || !['scheduled', 'recording'].includes(s.status)) return null; s.status = 'cancelled'; return { ...s }; }
  async expireMissedSchedules() { for (const s of this.schedules.values()) if (s.status === 'scheduled' && s.end_utc <= new Date()) s.status = 'missed'; }
  async claimDueSchedules(lead = 15) { const out = []; for (const s of this.schedules.values()) if (s.status === 'scheduled' && s.start_utc.getTime() <= Date.now() + lead * 1000 && s.end_utc > new Date()) { s.status = 'recording'; out.push({ ...s }); } return out; }
  async finishSchedule(id, { status, recordingId }) { const s = this.schedules.get(id); if (s && ['scheduled', 'recording'].includes(s.status)) { s.status = status; s.recording_id = recordingId ?? s.recording_id; } }
}

// Endless MPEG-TS test channel served over HTTP, like an IPTV stream.
function startTestChannel() {
  const children = new Set();
  const server = createServer((req, res) => {
    if (req.url !== '/live/channel.ts') { res.writeHead(404).end(); return; }
    res.writeHead(200, { 'Content-Type': 'video/mp2t' });
    const ff = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-re', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440', '-c:v', 'mpeg2video', '-c:a', 'mp2', '-f', 'mpegts', 'pipe:1'], { stdio: ['ignore', 'pipe', 'ignore'] });
    children.add(ff);
    ff.stdout.pipe(res);
    const end = () => { try { ff.kill('SIGKILL'); } catch (_) {} children.delete(ff); };
    req.on('close', end); res.on('close', end);
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve({
    url: `http://127.0.0.1:${server.address().port}/live/channel.ts`,
    missing: `http://127.0.0.1:${server.address().port}/live/missing.ts`,
    close: () => { for (const c of children) c.kill('SIGKILL'); server.close(); },
  })));
}

async function harness() {
  const storageDir = await mkdtemp(path.join(tmpdir(), 'dvr-'));
  const store = new MemoryStore();
  const recorder = new DvrRecorder({ storageDir, minFreeBytes: 0, startupProbeMs: 8000, logger: { error() {} } });
  const signer = new DvrSigner('test-secret-value-1234567890');
  const app = express();
  app.use(express.json());
  const dvr = registerDvrRoutes(app, { store, recorder, signer, options: { schedulerIntervalMs: 0, logger: { error() {} } } });
  await dvr.ready;
  const server = await new Promise(r => { const s = app.listen(0, '127.0.0.1', () => r(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = async (route, token, body) => {
    const res = await fetch(base + route, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
    return { status: res.status, body: await res.json() };
  };
  return { store, recorder, signer, dvr, base, post, storageDir, close: async () => { await dvr.shutdown(); server.close(); await rm(storageDir, { recursive: true, force: true }); } };
}

test('playback links are signed, expire, and reject tampering', () => {
  let now = 1_800_000_000_000;
  const signer = new DvrSigner('another-test-secret-123456', { now: () => now });
  const p = new URL('http://x' + signer.playbackPath(DEV_A1, HH_A, 60));
  const exp = p.searchParams.get('exp'), sig = p.searchParams.get('sig');
  assert.equal(signer.verify(DEV_A1, HH_A, exp, sig), true);
  assert.equal(signer.verify(DEV_A1, HH_B, exp, sig), false, 'other household');
  assert.equal(signer.verify(DEV_A1, HH_A, String(Number(exp) + 1), sig), false, 'tampered expiry');
  now += 61_000;
  assert.equal(signer.verify(DEV_A1, HH_A, exp, sig), false, 'expired');
});

test('only http and https channel streams are accepted', () => {
  assert.equal(validateStreamUrl(' https://iptv.example/live/1.ts '), 'https://iptv.example/live/1.ts');
  for (const bad of ['file:///etc/passwd', 'rtmp://x/live', 'not a url', '', null]) {
    assert.throws(() => validateStreamUrl(bad));
  }
});

test('DVR routes require a paired device', async () => {
  const h = await harness();
  try {
    const res = await fetch(h.base + '/api/device/live-tv/dvr', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"action":"status"}' });
    assert.equal(res.status, 401);
    assert.equal((await h.post('/api/device/live-tv/dvr', 'bogus', { action: 'status' })).status, 401);
  } finally { await h.close(); }
});

test('record now → stop saves a playable recording visible to every household device', { skip: !hasFfmpeg && 'ffmpeg not installed', timeout: 60000 }, async () => {
  const channel = await startTestChannel();
  const h = await harness();
  try {
    const start = await h.post('/api/device/live-tv/dvr', 'tokA1', { action: 'start', profileId: 1, sourceId: 'src1', channelId: 'src1|tvg:news', channelName: 'News 5', title: 'Evening News', streamUrl: channel.url });
    assert.equal(start.status, 200, JSON.stringify(start.body));
    assert.equal(start.body.recording.status, 'recording');
    const id = start.body.recording.id;

    // Pressing record again on another device does not start a duplicate.
    const again = await h.post('/api/device/live-tv/dvr', 'tokA2', { action: 'start', profileId: 2, sourceId: 'src1', channelId: 'src1|tvg:news', channelName: 'News 5', streamUrl: channel.url });
    assert.equal(again.body.alreadyRecording, true);
    assert.equal(again.body.recording.id, id);

    const status = await h.post('/api/device/live-tv/dvr', 'tokA2', { action: 'status' });
    assert.deepEqual(status.body.recordings.map(r => r.id), [id]);
    assert.equal((await h.post('/api/device/live-tv/dvr', 'tokB', { action: 'status' })).body.recordings.length, 0);

    await new Promise(r => setTimeout(r, 3000));
    const stop = await h.post('/api/device/live-tv/dvr', 'tokA1', { action: 'stop', recordingId: id });
    assert.equal(stop.status, 200);
    assert.equal(stop.body.recording.status, 'completed');
    assert.ok(stop.body.recording.sizeBytes > 10000, `size ${stop.body.recording.sizeBytes}`);
    assert.ok(stop.body.recording.durationSeconds >= 2);

    // Second device in the same household sees and can stream it.
    const list = await h.post('/api/device/live-tv/dvr/recordings', 'tokA2', { action: 'list' });
    assert.equal(list.body.recordings.length, 1);
    const rec = list.body.recordings[0];
    assert.equal(rec.title, 'Evening News');
    assert.equal(rec.startedByThisDevice, false);
    const ranged = await fetch(h.base + rec.playbackPath, { headers: { range: 'bytes=0-187' } });
    assert.equal(ranged.status, 206);
    assert.equal(ranged.headers.get('content-type'), 'video/mp2t');
    const bytes = new Uint8Array(await ranged.arrayBuffer());
    assert.equal(bytes.length, 188);
    assert.equal(bytes[0], 0x47, 'MPEG-TS sync byte');

    const probe = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration:stream=codec_type', '-of', 'json', h.recorder.filePathFor(HH_A, id)], { encoding: 'utf8' });
    const info = JSON.parse(probe.stdout);
    assert.ok(Number(info.format.duration) >= 2, `duration ${info.format.duration}`);
    assert.deepEqual(info.streams.map(s => s.codec_type).sort(), ['audio', 'video']);

    // Other households cannot see, play, or delete it.
    assert.equal((await h.post('/api/device/live-tv/dvr/recordings', 'tokB', { action: 'list' })).body.recordings.length, 0);
    assert.equal((await h.post('/api/device/live-tv/dvr/recordings', 'tokB', { action: 'delete', recordingId: id })).status, 404);
    const forged = rec.playbackPath.replace(/sig=[^&]+/, 'sig=' + 'A'.repeat(43));
    assert.equal((await fetch(h.base + forged)).status, 403);

    const del = await h.post('/api/device/live-tv/dvr/recordings', 'tokA2', { action: 'delete', recordingId: id });
    assert.equal(del.status, 200);
    await assert.rejects(stat(h.recorder.filePathFor(HH_A, id)));
    assert.equal((await h.post('/api/device/live-tv/dvr/recordings', 'tokA1', { action: 'list' })).body.recordings.length, 0);
  } finally { await h.close(); channel.close(); }
});

test('an unreachable channel reports a clear error and saves a failed entry', { skip: !hasFfmpeg && 'ffmpeg not installed', timeout: 30000 }, async () => {
  const channel = await startTestChannel();
  const h = await harness();
  try {
    const res = await h.post('/api/device/live-tv/dvr', 'tokA1', { action: 'start', profileId: 1, sourceId: 's', channelId: 's|x', channelName: 'Broken', streamUrl: channel.missing });
    assert.equal(res.status, 502);
    assert.match(res.body.error, /could not be opened/);
    const rows = await h.store.listRecordings(HH_A);
    assert.equal(rows[0].status, 'failed');
    assert.equal((await h.post('/api/device/live-tv/dvr', 'tokA1', { action: 'status' })).body.recordings.length, 0);
  } finally { await h.close(); channel.close(); }
});

test('a scheduled program in progress starts recording and can be cancelled', { skip: !hasFfmpeg && 'ffmpeg not installed', timeout: 60000 }, async () => {
  const channel = await startTestChannel();
  const h = await harness();
  try {
    const now = Date.now();
    const saved = await h.post('/api/device/live-tv/dvr/schedule', 'tokA1', { action: 'upsert', profileId: 1, sourceId: 's', channelId: 's|tvg:movie', channelName: 'Movies', title: 'Matinee', streamUrl: channel.url, startUtc: new Date(now - 60000).toISOString(), endUtc: new Date(now + 600000).toISOString() });
    assert.equal(saved.status, 200, JSON.stringify(saved.body));
    await h.dvr.tick();
    const list = await h.post('/api/device/live-tv/dvr/schedule', 'tokA2', { action: 'list' });
    assert.equal(list.body.schedules[0].status, 'recording');
    const recId = list.body.schedules[0].recordingId;
    assert.ok(h.recorder.isActive(recId));
    await new Promise(r => setTimeout(r, 1500));
    const removed = await h.post('/api/device/live-tv/dvr/schedule', 'tokA2', { action: 'remove', scheduleId: saved.body.schedule.id });
    assert.equal(removed.status, 200);
    assert.equal(h.recorder.isActive(recId), false);
    const rec = await h.store.getRecording(recId);
    assert.equal(rec.status, 'completed');
    assert.equal(rec.note, 'Schedule cancelled.');
  } finally { await h.close(); channel.close(); }
});

test('recordings left running by a crash are closed on startup', async () => {
  const storageDir = await mkdtemp(path.join(tmpdir(), 'dvr-'));
  const store = new MemoryStore();
  await store.insertRecording({ id: DEV_B, householdId: HH_A, profileId: 1, deviceId: DEV_A1, sourceId: 's', channelId: 'c', channelName: 'C', title: 'T' });
  const recorder = new DvrRecorder({ storageDir, minFreeBytes: 0 });
  const app = express();
  const dvr = registerDvrRoutes(app, { store, recorder, signer: new DvrSigner(), options: { schedulerIntervalMs: 0, logger: { error() {} } } });
  await dvr.ready;
  assert.equal((await store.getRecording(DEV_B)).status, 'failed');
  await rm(storageDir, { recursive: true, force: true });
});
