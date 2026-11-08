import { createHash, randomUUID } from 'node:crypto';

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const stateProfileId = '00000000-0000-0000-0000-000000000001';
const configPrefix = 'live_tv_config:';
const playbackPrefix = 'live_tv_playback:';
const householdProfilesKey = 'live_tv_profiles:household';
const commandPrefix = '[LIVE_TV_COMMAND]';
const maxAvatarBytes = 32 * 1024 * 1024;

function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

function parseProfileId(value) {
  const profileId = Number(value);
  if (!Number.isSafeInteger(profileId) || profileId < 1 || profileId > 1000000) {
    throw new Error('Profile ID must be a positive integer.');
  }
  return profileId;
}

function parseSources(value) {
  if (!Array.isArray(value)) {
    throw new Error('Sources must be an array.');
  }
  if (value.length > 50) {
    throw new Error('Too many sources.');
  }
  return value.map((item, index) => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      throw new Error(`Source ${index + 1} is invalid.`);
    }
    const id = String(item.id ?? '').trim();
    const name = String(item.name ?? '').trim();
    const type = String(item.type ?? '').trim();
    if (!id || !name || !type) {
      throw new Error(`Source ${index + 1} requires id, name, and type.`);
    }
    return {
      ...item,
      id,
      name,
      type
    };
  });
}

function parseTmdbApiKey(value) {
  if (value == null) {
    return '';
  }
  if (typeof value !== 'string') {
    throw new Error('TMDB API key must be a string.');
  }
  const cleaned = value.trim();
  if (cleaned && !/^[A-Za-z0-9]+$/.test(cleaned)) {
    throw new Error('TMDB API key format is invalid.');
  }
  if (cleaned.length > 128) {
    throw new Error('TMDB API key is too long.');
  }
  return cleaned;
}

