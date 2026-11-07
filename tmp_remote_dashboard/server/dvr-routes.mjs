// Cloud DVR routes. Recordings are household-scoped: any device paired to the
// household can see, play, stop, and delete them, matching how other Millitop
// state syncs across paired devices.
//
//   POST /api/device/live-tv/dvr             start | stop | status
//   POST /api/device/live-tv/dvr/schedule    list | upsert | remove
//   POST /api/device/live-tv/dvr/recordings  list | delete
//   GET  /api/dvr/recordings/:id/stream      signed, Range-capable playback
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { DvrError, isUuid, validateStreamUrl } from './dvr-recorder.mjs';

function text(value, field, max) {
  const cleaned = String(value ?? '').trim();
  if (!cleaned) {
    throw new DvrError(400, `${field} is required.`);
  }
  return cleaned.slice(0, max);
}

function parseProfileId(value) {
  const profileId = Number(value);
  if (!Number.isSafeInteger(profileId) || profileId < 1 || profileId > 1000000) {
    throw new DvrError(400, 'Profile ID must be a positive integer.');
  }
  return profileId;
}

function iso(value) {
  return value ? new Date(value).toISOString() : null;
}

export function publicRecording(row, { signer, deviceId, active = false }) {
  const started = row.started_at ? new Date(row.started_at) : null;
  const ended = row.ended_at ? new Date(row.ended_at) : null;
  const durationSeconds = started
    ? Math.max(0, Math.round(((ended ?? new Date()).getTime() - started.getTime()) / 1000))
    : 0;
  const playable = row.status !== 'failed' && (Number(row.size_bytes) > 0 || active);
  return {
    id: row.id,
    recordingId: row.id,
    title: row.title,
    channelName: row.channel_name,
    channelId: row.channel_id,
    sourceId: row.source_id,
    profileId: row.profile_id,
    scheduleId: row.schedule_id ?? null,
    status: row.status,
    startedAtUtc: iso(row.started_at),
    recordedAtUtc: iso(row.started_at),
    endedAtUtc: iso(row.ended_at),
    durationSeconds,
    sizeBytes: Number(row.size_bytes ?? 0),
    note: row.note ?? null,
    startedByThisDevice: deviceId ? row.started_by_device === deviceId : false,
    playbackPath: playable ? signer.playbackPath(row.id, row.household_id) : null,
  };
}

function publicSchedule(row) {
  return {
    id: row.id,
    scheduleId: row.id,
    title: row.title,
    channelName: row.channel_name,
    channelId: row.channel_id,
    sourceId: row.source_id,
    profileId: row.profile_id,
    status: row.status,
    startUtc: iso(row.start_utc),
    endUtc: iso(row.end_utc),
    recordingId: row.recording_id ?? null,
  };
}

