// PostgreSQL persistence for the cloud DVR. Tables live in dvr-schema.sql.
import { createHash } from 'node:crypto';

const T = 'millitop_tv';

function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

export class PgDvrStore {
  constructor(pool) {
    this.pool = pool;
  }

  async authenticateDevice(token) {
    const result = await this.pool.query(
      `SELECT d.id, d.household_id
       FROM ${T}.device_credentials c
       JOIN ${T}.devices d ON d.id = c.device_id
       JOIN ${T}.households h ON h.id = d.household_id
       WHERE c.token_hash = $1
         AND c.revoked_at IS NULL
         AND (c.expires_at IS NULL OR c.expires_at > now())
         AND d.revoked_at IS NULL
         AND h.active = true`,
      [digest(token)]
    );
    return result.rowCount ? result.rows[0] : null;
  }

  async countActive(householdId) {
    const r = await this.pool.query(
      `SELECT count(*)::int AS n FROM ${T}.dvr_recordings
       WHERE household_id = $1 AND status = 'recording'`,
      [householdId]
    );
    return r.rows[0].n;
  }

  async findActiveByChannel(householdId, channelId) {
    const r = await this.pool.query(
      `SELECT * FROM ${T}.dvr_recordings
       WHERE household_id = $1 AND channel_id = $2 AND status = 'recording'
       LIMIT 1`,
      [householdId, channelId]
    );
    return r.rows[0] ?? null;
  }

  async insertRecording(rec) {
    const r = await this.pool.query(
      `INSERT INTO ${T}.dvr_recordings
         (id, household_id, profile_id, started_by_device, schedule_id, source_id,
          channel_id, channel_name, title, status, started_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'recording',now())
       RETURNING *`,
      [rec.id, rec.householdId, rec.profileId, rec.deviceId, rec.scheduleId ?? null,
        rec.sourceId, rec.channelId, rec.channelName, rec.title]
    );
    return r.rows[0];
  }

  async finishRecording(id, { status, sizeBytes, note }) {
    const r = await this.pool.query(
      `UPDATE ${T}.dvr_recordings
       SET status = $2, size_bytes = $3, note = $4, ended_at = COALESCE(ended_at, now())
       WHERE id = $1
       RETURNING *`,
      [id, status, sizeBytes, note ?? null]
    );
    return r.rows[0] ?? null;
  }

  async getRecording(id) {
    const r = await this.pool.query(`SELECT * FROM ${T}.dvr_recordings WHERE id = $1`, [id]);
    return r.rows[0] ?? null;
  }

  async listRecordings(householdId, { activeOnly = false } = {}) {
    const r = await this.pool.query(
      `SELECT * FROM ${T}.dvr_recordings
       WHERE household_id = $1 AND deleted_at IS NULL
         ${activeOnly ? "AND status = 'recording'" : ''}
       ORDER BY started_at DESC
       LIMIT 500`,
      [householdId]
    );
    return r.rows;
  }

  async markDeleted(householdId, id) {
    const r = await this.pool.query(
      `UPDATE ${T}.dvr_recordings SET deleted_at = now()
       WHERE household_id = $1 AND id = $2 AND deleted_at IS NULL
       RETURNING id`,
      [householdId, id]
    );
    return r.rowCount > 0;
  }

  async listRecordingRowsForRecovery() {
    const r = await this.pool.query(
      `SELECT id, household_id FROM ${T}.dvr_recordings WHERE status = 'recording'`
    );
    return r.rows;
  }

  async listSchedules(householdId) {
    const r = await this.pool.query(
      `SELECT * FROM ${T}.dvr_schedules
       WHERE household_id = $1 AND status IN ('scheduled','recording')
       ORDER BY start_utc ASC
       LIMIT 200`,
      [householdId]
    );
    return r.rows;
  }

  async upsertSchedule(s) {
    const r = await this.pool.query(
      `INSERT INTO ${T}.dvr_schedules
         (id, household_id, profile_id, created_by_device, source_id, channel_id,
          channel_name, title, stream_url, start_utc, end_utc, status)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,'scheduled')
       ON CONFLICT (household_id, channel_id, start_utc) WHERE status = 'scheduled'
       DO UPDATE SET title = EXCLUDED.title, end_utc = EXCLUDED.end_utc,
         stream_url = EXCLUDED.stream_url, updated_at = now()
       RETURNING *`,
      [s.id, s.householdId, s.profileId, s.deviceId, s.sourceId, s.channelId,
        s.channelName, s.title, s.streamUrl, s.startUtc, s.endUtc]
    );
    return r.rows[0];
  }

  async cancelSchedule(householdId, id) {
    const r = await this.pool.query(
      `UPDATE ${T}.dvr_schedules SET status = 'cancelled', updated_at = now()
       WHERE household_id = $1 AND id = $2 AND status IN ('scheduled','recording')
       RETURNING *`,
      [householdId, id]
    );
    return r.rows[0] ?? null;
  }

  async expireMissedSchedules() {
    await this.pool.query(
      `UPDATE ${T}.dvr_schedules SET status = 'missed', updated_at = now()
       WHERE status = 'scheduled' AND end_utc <= now()`
    );
  }

  async claimDueSchedules(leadSeconds = 15) {
    const r = await this.pool.query(
      `UPDATE ${T}.dvr_schedules SET status = 'recording', updated_at = now()
       WHERE status = 'scheduled'
         AND start_utc <= now() + make_interval(secs => $1)
         AND end_utc > now()
       RETURNING *`,
      [leadSeconds]
    );
    return r.rows;
  }

  async finishSchedule(id, { status, recordingId }) {
    await this.pool.query(
      `UPDATE ${T}.dvr_schedules
       SET status = $2, recording_id = COALESCE($3, recording_id), updated_at = now()
       WHERE id = $1 AND status IN ('scheduled','recording')`,
      [id, status, recordingId ?? null]
    );
  }
}