function parseProfileState(value) {
  if (value == null) {
    return null;
  }

  function sourceType(source) {
    return String(source?.type ?? '').trim().toLowerCase();
  }

  function tryParseUrl(value) {
    try {
      return new URL(value);
    } catch (_) {
      return null;
    }
  }

  function normalizeUrl(value) {
    if (typeof value !== 'string' || !value.trim()) {
      return null;
    }
    const trimmed = value.trim();
    const parsed = tryParseUrl(trimmed);
    if (!parsed || !['http:', 'https:'].includes(parsed.protocol)) {
      return null;
    }
    if (parsed.username || parsed.password) {
      return null;
    }
    return parsed.toString();
  }

  async function fetchText(url, timeoutMs = 20000) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(url, {
        method: 'GET',
        signal: controller.signal,
        headers: {
          accept: 'application/json,text/plain,*/*'
        }
      });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      return await response.text();
    } finally {
      clearTimeout(timer);
    }
  }

  async function fetchJson(url, timeoutMs = 20000) {
    const text = await fetchText(url, timeoutMs);
    const parsed = JSON.parse(text);
    return parsed;
  }

  function parseM3uChannels(text) {
    const rows = String(text).split(/\r?\n/);
    const channels = [];
    let pendingTitle = null;
    let pendingAttrs = {};
    for (const row of rows) {
      const line = row.trim();
      if (!line) {
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        const commaIndex = line.indexOf(',');
        const metadata = commaIndex < 0 ? line.slice(8) : line.slice(8, commaIndex);
        pendingTitle = commaIndex < 0 ? '' : line.slice(commaIndex + 1).trim();
        pendingAttrs = {};
        const attrMatch = metadata.matchAll(/([a-zA-Z0-9_-]+)\s*=\s*"([^"]*)"/g);
        for (const entry of attrMatch) {
          pendingAttrs[String(entry[1]).toLowerCase()] = String(entry[2]).trim();
        }
        continue;
      }
      if (line.startsWith('#')) {
        continue;
      }
      const parsed = tryParseUrl(line);
      if (!parsed || !['http:', 'https:', 'rtsp:', 'rtmp:', 'udp:', 'rtp:'].includes(parsed.protocol)) {
        pendingTitle = null;
        pendingAttrs = {};
        continue;
      }
      const title = pendingTitle?.trim() ? pendingTitle.trim() : `Channel ${channels.length + 1}`;
      const group = pendingAttrs['group-title']?.trim() || '';
      const tvgId = pendingAttrs['tvg-id']?.trim() || '';
      channels.push({
        id: tvgId || `name:${title.toLowerCase()}`,
        title,
        group,
        streamUrl: parsed.toString()
      });
      pendingTitle = null;
      pendingAttrs = {};
    }
    channels.sort((a, b) => a.title.localeCompare(b.title));
    return channels;
  }

  async function loadChannelsForSource(source) {
    const type = sourceType(source);
    if (type === 'm3u') {
      const m3uUrl = normalizeUrl(source.m3uUrl ?? source.m3uLiveUrl ?? '');
      if (!m3uUrl) {
        throw new Error('M3U source URL is missing.');
      }
      const text = await fetchText(m3uUrl);
      return parseM3uChannels(text);
    }
    if (type === 'xtream') {
      const serverUrl = normalizeUrl(
        source.serverUrl ?? source.url ?? source.server ?? source.host ?? ''
      );
      const username = String(source.username ?? '').trim();
      const password = String(source.password ?? '').trim();
      if (!serverUrl || !username || !password) {
        throw new Error('Xtream source credentials are incomplete.');
      }
      const base = new URL(serverUrl);
      base.pathname = base.pathname.replace(/\/+$/, '');
      const categoriesUrl = new URL(base.toString());
      categoriesUrl.pathname = `${base.pathname}/player_api.php`;
      categoriesUrl.searchParams.set('username', username);
      categoriesUrl.searchParams.set('password', password);
      categoriesUrl.searchParams.set('action', 'get_live_categories');
      const streamsUrl = new URL(base.toString());
      streamsUrl.pathname = `${base.pathname}/player_api.php`;
      streamsUrl.searchParams.set('username', username);
      streamsUrl.searchParams.set('password', password);
      streamsUrl.searchParams.set('action', 'get_live_streams');

      const [categoriesRaw, streamsRaw] = await Promise.all([
        fetchJson(categoriesUrl.toString()).catch(() => []),
        fetchJson(streamsUrl.toString())
      ]);
      const categoryById = {};
      if (Array.isArray(categoriesRaw)) {
        for (const item of categoriesRaw) {
          const id = String(item?.category_id ?? '').trim();
          const name = String(item?.category_name ?? '').trim();
          if (id && name) {
            categoryById[id] = name;
          }
        }
      }
      if (!Array.isArray(streamsRaw)) {
        throw new Error('Xtream streams response was invalid.');
      }
      const channels = [];
      for (const item of streamsRaw) {
        if (!item || typeof item !== 'object') {
          continue;
        }
        const streamId = String(item.stream_id ?? '').trim();
        const title = String(item.name ?? '').trim();
        if (!streamId || !title) {
          continue;
        }
        const ext = String(item.container_extension ?? 'ts').trim() || 'ts';
        const stream = new URL(base.toString());
        stream.pathname = `${base.pathname}/live/${username}/${password}/${streamId}.${ext}`;
        const categoryId = String(item.category_id ?? '').trim();
        channels.push({
          id: streamId,
          title,
          group: String(item.category_name ?? '').trim() || categoryById[categoryId] || '',
          streamUrl: stream.toString()
        });
      }
      channels.sort((a, b) => a.title.localeCompare(b.title));
      return channels;
    }
    throw new Error('Unsupported source type.');
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Profile state must be an object.');
  }
  return value;
}

function parsePlaybackItem(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Playback item must be an object.');
  }
  const mediaType = String(value.mediaType ?? '').trim();
  const mediaId = String(value.mediaId ?? '').trim();
  const title = String(value.title ?? '').trim();
  if (!mediaType || !mediaId || !title) {
    throw new Error('Playback item must include mediaType, mediaId, and title.');
  }
  return {
    ...value,
    mediaType,
    mediaId,
    title
  };
}