export function registerDvrRoutes(app, { store, recorder, signer, deviceLimit, options = {} }) {
  const maxConcurrent = Number(options.maxConcurrent ?? 4);
  const maxRecordingMs = Number(options.maxRecordingHours ?? 4) * 60 * 60 * 1000;
  const postPaddingMs = Number(options.postPaddingSeconds ?? 60) * 1000;
  const schedulerIntervalMs = Number(options.schedulerIntervalMs ?? 20000);
  const logger = options.logger ?? console;
  const limit = deviceLimit ?? ((req, res, next) => next());

  // Persist the outcome whenever an ffmpeg job ends (stop, failure, timeout).
  recorder.onFinished = async result => {
    const failed = result.sizeBytes <= 0;
    const note = failed
      ? (result.error ? `Recording failed: ${result.error.split('\n').pop().slice(0, 240)}` : 'Recording produced no video.')
      : (result.reason || (!result.stopped && result.code !== 0 ? 'The channel stream ended unexpectedly.' : null));
    const row = await store.finishRecording(result.recordingId, {
      status: failed ? 'failed' : 'completed',
      sizeBytes: result.sizeBytes,
      note,
    });
    if (row?.schedule_id) {
      await store.finishSchedule(row.schedule_id, {
        status: failed ? 'failed' : 'completed',
        recordingId: row.id,
      });
    }
  };

  async function device(req) {
    const authorization = req.get('authorization') ?? '';
    const token = authorization.startsWith('Bearer ') ? authorization.slice(7).trim() : '';
    if (!token) {
      throw new DvrError(401, 'Device authentication required.');
    }
    const found = await store.authenticateDevice(token);
    if (!found) {
      throw new DvrError(401, 'Device authentication required.');
    }
    return found;
  }

  function handle(fn) {
    return async (req, res, next) => {
      try {
        const body = await fn(req, res);
        if (!res.headersSent) res.json(body);
      } catch (error) {
        if (error instanceof DvrError) {
          return res.status(error.status).json({ error: error.message });
        }
        return next(error);
      }
    };
  }

  async function startRecording({ householdId, deviceId, profileId, sourceId, channelId, channelName, title, streamUrl, scheduleId = null, durationMs = 0 }) {
    const existing = await store.findActiveByChannel(householdId, channelId);
    if (existing && recorder.isActive(existing.id)) {
      return { row: existing, alreadyRecording: true };
    }
    if (existing) {
      // Stale row from a crashed process; close it before starting again.
      await store.finishRecording(existing.id, { status: 'completed', sizeBytes: Number(existing.size_bytes ?? 0), note: 'Recording was interrupted.' });
    }
    if ((await store.countActive(householdId)) >= maxConcurrent) {
      throw new DvrError(429, `Your household is already recording ${maxConcurrent} channels. Stop one and try again.`);
    }
    const id = randomUUID();
    const row = await store.insertRecording({ id, householdId, profileId, deviceId, scheduleId, sourceId, channelId, channelName, title });
    try {
      await recorder.start({ recordingId: id, householdId, streamUrl, durationMs, maxDurationMs: maxRecordingMs });
    } catch (error) {
      if (recorder.isActive(id)) await recorder.stop(id).catch(() => {});
      // onFinished normally records the failure; make sure the row is closed.
      const current = await store.getRecording(id);
      if (current?.status === 'recording') {
        await store.finishRecording(id, { status: 'failed', sizeBytes: 0, note: error.message });
      }
      throw error;
    }
    return { row: (await store.getRecording(id)) ?? row, alreadyRecording: false };
  }

  app.post('/api/device/live-tv/dvr', limit, handle(async req => {
    const d = await device(req);
    const action = String(req.body?.action ?? '').trim().toLowerCase();
    const view = row => publicRecording(row, { signer, deviceId: d.id, active: recorder.isActive(row.id) });

    if (action === 'status') {
      const rows = await store.listRecordings(d.household_id, { activeOnly: true });
      return { recordings: rows.filter(r => recorder.isActive(r.id)).map(view) };
    }
    if (action === 'start') {
      const profileId = parseProfileId(req.body?.profileId);
      const channelName = text(req.body?.channelName, 'Channel name', 200);
      const { row, alreadyRecording } = await startRecording({
        householdId: d.household_id,
        deviceId: d.id,
        profileId,
        sourceId: text(req.body?.sourceId, 'Source', 200),
        channelId: text(req.body?.channelId, 'Channel', 400),
        channelName,
        title: String(req.body?.title ?? '').trim().slice(0, 300) || `${channelName} recording`,
        streamUrl: validateStreamUrl(req.body?.streamUrl),
      });
      return { recording: view(row), alreadyRecording };
    }
    if (action === 'stop') {
      let row = null;
      if (req.body?.recordingId != null) {
        if (!isUuid(String(req.body.recordingId))) throw new DvrError(400, 'Invalid recording.');
        row = await store.getRecording(String(req.body.recordingId));
      } else if (req.body?.channelId) {
        row = await store.findActiveByChannel(d.household_id, String(req.body.channelId));
      }
      if (!row || row.household_id !== d.household_id) {
        throw new DvrError(404, 'No active recording was found for this channel.');
      }
      if (recorder.isActive(row.id)) {
        await recorder.stop(row.id);
      } else if (row.status === 'recording') {
        await store.finishRecording(row.id, { status: 'completed', sizeBytes: Number(row.size_bytes ?? 0), note: 'Recording was interrupted.' });
      }
      const finished = await store.getRecording(row.id);
      return { recording: view(finished) };
    }
    throw new DvrError(400, 'Unsupported DVR action.');
  }));

  app.post('/api/device/live-tv/dvr/recordings', limit, handle(async req => {
    const d = await device(req);
    const action = String(req.body?.action ?? 'list').trim().toLowerCase();
    if (action === 'list') {
      const rows = await store.listRecordings(d.household_id);
      return {
        recordings: rows.map(row => publicRecording(row, { signer, deviceId: d.id, active: recorder.isActive(row.id) })),
      };
    }
    if (action === 'delete') {
      const id = String(req.body?.recordingId ?? '');
      if (!isUuid(id)) throw new DvrError(400, 'Invalid recording.');
      const row = await store.getRecording(id);
      if (!row || row.household_id !== d.household_id || row.deleted_at) {
        throw new DvrError(404, 'Recording not found.');
      }
      await recorder.remove(d.household_id, id);
      await store.markDeleted(d.household_id, id);
      return { deleted: true };
    }
    throw new DvrError(400, 'Unsupported recordings action.');
  }));

  app.post('/api/device/live-tv/dvr/schedule', limit, handle(async req => {
    const d = await device(req);
    const action = String(req.body?.action ?? '').trim().toLowerCase();
    if (action === 'list') {
      return { schedules: (await store.listSchedules(d.household_id)).map(publicSchedule) };
    }
    if (action === 'upsert') {
      const startUtc = new Date(String(req.body?.startUtc ?? ''));
      const endUtc = new Date(String(req.body?.endUtc ?? ''));
      if (Number.isNaN(startUtc.getTime()) || Number.isNaN(endUtc.getTime()) || endUtc <= startUtc) {
        throw new DvrError(400, 'The program start and end times are invalid.');
      }
      if (endUtc <= new Date()) {
        throw new DvrError(400, 'That program has already ended.');
      }
      if (endUtc - startUtc > maxRecordingMs) {
        throw new DvrError(400, 'That program is longer than the maximum recording length.');
      }
      const row = await store.upsertSchedule({
        id: randomUUID(),
        householdId: d.household_id,
        profileId: parseProfileId(req.body?.profileId),
        deviceId: d.id,
        sourceId: text(req.body?.sourceId, 'Source', 200),
        channelId: text(req.body?.channelId, 'Channel', 400),
        channelName: text(req.body?.channelName, 'Channel name', 200),
        title: text(req.body?.title, 'Program title', 300),
        streamUrl: validateStreamUrl(req.body?.streamUrl),
        startUtc: startUtc.toISOString(),
        endUtc: endUtc.toISOString(),
      });
      // Programs already in progress start right away.
      queueMicrotask(() => tick().catch(() => {}));
      return { saved: true, schedule: publicSchedule(row) };
    }
    if (action === 'remove') {
      const id = String(req.body?.scheduleId ?? '');
      if (!isUuid(id)) throw new DvrError(400, 'Invalid schedule.');
      const row = await store.cancelSchedule(d.household_id, id);
      if (!row) throw new DvrError(404, 'Schedule not found.');
      if (row.recording_id && recorder.isActive(row.recording_id)) {
        await recorder.stop(row.recording_id, 'Schedule cancelled.');
      }
      return { removed: true };
    }
    throw new DvrError(400, 'Unsupported schedule action.');
  }));

  app.get('/api/dvr/recordings/:id/stream', async (req, res, next) => {
    try {
      const id = String(req.params.id ?? '');
      if (!isUuid(id)) return res.status(404).json({ error: 'Recording not found.' });
      const row = await store.getRecording(id);
      if (!row || row.deleted_at || !signer.verify(id, row.household_id, req.query.exp, req.query.sig)) {
        return res.status(403).json({ error: 'This playback link is invalid or expired. Refresh the DVR list.' });
      }
      const filePath = recorder.filePathFor(row.household_id, id);
      try {
        await fs.access(filePath);
      } catch (_) {
        return res.status(404).json({ error: 'The recording file is missing.' });
      }
      res.setHeader('Cache-Control', 'private, no-store');
      return res.sendFile(filePath, {
        acceptRanges: true,
        dotfiles: 'deny',
        headers: { 'Content-Type': 'video/mp2t' },
      }, error => {
        if (error && !res.headersSent) next(error);
      });
    } catch (error) {
      return next(error);
    }
  });

  // --- Scheduler and crash recovery -------------------------------------
  // Concurrent callers share one in-flight run so a schedule is never
  // claimed by one tick and reported as idle by another.
  let running = null;
  function tick() {
    running ??= runTick().finally(() => { running = null; });
    return running;
  }
  async function runTick() {
    {
      await store.expireMissedSchedules();
      for (const s of await store.claimDueSchedules()) {
        const durationMs = Math.max(30000, new Date(s.end_utc).getTime() - Date.now() + postPaddingMs);
        try {
          const { row } = await startRecording({
            householdId: s.household_id,
            deviceId: s.created_by_device,
            profileId: s.profile_id,
            sourceId: s.source_id,
            channelId: s.channel_id,
            channelName: s.channel_name,
            title: s.title,
            streamUrl: s.stream_url,
            scheduleId: s.id,
            durationMs,
          });
          await store.finishSchedule(s.id, { status: 'recording', recordingId: row.id });
        } catch (error) {
          logger.error?.(`DVR schedule ${s.id} failed to start: ${error?.message ?? error}`);
          await store.finishSchedule(s.id, { status: 'failed' });
        }
      }
    }
  }

  async function recover() {
    for (const row of await store.listRecordingRowsForRecovery()) {
      if (recorder.isActive(row.id)) continue;
      let size = 0;
      try {
        size = (await fs.stat(recorder.filePathFor(row.household_id, row.id))).size;
      } catch (_) {}
      const done = await store.finishRecording(row.id, {
        status: size > 0 ? 'completed' : 'failed',
        sizeBytes: size,
        note: 'Recording was interrupted when the DVR server restarted.',
      });
      if (done?.schedule_id) {
        await store.finishSchedule(done.schedule_id, { status: size > 0 ? 'completed' : 'failed', recordingId: done.id });
      }
    }
  }

  let timer = null;
  const ready = recover()
    .catch(error => logger.error?.(`DVR recovery failed: ${error?.message ?? error}`))
    .then(() => {
      if (schedulerIntervalMs > 0) {
        timer = setInterval(() => tick().catch(error => logger.error?.(`DVR scheduler failed: ${error?.message ?? error}`)), schedulerIntervalMs);
        timer.unref?.();
      }
    });

  return {
    ready,
    tick,
    async shutdown() {
      clearInterval(timer);
      await recorder.shutdown();
    },
  };
}
