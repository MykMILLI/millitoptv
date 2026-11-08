import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { rateLimit } from 'express-rate-limit';

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function registerDeviceRoutes(app, pool) {
  const enrollmentLimit = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 20,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: {
      error: 'Too many enrollment attempts. Try again later.'
    }
  });

  const heartbeatLimit = rateLimit({
    windowMs: 60 * 1000,
    limit: 120,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: { error: 'Too many device requests.' }
  });

  // Existing /api/admin middleware validates dashboard membership.
  app.post('/api/admin/pairing-codes', async (req, res, next) => {
    const { householdId, deviceName } = req.body ?? {};

    if (
      typeof householdId !== 'string' ||
      !uuidPattern.test(householdId) ||
      typeof deviceName !== 'string' ||
      !deviceName.trim() ||
      deviceName.trim().length > 120
    ) {
      return res.status(400).json({
        error: 'Choose a household and enter a device name.'
      });
    }

    let connection;

    try {
      connection = await pool.connect();
      await connection.query('BEGIN');

      const household = await connection.query(
        `SELECT id FROM millitop_tv.households
         WHERE id = $1 AND active = true
         FOR SHARE`,
        [householdId]
      );

      if (!household.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(404).json({ error: 'Household not found.' });
      }

      const rawCode = randomBytes(6).toString('hex').toUpperCase();

      const result = await connection.query(
        `INSERT INTO millitop_tv.pairing_codes
           (household_id, device_name, code_hash, created_by, expires_at)
         VALUES ($1, $2, $3, $4, now() + interval '10 minutes')
         RETURNING id, expires_at`,
        [
          householdId,
          deviceName.trim(),
          digest(`pairing:${rawCode}`),
          req.admin.id
        ]
      );

      await connection.query(
        `INSERT INTO millitop_tv.audit_log
           (actor_user_id, action, entity_type, entity_id)
         VALUES ($1, 'pairing.created', 'pairing_code', $2)`,
        [req.admin.id, result.rows[0].id]
      );

      await connection.query('COMMIT');

      res.status(201).json({
        code: rawCode.match(/.{1,4}/g).join('-'),
        expiresAt: result.rows[0].expires_at,
        deviceName: deviceName.trim()
      });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      next(error);
    } finally {
      connection?.release();
    }
  });

  app.get('/api/admin/devices', async (req, res, next) => {
    try {
      const result = await pool.query(`
        SELECT
          d.id,
          d.name,
          d.household_id,
          h.name AS household_name,
          d.app_version,
          d.enrolled_at,
          d.last_opened_at,
          d.last_seen_at,
          d.last_activity_at,
          d.reported_state,
          CASE
            WHEN d.last_seen_at > now() - interval '90 seconds'
              THEN 'online'
            ELSE 'offline'
          END AS connection_status
        FROM millitop_tv.devices d
        JOIN millitop_tv.households h ON h.id = d.household_id
        WHERE d.revoked_at IS NULL
        ORDER BY d.enrolled_at DESC
      `);

      res.json(result.rows);
    } catch (error) {
      next(error);
    }
  });

  async function deleteDevice(req, res, next) {
    if (!uuidPattern.test(req.params.id)) {
      return res.status(400).json({ error: 'Invalid device ID.' });
    }

    let connection;

    try {
      connection = await pool.connect();
      await connection.query('BEGIN');

      const result = await connection.query(
        `UPDATE millitop_tv.devices
         SET revoked_at = COALESCE(revoked_at, now())
         WHERE id = $1
         RETURNING id`,
        [req.params.id]
      );

      if (!result.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(404).json({ error: 'Device not found.' });
      }

      await connection.query(
        `UPDATE millitop_tv.device_credentials
         SET revoked_at = COALESCE(revoked_at, now())
         WHERE device_id = $1`,
        [req.params.id]
      );

      await connection.query(
        `INSERT INTO millitop_tv.audit_log
           (actor_user_id, action, entity_type, entity_id)
         VALUES ($1, 'device.deleted', 'device', $2)`,
        [req.admin.id, req.params.id]
      );

      await connection.query('COMMIT');
      res.json({ deleted: true });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      next(error);
    } finally {
      connection?.release();
    }
  }

  app.post('/api/admin/devices/:id/delete', deleteDevice);
  // Backward-compatible alias for older dashboard clients.
  app.post('/api/admin/devices/:id/revoke', deleteDevice);

  app.post('/api/device/enroll', enrollmentLimit, async (req, res, next) => {
    const input = req.body?.code;

    if (typeof input !== 'string' || input.length > 40) {
      return res.status(400).json({ error: 'Enter a valid pairing code.' });
    }

    const code = input.replace(/[-\s]/g, '').toUpperCase();

    if (!/^[0-9A-F]{12}$/.test(code)) {
      return res.status(400).json({ error: 'Enter a valid pairing code.' });
    }

    let connection;

    try {
      connection = await pool.connect();
      await connection.query('BEGIN');

      const pairing = await connection.query(
        `SELECT p.id, p.household_id, p.device_name
         FROM millitop_tv.pairing_codes p
         JOIN millitop_tv.households h ON h.id = p.household_id
         WHERE p.code_hash = $1
           AND p.used_at IS NULL
           AND p.expires_at > now()
           AND h.active = true
         FOR UPDATE OF p`,
        [digest(`pairing:${code}`)]
      );

      if (!pairing.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(400).json({
          error: 'Pairing code is invalid, expired, or already used.'
        });
      }

      const selected = pairing.rows[0];
      const deviceId = randomUUID();
      const token = `mtv_${randomBytes(32).toString('base64url')}`;

      await connection.query(
        `INSERT INTO millitop_tv.devices (id, household_id, name)
         VALUES ($1, $2, $3)`,
        [deviceId, selected.household_id, selected.device_name]
      );

      await connection.query(
        `INSERT INTO millitop_tv.device_credentials (device_id, token_hash)
         VALUES ($1, $2)`,
        [deviceId, digest(token)]
      );

      await connection.query(
        `UPDATE millitop_tv.pairing_codes
         SET used_at = now(), used_by_device = $2
         WHERE id = $1`,
        [selected.id, deviceId]
      );

      await connection.query(
        `INSERT INTO millitop_tv.audit_log
           (actor_device_id, action, entity_type, entity_id)
         VALUES ($1, 'device.enrolled', 'device', $1)`,
        [deviceId]
      );

      await connection.query('COMMIT');

      res.status(201).json({
        deviceId,
        deviceName: selected.device_name,
        householdId: selected.household_id,
        deviceToken: token,
        heartbeatIntervalSeconds: 30
      });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/device/heartbeat', heartbeatLimit, async (req, res, next) => {
    const authorization = req.get('authorization') ?? '';
    const match = /^Bearer (mtv_[A-Za-z0-9_-]{43})$/.exec(authorization);

    if (!match) {
      return res.status(401).json({ error: 'Device authentication required.' });
    }

    const { sessionId, state, active, appVersion } = req.body ?? {};

    if (
      typeof sessionId !== 'string' ||
      !uuidPattern.test(sessionId) ||
      !['unknown', 'browsing', 'idle', 'media_active'].includes(state) ||
      typeof active !== 'boolean' ||
      typeof appVersion !== 'string' ||
      appVersion.length > 80
    ) {
      return res.status(400).json({ error: 'Invalid heartbeat.' });
    }

    let connection;

    try {
      connection = await pool.connect();
      await connection.query('BEGIN');

      const authenticated = await connection.query(
        `SELECT d.id
         FROM millitop_tv.device_credentials c
         JOIN millitop_tv.devices d ON d.id = c.device_id
         JOIN millitop_tv.households h ON h.id = d.household_id
         WHERE c.token_hash = $1
           AND c.revoked_at IS NULL
           AND (c.expires_at IS NULL OR c.expires_at > now())
           AND d.revoked_at IS NULL
           AND h.active = true
         FOR UPDATE OF d`,
        [digest(match[1])]
      );

      if (!authenticated.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(401).json({
          error: 'Device credential is invalid or revoked.'
        });
      }

      const deviceId = authenticated.rows[0].id;

      const inserted = await connection.query(
        `INSERT INTO millitop_tv.device_sessions (id, device_id)
         VALUES ($1, $2)
         ON CONFLICT (id) DO NOTHING
         RETURNING id`,
        [sessionId, deviceId]
      );

      const session = await connection.query(
        `UPDATE millitop_tv.device_sessions
         SET last_seen_at = now()
         WHERE id = $1 AND device_id = $2
         RETURNING id`,
        [sessionId, deviceId]
      );

      if (!session.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(409).json({ error: 'Session ID conflict.' });
      }

      await connection.query(
        `UPDATE millitop_tv.devices
         SET last_seen_at = now(),
             last_opened_at =
               CASE WHEN $2 THEN now() ELSE last_opened_at END,
             last_activity_at =
               CASE WHEN $3 THEN now() ELSE last_activity_at END,
             reported_state = $4,
             app_version = $5
         WHERE id = $1`,
        [deviceId, inserted.rowCount === 1, active, state, appVersion]
      );

      const reported = /^(\d+\.\d+\.\d+)\+(\d+)$/.exec(appVersion.trim());
      if (reported) {
        const version = reported[1];
        const build = Number.parseInt(reported[2], 10);
        if (Number.isInteger(build) && build > 0) {
          const verified = await connection.query(
            `UPDATE millitop_tv.app_update_assignments a
             SET status = 'verified',
                 verified_at = COALESCE(a.verified_at, now()),
                 updated_at = now(),
                 last_error = NULL
             FROM millitop_tv.app_releases r
             WHERE a.release_id = r.id
               AND a.device_id = $1
               AND a.status NOT IN ('verified', 'failed')
               AND r.version = $2
               AND r.build = $3
             RETURNING a.id`,
            [deviceId, version, build]
          );
          for (const row of verified.rows) {
            await connection.query(
              `INSERT INTO millitop_tv.app_update_events
                 (id, assignment_id, status)
               VALUES ($1, $2, 'verified')`,
              [randomUUID(), row.id]
            );
          }
        }
      }

      await connection.query('COMMIT');

      res.json({
        accepted: true,
        heartbeatIntervalSeconds: 30,
        serverTime: new Date().toISOString()
      });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      next(error);
    } finally {
      connection?.release();
    }
  });
}
