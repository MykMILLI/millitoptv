// PostgreSQL persistence for app diagnostics/analytics. Table: telemetry-schema.sql.
import { createHash } from 'node:crypto';

const T = 'millitop_tv';

function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

export class PgTelemetryStore {
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

  async insertEvents(rows) {
    if (!rows.length) return 0;
    const cols = ['household_id', 'device_id', 'session_id', 'profile_id', 'app_version', 'platform',
      'occurred_at', 'level', 'category', 'message', 'error', 'hint', 'details'];
    const values = [];
    const tuples = rows.map((row, i) => {
      values.push(row.householdId, row.deviceId, row.sessionId, row.profileId, row.appVersion, row.platform,
        row.occurredAt, row.level, row.category, row.message, row.error, row.hint, JSON.stringify(row.details));
      return `(${cols.map((_, j) => `$${i * cols.length + j + 1}`).join(',')})`;
    });
    const r = await this.pool.query(
      `INSERT INTO ${T}.app_telemetry (${cols.join(',')}) VALUES ${tuples.join(',')}`,
      values
    );
    return r.rowCount;
  }

  async prune(retentionDays) {
    await this.pool.query(
      `DELETE FROM ${T}.app_telemetry WHERE received_at < now() - make_interval(days => $1)`,
      [retentionDays]
    );
  }

  async summary({ days, householdId = null }) {
    const params = [days, householdId];
    const where = `occurred_at > now() - make_interval(days => $1) AND ($2::uuid IS NULL OR household_id = $2::uuid)`;
    const [totals, errors, events, versions, recent] = await Promise.all([
      this.pool.query(`SELECT level, count(*)::int AS n FROM ${T}.app_telemetry WHERE ${where} GROUP BY level`, params),
      this.pool.query(
        `SELECT category, message, max(hint) AS hint, count(*)::int AS n, count(DISTINCT device_id)::int AS devices, max(occurred_at) AS last_seen
         FROM ${T}.app_telemetry WHERE ${where} AND level IN ('warn','error')
         GROUP BY category, message ORDER BY n DESC LIMIT 50`, params),
      this.pool.query(
        `SELECT message AS event, count(*)::int AS n, count(DISTINCT device_id)::int AS devices
         FROM ${T}.app_telemetry WHERE ${where} AND category = 'analytics'
         GROUP BY message ORDER BY n DESC LIMIT 50`, params),
      this.pool.query(
        `SELECT coalesce(app_version,'unknown') AS version, coalesce(platform,'unknown') AS platform,
                count(DISTINCT device_id)::int AS devices, count(DISTINCT session_id)::int AS sessions
         FROM ${T}.app_telemetry WHERE ${where} GROUP BY 1,2 ORDER BY devices DESC LIMIT 50`, params),
      this.pool.query(
        `SELECT occurred_at, level, category, message, error, hint, platform, app_version, device_id
         FROM ${T}.app_telemetry WHERE ${where} AND level = 'error'
         ORDER BY occurred_at DESC LIMIT 100`, params),
    ]);
    return {
      totals: Object.fromEntries(totals.rows.map(r => [r.level, r.n])),
      topProblems: errors.rows,
      topEvents: events.rows,
      versions: versions.rows,
      recentErrors: recent.rows,
    };
  }

  async recentEvents({
    sinceId = null,
    householdId = null,
    category = null,
    level = null,
    limit = 100,
  } = {}) {
    const bounded = Math.min(500, Math.max(1, Number(limit) || 100));
    const params = [sinceId, householdId, category, level, bounded];
    const r = await this.pool.query(
      `SELECT id, occurred_at, received_at, level, category, message, error, hint,
              details, platform, app_version, device_id, session_id, profile_id
         FROM ${T}.app_telemetry
        WHERE ($1::bigint IS NULL OR id > $1::bigint)
          AND ($2::uuid IS NULL OR household_id = $2::uuid)
          AND ($3::text IS NULL OR category = $3::text)
          AND ($4::text IS NULL OR level = $4::text)
        ORDER BY id ASC
        LIMIT $5`,
      params
    );
    return r.rows;
  }
}
