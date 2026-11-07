// Millitop TV cloud DVR recorder.
//
// Recordings run on the dashboard host (not on the viewing device) so they
// keep going when the app is closed, and every paired device in the household
// can list and stream the finished file. Each recording is one ffmpeg process
// that stream-copies the channel into an MPEG-TS file. MPEG-TS stays playable
// even if the process is killed, so an unexpected restart still leaves a
// usable partial recording.
import { spawn as nodeSpawn } from 'node:child_process';
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class DvrError extends Error {
  constructor(status, message) {
    super(message);
    this.name = 'DvrError';
    this.status = status;
  }
}

export function isUuid(value) {
  return typeof value === 'string' && uuidPattern.test(value);
}

export function validateStreamUrl(value) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new DvrError(400, 'This channel has no stream address to record.');
  }
  const trimmed = value.trim();
  if (trimmed.length > 4096) {
    throw new DvrError(400, 'The channel stream address is too long.');
  }
  let parsed;
  try {
    parsed = new URL(trimmed);
  } catch (_) {
    throw new DvrError(400, 'The channel stream address is not valid.');
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new DvrError(400, 'Only HTTP and HTTPS live channels can be recorded.');
  }
  return parsed.toString();
}

// Short-lived signed playback links. Media players (mpv/ExoPlayer) cannot
// always send an Authorization header, so the device asks for a recording
// list (authenticated) and receives per-recording URLs signed with HMAC.
export class DvrSigner {
  constructor(secret, { now = () => Date.now() } = {}) {
    this.key = secret && String(secret).length >= 16
      ? Buffer.from(String(secret))
      : randomBytes(32);
    this.now = now;
  }

  sign(recordingId, householdId, expiresAt) {
    return createHmac('sha256', this.key)
      .update(`${recordingId}.${householdId}.${expiresAt}`)
      .digest('base64url');
  }

  playbackPath(recordingId, householdId, ttlSeconds = 12 * 60 * 60) {
    const expiresAt = Math.floor(this.now() / 1000) + ttlSeconds;
    const sig = this.sign(recordingId, householdId, expiresAt);
    return `/api/dvr/recordings/${recordingId}/stream?exp=${expiresAt}&sig=${sig}`;
  }

  verify(recordingId, householdId, exp, sig) {
    const expiresAt = Number(exp);
    if (!Number.isSafeInteger(expiresAt) || expiresAt < this.now() / 1000) {
      return false;
    }
    if (typeof sig !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(sig)) {
      return false;
    }
    const expected = Buffer.from(this.sign(recordingId, householdId, expiresAt));
    const actual = Buffer.from(sig);
    return expected.length === actual.length && timingSafeEqual(expected, actual);
  }
}

export class DvrRecorder {
  constructor({
    storageDir,
    ffmpegPath = 'ffmpeg',
    spawn = nodeSpawn,
    onFinished = async () => {},
    startupProbeMs = 8000,
    stopGraceMs = 10000,
    minFreeBytes = 5 * 1024 * 1024 * 1024,
    statfs = fs.statfs?.bind(fs),
    logger = console,
  } = {}) {
    if (!storageDir) {
      throw new Error('DVR storage directory is required.');
    }
    this.storageDir = path.resolve(storageDir);
    this.ffmpegPath = ffmpegPath;
    this.spawn = spawn;
    this.onFinished = onFinished;
    this.startupProbeMs = startupProbeMs;
    this.stopGraceMs = stopGraceMs;
    this.minFreeBytes = minFreeBytes;
    this.statfs = statfs;
    this.logger = logger;
    this.jobs = new Map();
  }

  filePathFor(householdId, recordingId) {
    if (!isUuid(householdId) || !isUuid(recordingId)) {
      throw new DvrError(400, 'Invalid recording identifier.');
    }
    return path.join(this.storageDir, householdId.toLowerCase(), `${recordingId.toLowerCase()}.ts`);
  }

  isActive(recordingId) {
    return this.jobs.has(recordingId);
  }

  activeIds() {
    return [...this.jobs.keys()];
  }

  buildArgs(streamUrl, filePath, durationMs) {
    const args = [
      '-hide_banner',
      '-nostdin',
      '-loglevel', 'error',
      '-y',
      // Only network protocols may be opened from a device-supplied URL.
      '-protocol_whitelist', 'http,https,tcp,tls,crypto,hls,httpproxy',
      '-user_agent', 'MillitopTV-DVR/1.0',
      '-reconnect', '1',
      '-reconnect_streamed', '1',
      '-reconnect_on_network_error', '1',
      '-reconnect_delay_max', '10',
      '-rw_timeout', '30000000',
      '-i', streamUrl,
      '-map', '0:v?',
      '-map', '0:a?',
      '-c', 'copy',
      '-f', 'mpegts',
    ];
    if (durationMs && durationMs > 0) {
      args.push('-t', (durationMs / 1000).toFixed(1));
    }
    args.push(filePath);
    return args;
  }