function normalizeHouseholdProfileEntries(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  const normalized = [];
  for (const item of value) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      continue;
    }
    const idRaw = item.id;
    const profileId =
      Number.isSafeInteger(idRaw) && idRaw > 0
        ? idRaw
        : parseInt(String(idRaw ?? '').trim(), 10);
    if (!Number.isSafeInteger(profileId) || profileId < 1 || profileId > 1000000) {
      continue;
    }
    const name = String(item.name ?? '').trim();
    const deleted = item.deleted === true;
    if (!deleted && !name) {
      continue;
    }
    const avatarBase64 = String(item.avatarBase64 ?? '').trim();
    const avatarExtension = String(item.avatarExtension ?? '').trim();
    normalized.push({
      id: profileId,
      name,
      deleted,
      avatarBase64: avatarBase64 || null,
      avatarExtension: avatarExtension || null,
      updatedAtUtc: String(item.updatedAtUtc ?? '').trim() || new Date().toISOString()
    });
  }
  normalized.sort((a, b) => a.id - b.id);
  return normalized;
}

function parseHouseholdProfileUpdate(value) {
  const profileId = parseProfileId(value?.profileId);
  const name = String(value?.name ?? '').trim();
  if (!name) {
    throw new Error('Profile name is required.');
  }
  if (name.length > 40) {
    throw new Error('Profile name is too long.');
  }
  const avatarBase64 = String(value?.avatarBase64 ?? '').trim();
  const avatarExtensionRaw = String(value?.avatarExtension ?? '').trim().toLowerCase();
  let avatarExtension = '';
  if (avatarBase64) {
    let bytes;
    try {
      bytes = Buffer.from(avatarBase64, 'base64');
    } catch (_) {
      throw new Error('Profile picture format is invalid.');
    }
    if (!bytes.length || bytes.length > maxAvatarBytes) {
      throw new Error('Profile picture is too large.');
    }
    avatarExtension = avatarExtensionRaw || 'png';
    if (!/^[a-z0-9]{2,8}$/.test(avatarExtension)) {
      throw new Error('Profile picture extension is invalid.');
    }
  }
  return {
    profileId,
    name,
    avatarBase64: avatarBase64 || null,
    avatarExtension: avatarExtension || null
  };
}

function deviceConfigKey(profileId, deviceId) {
  return `${configPrefix}${profileId}:device:${deviceId}`;
}

function householdConfigKey(profileId) {
  return `${configPrefix}${profileId}:household`;
}

function playbackKey(deviceId) {
  return `${playbackPrefix}${deviceId}`;
}

async function authenticateDevice(connection, req) {
  const authorization = req.get('authorization') ?? '';
  if (!authorization.startsWith('Bearer ')) {
    return null;
  }
  const token = authorization.slice(7).trim();
  if (!token) {
    return null;
  }
  const result = await connection.query(
    `SELECT d.id, d.household_id
     FROM millitop_tv.device_credentials c
     JOIN millitop_tv.devices d ON d.id = c.device_id
     JOIN millitop_tv.households h ON h.id = d.household_id
     WHERE c.token_hash = $1
       AND c.revoked_at IS NULL
       AND (c.expires_at IS NULL OR c.expires_at > now())
       AND d.revoked_at IS NULL
       AND h.active = true
     FOR SHARE OF d`,
    [digest(token)]
  );
  return result.rowCount ? result.rows[0] : null;
}

async function lockHead(connection, householdId) {
  await connection.query(
    `INSERT INTO millitop_tv.profile_sync_heads (household_id)
     VALUES ($1)
     ON CONFLICT (household_id) DO NOTHING`,
    [householdId]
  );
  await connection.query(
    `SELECT revision
     FROM millitop_tv.profile_sync_heads
     WHERE household_id = $1
     FOR UPDATE`,
    [householdId]
  );
}

async function nextRevision(connection, householdId) {
  const updated = await connection.query(
    `UPDATE millitop_tv.profile_sync_heads
     SET revision = revision + 1
     WHERE household_id = $1
     RETURNING revision`,
    [householdId]
  );
  return Number(updated.rows[0].revision);
}

async function upsertPreferenceEntity(
  connection,
  { householdId, entityKey, payload, updatedByDevice },
) {
  await lockHead(connection, householdId);
  const revision = await nextRevision(connection, householdId);
  await connection.query(
    `INSERT INTO millitop_tv.profile_sync_entities
       (household_id, profile_id, kind, entity_key, revision, deleted, payload, updated_by_device, updated_at)
     VALUES ($1, $2, 'preference', $3, $4, false, $5::jsonb, $6, now())
     ON CONFLICT (household_id, profile_id, kind, entity_key)
     DO UPDATE SET
       revision = EXCLUDED.revision,
       deleted = false,
       payload = EXCLUDED.payload,
       updated_by_device = EXCLUDED.updated_by_device,
       updated_at = now()`,
    [
      householdId,
      stateProfileId,
      entityKey,
      revision,
      JSON.stringify(payload),
      updatedByDevice
    ]
  );
  await connection.query(
    `INSERT INTO millitop_tv.profile_sync_events
       (household_id, revision, profile_id, kind, entity_key, deleted, payload, created_at)
     VALUES ($1, $2, $3, 'preference', $4, false, $5::jsonb, now())`,
    [householdId, revision, stateProfileId, entityKey, JSON.stringify(payload)]
  );
}

async function enqueueDeviceCommand(
  connection,
  { actorUserId, deviceId, commandType, commandPayload },
) {
  const messageId = randomUUID();
  const title = `${commandPrefix} ${commandType}`;
  const body = JSON.stringify(commandPayload);
  await connection.query(
    `INSERT INTO millitop_tv.messages
       (id, draft_title, draft_body, draft_requires_ack, created_by)
     VALUES ($1, $2, $3, false, $4)`,
    [messageId, title, body, actorUserId]
  );
  const revision = await connection.query(
    `INSERT INTO millitop_tv.message_revisions
       (message_id, revision, title, body, requires_ack, published_by)
     VALUES ($1, 1, $2, $3, false, $4)
     RETURNING id`,
    [messageId, title, body, actorUserId]
  );
  await connection.query(
    `INSERT INTO millitop_tv.deliveries
       (revision_id, device_id)
     VALUES ($1, $2)
     ON CONFLICT (revision_id, device_id) DO NOTHING`,
    [revision.rows[0].id, deviceId]
  );
  return messageId;
}

function parseJsonOrDefault(value, fallback) {
  try {
    if (typeof value !== 'string' || !value.trim()) {
      return fallback;
    }
    return JSON.parse(value);
  } catch (_) {
    return fallback;
  }
}