  async _ensureSpace(dir) {
    if (!this.statfs || !this.minFreeBytes) {
      return;
    }
    try {
      const stats = await this.statfs(dir);
      const free = Number(stats.bavail) * Number(stats.bsize);
      if (Number.isFinite(free) && free < this.minFreeBytes) {
        throw new DvrError(507, 'The DVR storage is almost full. Delete old recordings and try again.');
      }
    } catch (error) {
      if (error instanceof DvrError) throw error;
    }
  }

  async _size(filePath) {
    try {
      return (await fs.stat(filePath)).size;
    } catch (_) {
      return 0;
    }
  }

  async start({ recordingId, householdId, streamUrl, durationMs = 0, maxDurationMs = 0 }) {
    if (this.jobs.has(recordingId)) {
      throw new DvrError(409, 'This recording is already running.');
    }
    const url = validateStreamUrl(streamUrl);
    const filePath = this.filePathFor(householdId, recordingId);
    const dir = path.dirname(filePath);
    await fs.mkdir(dir, { recursive: true });
    await this._ensureSpace(dir);

    const child = this.spawn(this.ffmpegPath, this.buildArgs(url, filePath, durationMs), {
      stdio: ['ignore', 'ignore', 'pipe'],
      windowsHide: true,
    });
    const job = {
      child,
      filePath,
      householdId,
      stopping: false,
      reason: '',
      stderr: '',
      exited: false,
      timer: null,
      killTimer: null,
    };
    child.stderr?.on('data', chunk => {
      job.stderr = (job.stderr + chunk.toString()).slice(-2000);
    });
    let spawnError = null;
    job.finished = new Promise(resolve => {
      const finish = async (code, signal) => {
        if (job.exited) return;
        job.exited = true;
        clearTimeout(job.timer);
        clearTimeout(job.killTimer);
        this.jobs.delete(recordingId);
        const sizeBytes = await this._size(filePath);
        const result = {
          recordingId,
          householdId,
          filePath,
          sizeBytes,
          code,
          signal,
          stopped: job.stopping,
          reason: job.reason,
          error: spawnError ? String(spawnError.message ?? spawnError) : job.stderr.trim(),
        };
        try {
          await this.onFinished(result);
        } catch (error) {
          this.logger.error?.(`DVR finalize failed for ${recordingId}: ${error?.message ?? error}`);
        }
        resolve(result);
      };
      child.once('error', error => {
        spawnError = error;
        finish(-1, null);
      });
      child.once('exit', (code, signal) => finish(code, signal));
    });
    this.jobs.set(recordingId, job);

    if (!durationMs && maxDurationMs > 0) {
      job.timer = setTimeout(() => {
        this.stop(recordingId, 'Reached the maximum recording length.').catch(() => {});
      }, maxDurationMs);
      job.timer.unref?.();
    }

    // Wait until ffmpeg either writes data (stream opened) or fails.
    const deadline = Date.now() + this.startupProbeMs;
    while (Date.now() < deadline) {
      if (job.exited) {
        const result = await job.finished;
        const detail = result.error ? ` (${result.error.split('\n').pop().slice(0, 200)})` : '';
        throw new DvrError(502, `The channel stream could not be opened for recording${detail}.`);
      }
      if ((await this._size(filePath)) > 0) {
        break;
      }
      await new Promise(r => setTimeout(r, 200));
    }
    return { filePath };
  }

  async stop(recordingId, reason = '') {
    const job = this.jobs.get(recordingId);
    if (!job) {
      return null;
    }
    if (!job.stopping) {
      job.stopping = true;
      job.reason = reason;
      // SIGINT lets ffmpeg flush and close the file cleanly.
      try { job.child.kill('SIGINT'); } catch (_) {}
      job.killTimer = setTimeout(() => {
        try { job.child.kill('SIGKILL'); } catch (_) {}
      }, this.stopGraceMs);
      job.killTimer.unref?.();
    }
    return job.finished;
  }

  async shutdown() {
    await Promise.all(this.activeIds().map(id => this.stop(id, 'The DVR server restarted.')));
  }

  async remove(householdId, recordingId) {
    await this.stop(recordingId, 'Deleted.');
    await fs.rm(this.filePathFor(householdId, recordingId), { force: true });
  }
}