export function registerLiveTvRoutes(app, pool, deviceLimit) {
  if (typeof deviceLimit !== 'function') {
    throw new Error('Device rate limiter required.');
  }

  app.get('/api/admin/live-tv/devices', async (req, res, next) => {
    try {
      const result = await pool.query(
        `SELECT
           d.id AS device_id,
           d.name AS device_name,
           d.household_id,
           h.name AS household_name,
           cfg.entity_key AS config_key,
           cfg.payload::text AS config_payload,
           cfg.updated_at AS config_updated_at,
           pb.payload::text AS playback_payload,
           pb.updated_at AS playback_updated_at,
           (
             SELECT count(*)::int
             FROM millitop_tv.deliveries qd
             JOIN millitop_tv.message_revisions qr ON qr.id = qd.revision_id
             WHERE qd.device_id = d.id
               AND qd.opened_at IS NULL
               AND qr.title LIKE $1
           ) AS pending_commands
         FROM millitop_tv.devices d
         JOIN millitop_tv.households h ON h.id = d.household_id
         LEFT JOIN LATERAL (
           SELECT entity_key, payload, updated_at
           FROM millitop_tv.profile_sync_entities
           WHERE household_id = d.household_id
             AND profile_id = $2
             AND kind = 'preference'
             AND NOT deleted
             AND entity_key LIKE ($3 || d.id::text)
           ORDER BY updated_at DESC
           LIMIT 1
         ) cfg ON true
         LEFT JOIN LATERAL (
           SELECT payload, updated_at
           FROM millitop_tv.profile_sync_entities
           WHERE household_id = d.household_id
             AND profile_id = $2
             AND kind = 'preference'
             AND NOT deleted
             AND entity_key = ($4 || d.id::text)
           ORDER BY updated_at DESC
           LIMIT 1
         ) pb ON true
         WHERE d.revoked_at IS NULL
         ORDER BY h.name ASC, d.name ASC`,
        [`${commandPrefix}%`, stateProfileId, `${configPrefix}%device:`, playbackPrefix]
      );
      const values = result.rows.map(row => {
        const playbackPayload = parseJsonOrDefault(row.playback_payload, null);
        const configPayload = parseJsonOrDefault(row.config_payload, null);
        return {
          ...row,
          config_payload: configPayload,
          playback_payload: playbackPayload
        };
      });
      res.json(values);
    } catch (error) {
      next(error);
    }
  });

  app.post('/api/admin/live-tv/devices/:id/config', async (req, res, next) => {
    if (!uuidPattern.test(req.params.id)) {
      return res.status(400).json({ error: 'Invalid device ID.' });
    }
    let profileId;
    let sources;
    let tmdbApiKey;
    let profileState;
    try {
      profileId = parseProfileId(req.body?.profileId);
      sources = parseSources(req.body?.sources ?? []);
      tmdbApiKey = parseTmdbApiKey(req.body?.tmdbApiKey);
      profileState = parseProfileState(req.body?.profileState);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }

    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');

      const device = await connection.query(
        `SELECT id, household_id
         FROM millitop_tv.devices
         WHERE id = $1
           AND revoked_at IS NULL
         FOR SHARE`,
        [req.params.id]
      );
      if (!device.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(404).json({ error: 'Device not found.' });
      }

      await upsertPreferenceEntity(connection, {
        householdId: device.rows[0].household_id,
        entityKey: deviceConfigKey(profileId, req.params.id),
        payload: {
          profileId,
          sources,
          tmdbApiKey,
          profileState,
          updatedAtUtc: new Date().toISOString(),
          updatedBy: 'admin'
        },
        updatedByDevice: req.params.id
      });

      await connection.query('COMMIT');
      res.json({ saved: true });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/admin/live-tv/devices/:id/playback/start', async (req, res, next) => {
    if (!uuidPattern.test(req.params.id)) {
      return res.status(400).json({ error: 'Invalid device ID.' });
    }
    let profileId;
    let item;
    try {
      profileId = parseProfileId(req.body?.profileId);
      item = parsePlaybackItem(req.body?.item);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }

    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await connection.query(
        `SELECT id, household_id
         FROM millitop_tv.devices
         WHERE id = $1
           AND revoked_at IS NULL
         FOR SHARE`,
        [req.params.id]
      );
      if (!device.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(404).json({ error: 'Device not found.' });
      }
      const commandId = await enqueueDeviceCommand(connection, {
        actorUserId: req.admin.id,
        deviceId: req.params.id,
        commandType: 'playback_start',
        commandPayload: {
          commandType: 'playback_start',
          profileId,
          item
        }
      });
      await connection.query('COMMIT');
      res.status(201).json({ queued: true, commandId });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      next(error);
    } finally {
      connection?.release();
    }
  });

  app.get('/api/admin/live-tv/devices/:id/channels', async (req, res, next) => {
    if (!uuidPattern.test(req.params.id)) {
      return res.status(400).json({ error: 'Invalid device ID.' });
    }
    let profileId;
    try {
      profileId = parseProfileId(req.query?.profileId ?? 1);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    const sourceFilter = String(req.query?.sourceId ?? '').trim();

    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await connection.query(
        `SELECT id, household_id
         FROM millitop_tv.devices
         WHERE id = $1
           AND revoked_at IS NULL
         FOR SHARE`,
        [req.params.id]
      );
      if (!device.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(404).json({ error: 'Device not found.' });
      }
      const config = await connection.query(
        `SELECT payload
         FROM millitop_tv.profile_sync_entities
         WHERE household_id = $1
           AND profile_id = $2
           AND kind = 'preference'
           AND NOT deleted
           AND entity_key IN ($3, $4)
         ORDER BY CASE WHEN entity_key = $3 THEN 0 ELSE 1 END, updated_at DESC
         LIMIT 1`,
        [
          device.rows[0].household_id,
          stateProfileId,
          deviceConfigKey(profileId, req.params.id),
          householdConfigKey(profileId)
        ]
      );
      await connection.query('COMMIT');
      const sourcesRaw = config.rows[0]?.payload?.sources;
      const sources = Array.isArray(sourcesRaw) ? parseSources(sourcesRaw) : [];
      const activeSources = sourceFilter
        ? sources.filter(source => source.id === sourceFilter)
        : sources;
      const loaded = await Promise.all(
        activeSources.map(async source => {
          try {
            const channels = await loadChannelsForSource(source);
            return {
              sourceId: source.id,
              sourceName: source.name,
              sourceType: sourceType(source),
              channels
            };
          } catch (error) {
            return {
              sourceId: source.id,
              sourceName: source.name,
              sourceType: sourceType(source),
              channels: [],
              error: error.message
            };
          }
        })
      );
      return res.json({
        profileId,
        sources: loaded
      });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/device/live-tv/config', deviceLimit, async (req, res, next) => {
    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await authenticateDevice(connection, req);
      if (!device) {
        await connection.query('ROLLBACK');
        return res.status(401).json({ error: 'Device authentication required.' });
      }
      const action = String(req.body?.action ?? '').trim().toLowerCase();
      const profileId = parseProfileId(req.body?.profileId);
      if (action === 'get') {
        const config = await connection.query(
          `SELECT payload
           FROM millitop_tv.profile_sync_entities
           WHERE household_id = $1
             AND profile_id = $2
             AND kind = 'preference'
             AND NOT deleted
             AND entity_key IN ($3, $4)
           ORDER BY CASE WHEN entity_key = $3 THEN 0 ELSE 1 END, updated_at DESC
           LIMIT 1`,
          [
            device.household_id,
            stateProfileId,
            deviceConfigKey(profileId, device.id),
            householdConfigKey(profileId)
          ]
        );
        await connection.query('COMMIT');
        const payload = config.rows[0]?.payload ?? {};
        return res.json({
          sources: Array.isArray(payload.sources) ? payload.sources : [],
          tmdbApiKey: typeof payload.tmdbApiKey === 'string' ? payload.tmdbApiKey : '',
          profileState:
            payload.profileState && typeof payload.profileState === 'object'
              ? payload.profileState
              : null
        });
      }
      if (action !== 'set') {
        await connection.query('ROLLBACK');
        return res.status(400).json({ error: 'Unsupported config action.' });
      }
      const sources = parseSources(req.body?.sources ?? []);
      const tmdbApiKey = parseTmdbApiKey(req.body?.tmdbApiKey);
      const profileState = parseProfileState(req.body?.profileState);
      await upsertPreferenceEntity(connection, {
        householdId: device.household_id,
        entityKey: householdConfigKey(profileId),
        payload: {
          profileId,
          sources,
          tmdbApiKey,
          profileState,
          updatedAtUtc: new Date().toISOString(),
          updatedBy: 'device'
        },
        updatedByDevice: device.id
      });
      await connection.query('COMMIT');
      return res.json({ saved: true });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      if (error?.message?.includes('Profile ID')) {
        return res.status(400).json({ error: error.message });
      }
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/device/household/profiles', deviceLimit, async (req, res, next) => {
    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await authenticateDevice(connection, req);
      if (!device) {
        await connection.query('ROLLBACK');
        return res.status(401).json({ error: 'Device authentication required.' });
      }
      const action = String(req.body?.action ?? '').trim().toLowerCase();
      const existing = await connection.query(
        `SELECT payload
         FROM millitop_tv.profile_sync_entities
         WHERE household_id = $1
           AND profile_id = $2
           AND kind = 'preference'
           AND entity_key = $3
           AND NOT deleted
         ORDER BY updated_at DESC
         LIMIT 1`,
        [device.household_id, stateProfileId, householdProfilesKey]
      );
      const payload = existing.rows[0]?.payload ?? {};
      const current = normalizeHouseholdProfileEntries(payload.profiles);
      if (action === 'get') {
        await connection.query('COMMIT');
        return res.json({ profiles: current });
      }
      if (action === 'upsert') {
        const update = parseHouseholdProfileUpdate(req.body ?? {});
        const existingProfile = current.find(entry => entry.id === update.profileId) ?? null;
        const avatarProvided = Object.prototype.hasOwnProperty.call(req.body ?? {}, 'avatarBase64');
        const avatarExtensionProvided = Object.prototype.hasOwnProperty.call(req.body ?? {}, 'avatarExtension');
        const avatarBase64 = avatarProvided
          ? update.avatarBase64
          : (existingProfile?.avatarBase64 ?? null);
        const avatarExtension = avatarBase64
          ? (avatarExtensionProvided ? update.avatarExtension : (existingProfile?.avatarExtension ?? null))
          : null;
        const values = current.filter(entry => entry.id !== update.profileId);
        values.push({
          id: update.profileId,
          name: update.name,
          deleted: false,
          avatarBase64,
          avatarExtension,
          updatedAtUtc: new Date().toISOString()
        });
        values.sort((a, b) => a.id - b.id);
        await upsertPreferenceEntity(connection, {
          householdId: device.household_id,
          entityKey: householdProfilesKey,
          payload: {
            profiles: values,
            updatedAtUtc: new Date().toISOString(),
            updatedBy: 'device'
          },
          updatedByDevice: device.id
        });
        await connection.query('COMMIT');
        return res.json({ saved: true, profiles: values });
      }
      if (action === 'remove') {
        const profileId = parseProfileId(req.body?.profileId);
        const values = current.filter(entry => entry.id !== profileId);
        values.push({
          id: profileId,
          name: '',
          deleted: true,
          avatarBase64: null,
          avatarExtension: null,
          updatedAtUtc: new Date().toISOString()
        });
        values.sort((a, b) => a.id - b.id);
        await upsertPreferenceEntity(connection, {
          householdId: device.household_id,
          entityKey: householdProfilesKey,
          payload: {
            profiles: values,
            updatedAtUtc: new Date().toISOString(),
            updatedBy: 'device'
          },
          updatedByDevice: device.id
        });
        await connection.query('COMMIT');
        return res.json({ saved: true });
      }
      await connection.query('ROLLBACK');
      return res.status(400).json({ error: 'Unsupported household profile action.' });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      if (
        error?.message?.includes('Profile ID') ||
        error?.message?.includes('Profile name') ||
        error?.message?.includes('Profile picture')
      ) {
        return res.status(400).json({ error: error.message });
      }
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/device/live-tv/playback', deviceLimit, async (req, res, next) => {
    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await authenticateDevice(connection, req);
      if (!device) {
        await connection.query('ROLLBACK');
        return res.status(401).json({ error: 'Device authentication required.' });
      }
      const action = String(req.body?.action ?? '').trim().toLowerCase();
      if (action === 'get') {
        const current = await connection.query(
          `SELECT payload
           FROM millitop_tv.profile_sync_entities
           WHERE household_id = $1
             AND profile_id = $2
             AND kind = 'preference'
             AND entity_key = $3
             AND NOT deleted
           ORDER BY updated_at DESC
           LIMIT 1`,
          [device.household_id, stateProfileId, playbackKey(device.id)]
        );
        await connection.query('COMMIT');
        return res.json(current.rows[0]?.payload ?? { active: false });
      }
      if (action !== 'status') {
        await connection.query('ROLLBACK');
        return res.status(400).json({ error: 'Unsupported playback action.' });
      }
      const profileId = parseProfileId(req.body?.profileId);
      const sourceId = String(req.body?.sourceId ?? '').trim();
      const sourceName = String(req.body?.sourceName ?? '').trim();
      const mediaType = String(req.body?.mediaType ?? '').trim();
      const mediaId = String(req.body?.mediaId ?? '').trim();
      const title = String(req.body?.title ?? '').trim();
      const active = Boolean(req.body?.active);
      if (!sourceId || !sourceName || !mediaType || !mediaId || !title) {
        await connection.query('ROLLBACK');
        return res.status(400).json({ error: 'Playback status fields are incomplete.' });
      }
      await upsertPreferenceEntity(connection, {
        householdId: device.household_id,
        entityKey: playbackKey(device.id),
        payload: {
          profileId,
          sourceId,
          sourceName,
          mediaType,
          mediaId,
          title,
          active,
          updatedAtUtc: new Date().toISOString()
        },
        updatedByDevice: device.id
      });
      await connection.query('COMMIT');
      return res.json({ accepted: true });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      if (error?.message?.includes('Profile ID')) {
        return res.status(400).json({ error: error.message });
      }
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/device/live-tv/queue', deviceLimit, async (req, res, next) => {
    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await authenticateDevice(connection, req);
      if (!device) {
        await connection.query('ROLLBACK');
        return res.status(401).json({ error: 'Device authentication required.' });
      }
      const action = String(req.body?.action ?? '').trim().toLowerCase();
      if (action === 'pull') {
        const rows = await connection.query(
          `SELECT d.id AS delivery_id, r.id AS revision_id, r.title, r.body, r.published_at
           FROM millitop_tv.deliveries d
           JOIN millitop_tv.message_revisions r ON r.id = d.revision_id
           WHERE d.device_id = $1
             AND d.opened_at IS NULL
             AND r.title LIKE $2
           ORDER BY d.assigned_at ASC
           LIMIT 10`,
          [device.id, `${commandPrefix}%`]
        );
        if (rows.rowCount) {
          await connection.query(
            `UPDATE millitop_tv.deliveries
             SET delivered_at = COALESCE(delivered_at, now()),
                 opened_at = now()
             WHERE id = ANY($1::uuid[])`,
            [rows.rows.map(row => row.delivery_id)]
          );
        }
        await connection.query('COMMIT');
        return res.json({
          commands: rows.rows.map(row => {
            const payload = parseJsonOrDefault(row.body, {});
            return {
              id: row.delivery_id,
              revisionId: row.revision_id,
              title: row.title,
              payload,
              publishedAt: row.published_at
            };
          })
        });
      }
      if (action === 'ack') {
        const deliveryId = String(req.body?.commandId ?? '').trim();
        if (!uuidPattern.test(deliveryId)) {
          await connection.query('ROLLBACK');
          return res.status(400).json({ error: 'commandId is required.' });
        }
        const success = Boolean(req.body?.success);
        const profileId = req.body?.profileId == null
          ? null
          : String(req.body.profileId).trim();
        await connection.query(
          `UPDATE millitop_tv.deliveries
           SET acknowledged_at = now(),
               acknowledged_profile_id = $3
           WHERE id = $1
             AND device_id = $2`,
          [deliveryId, device.id, profileId]
        );
        await connection.query('COMMIT');
        return res.json({ acknowledged: true, success });
      }
      if (action === 'enqueue') {
        await connection.query('COMMIT');
        return res.json({ accepted: false, reason: 'Device-origin enqueue disabled.' });
      }
      await connection.query('ROLLBACK');
      return res.status(400).json({ error: 'Unsupported queue action.' });
    } catch (error) {
      if (connection) await connection.query('ROLLBACK').catch(() => {});
      return next(error);
    } finally {
      connection?.release();
    }
  });
}
