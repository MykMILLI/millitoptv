import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const videoExtensions = new Set([
  '.mp4',
  '.mkv',
  '.avi',
  '.mov',
  '.wmv',
  '.m4v',
  '.mpg',
  '.mpeg',
  '.mp2',
  '.m2v',
  '.m2p',
  '.mts',
  '.ts',
  '.m2ts',
  '.vob',
  '.iso',
  '.divx',
  '.flv',
  '.ogv',
  '.3gp',
  '.3g2',
  '.webm',
]);
const mediaScanCacheTtlMs = 8 * 60 * 1000;
const mediaScanCache = new Map();
const allowedMediaKinds = new Set(['auto', 'movie', 'series', 'home_video', 'live_show', 'other']);
let mediaSchema = String(process.env.MEDIA_LIBRARY_SCHEMA ?? 'millitop_tv').trim() || 'millitop_tv';
const fallbackProfileId = '00000000-0000-0000-0000-000000000001';
const fallbackKind = 'preference';
const fallbackEntityKey = 'media_library_state:household';
const fallbackSourcesEntityKey = 'media_library_sources:household';

function mediaTable(name) {
  return `${mediaSchema}.${name}`;
}

function scanCacheKey({ type, pathValue, username, domain, password }) {
  return [
    type,
    normalizeSmbPathValue(pathValue),
    String(username ?? '').trim().toLowerCase(),
    String(domain ?? '').trim().toLowerCase(),
    createHash('sha1').update(String(password ?? '')).digest('hex').slice(0, 12),
  ].join('::');
}

function readScanCache(key) {
  const cached = mediaScanCache.get(key);
  if (!cached) {
    return null;
  }
  if (Date.now() - cached.createdAt > mediaScanCacheTtlMs) {
    mediaScanCache.delete(key);
    return null;
  }
  return [...cached.files];
}

function writeScanCache(key, files) {
  mediaScanCache.set(key, {
    createdAt: Date.now(),
    files: Array.isArray(files) ? [...files] : [],
  });
}

function parseSourceInput(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Source payload is invalid.');
  }
  const name = String(value.name ?? '').trim();
  const rootPath = String(value.rootPath ?? value.sharePath ?? '').trim();
  if (!name || name.length > 120) {
    throw new Error('Source name must contain 1–120 characters.');
  }
  if (!rootPath || rootPath.length > 1024) {
    throw new Error('Source path must contain 1–1024 characters.');
  }
  return {
    name,
    rootPath,
    smbUsername: String(value.smbUsername ?? '').trim(),
    smbPassword: String(value.smbPassword ?? '').trim(),
    smbDomain: String(value.smbDomain ?? '').trim(),
    tmdbApiKey: String(value.tmdbApiKey ?? '').trim(),
    enabled: value.enabled !== false,
  };
}

async function hasStructuredMediaTables(pool) {
  const result = await pool.query(
    'SELECT to_regclass($1) AS rel',
    [`${mediaSchema}.media_libraries`]
  );
  return Boolean(result.rows[0]?.rel);
}

async function loadFallbackLibraries(connection, householdId) {
  const row = await connection.query(
    `SELECT payload
     FROM millitop_tv.profile_sync_entities
     WHERE household_id = $1
       AND profile_id = $2
       AND kind = $3
       AND entity_key = $4
       AND NOT deleted
     LIMIT 1`,
    [householdId, fallbackProfileId, fallbackKind, fallbackEntityKey]
  );
  const payload = row.rows[0]?.payload;
  const libraries = Array.isArray(payload?.libraries) ? payload.libraries : [];
  return libraries
    .filter(item => item && typeof item === 'object')
    .map(item => ({
      id: String(item.id ?? randomUUID()),
      householdId,
      name: String(item.name ?? '').trim(),
      sharePath: String(item.sharePath ?? '').trim(),
      enabled: item.enabled !== false,
      tmdbEnabled: item.tmdbEnabled !== false,
      tmdbApiKey: String(item.tmdbApiKey ?? ''),
      smbUsername: String(item.smbUsername ?? ''),
      smbDomain: String(item.smbDomain ?? ''),
      hasSmbPassword: String(item.smbPassword ?? '').length > 0,
      profileIds: Array.isArray(item.profileIds)
        ? item.profileIds.map(value => Number(value)).filter(value => Number.isSafeInteger(value))
        : [],
      createdAt: item.createdAt ?? null,
      updatedAt: item.updatedAt ?? null,
      mediaKindOverride: String(item.mediaKindOverride ?? ''),
      displayName: String(item.displayName ?? item.name ?? '').trim(),
    }));
}

async function loadFallbackSources(connection, householdId) {
  const row = await connection.query(
    `SELECT payload
     FROM millitop_tv.profile_sync_entities
     WHERE household_id = $1
       AND profile_id = $2
       AND kind = $3
       AND entity_key = $4
       AND NOT deleted
     LIMIT 1`,
    [householdId, fallbackProfileId, fallbackKind, fallbackSourcesEntityKey]
  );
  const payload = row.rows[0]?.payload;
  const sources = Array.isArray(payload?.sources) ? payload.sources : [];
  return sources
    .filter(item => item && typeof item === 'object')
    .map(item => ({
      id: String(item.id ?? randomUUID()),
      name: String(item.name ?? '').trim(),
      rootPath: String(item.rootPath ?? item.sharePath ?? '').trim(),
      smbUsername: String(item.smbUsername ?? ''),
      smbPassword: String(item.smbPassword ?? ''),
      smbDomain: String(item.smbDomain ?? ''),
      tmdbApiKey: String(item.tmdbApiKey ?? ''),
      enabled: item.enabled !== false,
      createdAt: item.createdAt ?? null,
      updatedAt: item.updatedAt ?? null,
    }));
}

function normalizeSmbPathValue(value) {
  return String(value ?? '')
    .trim()
    .replace(/\\/g, '/')
    .replace(/^smb:\/\//i, '')
    .replace(/^\/+/, '')
    .replace(/\/+/g, '/')
    .replace(/\/+$/, '')
    .toLowerCase();
}

function hydrateFallbackLibrariesWithSourceCredentials(libraries, sources) {
  const sourceEntries = Array.isArray(sources) ? sources : [];
  return libraries.map(library => {
    const libraryPath = normalizeSmbPathValue(library.sharePath);
    const matchedSource = sourceEntries.find(source => {
      const sourcePath = normalizeSmbPathValue(source.rootPath);
      return (
        sourcePath &&
        libraryPath &&
        (libraryPath.startsWith(sourcePath) || sourcePath.startsWith(libraryPath))
      );
    });
    if (!matchedSource) {
      return library;
    }
    return {
      ...library,
      smbUsername: library.smbUsername || matchedSource.smbUsername || '',
      smbPassword: library.smbPassword || matchedSource.smbPassword || '',
      smbDomain: library.smbDomain || matchedSource.smbDomain || '',
      tmdbApiKey: library.tmdbApiKey || matchedSource.tmdbApiKey || '',
    };
  });
}

async function resolveFallbackDeviceId(connection, householdId) {
  const householdDevice = await connection.query(
    `SELECT id
     FROM millitop_tv.devices
     WHERE household_id = $1
       AND revoked_at IS NULL
     ORDER BY enrolled_at ASC
     LIMIT 1`,
    [householdId]
  );
  if (householdDevice.rowCount) {
    return householdDevice.rows[0].id;
  }
  const anyDevice = await connection.query(
    `SELECT id
     FROM millitop_tv.devices
     WHERE revoked_at IS NULL
     ORDER BY enrolled_at ASC
     LIMIT 1`
  );
  if (anyDevice.rowCount) {
    return anyDevice.rows[0].id;
  }
  throw new Error('At least one enrolled device is required before saving SMB sources.');
}

async function saveFallbackLibraries(connection, householdId, libraries) {
  const revisionRow = await connection.query(
    `SELECT COALESCE(MAX(revision), 0) + 1 AS revision
     FROM millitop_tv.profile_sync_entities
     WHERE household_id = $1`,
    [householdId]
  );
  const revision = Number(revisionRow.rows[0]?.revision ?? 1);
  const updatedByDevice = await resolveFallbackDeviceId(connection, householdId);
  const payload = {
    libraries: libraries.map(item => ({
      id: item.id,
      name: item.name,
      sharePath: item.sharePath,
      enabled: item.enabled !== false,
      tmdbEnabled: item.tmdbEnabled !== false,
      tmdbApiKey: item.tmdbApiKey ?? '',
      smbUsername: item.smbUsername ?? '',
      smbPassword: item.smbPassword ?? '',
      smbDomain: item.smbDomain ?? '',
      profileIds: item.profileIds ?? [],
      createdAt: item.createdAt ?? new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      mediaKindOverride: item.mediaKindOverride ?? '',
      displayName: item.displayName ?? item.name ?? '',
    })),
  };
  await connection.query(
    `INSERT INTO millitop_tv.profile_sync_entities
       (household_id, profile_id, kind, entity_key, revision, deleted, payload, updated_by_device, updated_at)
     VALUES ($1, $2, $3, $4, $5, false, $6, $7, now())
     ON CONFLICT (household_id, profile_id, kind, entity_key)
     DO UPDATE SET
       revision = EXCLUDED.revision,
       deleted = false,
       payload = EXCLUDED.payload,
       updated_by_device = EXCLUDED.updated_by_device,
       updated_at = now()`,
    [
      householdId,
      fallbackProfileId,
      fallbackKind,
      fallbackEntityKey,
      revision,
      JSON.stringify(payload),
      updatedByDevice,
    ]
  );
}

async function saveFallbackSources(connection, householdId, sources) {
  const revisionRow = await connection.query(
    `SELECT COALESCE(MAX(revision), 0) + 1 AS revision
     FROM millitop_tv.profile_sync_entities
     WHERE household_id = $1`,
    [householdId]
  );
  const revision = Number(revisionRow.rows[0]?.revision ?? 1);
  const updatedByDevice = await resolveFallbackDeviceId(connection, householdId);
  const payload = {
    sources: sources.map(item => ({
      id: item.id,
      name: item.name,
      rootPath: item.rootPath,
      smbUsername: item.smbUsername ?? '',
      smbPassword: item.smbPassword ?? '',
      smbDomain: item.smbDomain ?? '',
      tmdbApiKey: item.tmdbApiKey ?? '',
      enabled: item.enabled !== false,
      createdAt: item.createdAt ?? new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    })),
  };
  await connection.query(
    `INSERT INTO millitop_tv.profile_sync_entities
       (household_id, profile_id, kind, entity_key, revision, deleted, payload, updated_by_device, updated_at)
     VALUES ($1, $2, $3, $4, $5, false, $6, $7, now())
     ON CONFLICT (household_id, profile_id, kind, entity_key)
     DO UPDATE SET
       revision = EXCLUDED.revision,
       deleted = false,
       payload = EXCLUDED.payload,
       updated_by_device = EXCLUDED.updated_by_device,
       updated_at = now()`,
    [
      householdId,
      fallbackProfileId,
      fallbackKind,
      fallbackSourcesEntityKey,
      revision,
      JSON.stringify(payload),
      updatedByDevice,
    ]
  );
}

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

function parseHouseholdId(value) {
  const householdId = String(value ?? '').trim();
  if (!uuidPattern.test(householdId)) {
    throw new Error('Invalid household ID.');
  }
  return householdId;
}

function parseLibraryId(value) {
  const libraryId = String(value ?? '').trim();
  if (!uuidPattern.test(libraryId)) {
    throw new Error('Invalid library ID.');
  }
  return libraryId;
}

function parseLibraryInput(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Library payload is invalid.');
  }
  const name = String(value.name ?? '').trim();
  const sharePath = String(value.sharePath ?? '').trim();
  if (!name || name.length > 120) {
    throw new Error('Library name must contain 1–120 characters.');
  }
  if (!sharePath || sharePath.length > 1024) {
    throw new Error('Library share path must contain 1–1024 characters.');
  }
  const smbUsername = String(value.smbUsername ?? '').trim();
  const smbPassword = String(value.smbPassword ?? '').trim();
  const smbDomain = String(value.smbDomain ?? '').trim();
  const mediaKind = String(value.mediaKind ?? 'auto').trim().toLowerCase();
  if (!allowedMediaKinds.has(mediaKind)) {
    throw new Error('Invalid media kind.');
  }
  return {
    name,
    sharePath,
    enabled: value.enabled !== false,
    tmdbEnabled: value.tmdbEnabled !== false,
    tmdbApiKey: String(value.tmdbApiKey ?? '').trim(),
    smbUsername,
    smbPassword,
    smbDomain,
    mediaKind,
  };
}

function parseAclProfileIds(value) {
  if (!Array.isArray(value)) {
    throw new Error('profileIds must be an array.');
  }
  const normalized = [];
  const seen = new Set();
  for (const raw of value) {
    const profileId = parseProfileId(raw);
    if (seen.has(profileId)) {
      continue;
    }
    seen.add(profileId);
    normalized.push(profileId);
    if (normalized.length >= 1000) {
      break;
    }
  }
  return normalized;
}

function parseSharePath(value) {
  const sharePath = String(value ?? '').trim();
  if (!sharePath || sharePath.length > 1024) {
    throw new Error('Share path must contain 1–1024 characters.');
  }
  return sharePath;
}

function isSmbPath(value) {
  const sharePath = String(value ?? '').trim();
  return sharePath.startsWith('\\\\') || /^smb:\/\//i.test(sharePath);
}

function parseLibraryNameMetadata(name) {
  const trimmed = String(name ?? '').trim();
  const tagged = trimmed.match(/^\[(auto|movie|series|home_video|live_show|other)\]\s*(.+)$/i);
  if (tagged) {
    const kind = tagged[1].toLowerCase();
    return {
      displayName: tagged[2].trim() || trimmed,
      mediaKindOverride: kind === 'auto' ? '' : kind,
    };
  }
  return { displayName: trimmed, mediaKindOverride: '' };
}

function encodeLibraryName(name, mediaKind) {
  const safeName = String(name ?? '').trim();
  const kind = String(mediaKind ?? 'auto').trim().toLowerCase();
  if (!allowedMediaKinds.has(kind) || kind === 'auto') {
    return safeName;
  }
  return `[${kind}] ${safeName}`;
}

function parseSmbLocation(sharePath) {
  const value = String(sharePath ?? '').trim();
  if (value.startsWith('\\\\')) {
    const segments = value.replace(/^\\\\+/, '').split('\\').filter(Boolean);
    if (segments.length < 2) {
      throw new Error('SMB UNC path must include server and share.');
    }
    const [server, share, ...rest] = segments;
    return { server, share, directory: rest.join('/') };
  }
  const smbMatch = value.match(/^smb:\/\/([^/]+)\/([^/]+)\/?(.*)$/i);
  if (smbMatch) {
    return {
      server: smbMatch[1],
      share: smbMatch[2],
      directory: smbMatch[3] || '',
    };
  }
  throw new Error('Unsupported SMB path format. Use \\\\server\\share\\path or smb://server/share/path');
}

let smbClientReady;
async function ensureSmbClientAvailable() {
  if (!smbClientReady) {
    smbClientReady = execFileAsync('smbclient', ['--version'], { timeout: 10000 })
      .then(() => true)
      .catch(() => {
        throw new Error('SMB client is not installed on the dashboard server.');
      });
  }
  return smbClientReady;
}

function appendSmbAuthArgs(args, username, password, domain) {
  if (username) {
    args.push('-U', `${username}%${password ?? ''}`);
    if (domain) {
      args.push('-W', domain);
    }
    return;
  }
  args.push('-N');
}

function parseSmbLsOutput(stdout, server, share, maxItems = 3000) {
  const values = [];
  let currentDirectory = '';
  const lines = String(stdout ?? '').split(/\r?\n/);
  for (const line of lines) {
    if (values.length >= maxItems) {
      break;
    }
    const headerMatch = line.match(/^\s*\\(.+?)\s*$/);
    if (headerMatch) {
      currentDirectory = headerMatch[1].replace(/\\/g, '/');
      continue;
    }
    let fileName = '';
    let attrs = '';
    const strictEntry = line.match(
      /^\s*(.+?)\s+([A-Z]+)\s+\d+\s+.+$/
    );
    if (strictEntry) {
      fileName = strictEntry[1].trim();
      attrs = strictEntry[2].toUpperCase();
    } else {
      const trimmed = line.trim();
      if (!trimmed) {
        continue;
      }
      const parts = trimmed.split(/\s{2,}/).filter(Boolean);
      if (parts.length < 2) {
        continue;
      }
      fileName = parts[0].trim();
      const attrsToken = parts[1].trim().split(/\s+/)[0] ?? '';
      attrs = attrsToken.toUpperCase();
      if (!/^[A-Z]{1,8}$/.test(attrs)) {
        continue;
      }
    }
    if (!fileName || fileName === '.' || fileName === '..' || attrs.includes('D')) {
      continue;
    }
    const ext = path.extname(fileName).toLowerCase();
    if (!videoExtensions.has(ext)) {
      continue;
    }
    const relative = currentDirectory ? `${currentDirectory}/${fileName}` : fileName;
    values.push(`smb://${server}/${share}/${relative}`);
  }
  return values;
}

function parseSmbDirectoryOutput(stdout, server, share, baseDirectory = '') {
  const values = [];
  const lines = String(stdout ?? '').split(/\r?\n/);
  for (const line of lines) {
    let name = '';
    let attrs = '';
    const strictEntry = line.match(/^\s*(.+?)\s+([A-Z]+)\s+\d+\s+.*$/);
    if (strictEntry) {
      name = strictEntry[1].trim();
      attrs = strictEntry[2].toUpperCase();
    } else {
      const trimmed = line.trim();
      if (!trimmed) {
        continue;
      }
      const parts = trimmed.split(/\s{2,}/).filter(Boolean);
      if (parts.length < 2) {
        continue;
      }
      name = parts[0].trim();
      const attrsToken = parts[1].trim().split(/\s+/)[0] ?? '';
      attrs = attrsToken.toUpperCase();
      if (!/^[A-Z]{1,8}$/.test(attrs)) {
        continue;
      }
    }
    if (!name || name === '.' || name === '..') {
      continue;
    }
    const isDirectory = attrs.includes('D');
    const fullRelative = baseDirectory ? `${baseDirectory}/${name}` : name;
    values.push({
      name,
      type: isDirectory ? 'directory' : 'file',
      path: `smb://${server}/${share}/${fullRelative}`,
    });
  }
  return values;
}

async function browseSmbShare(sharePath, smbUsername, smbPassword, smbDomain) {
  await ensureSmbClientAvailable();
  const { server, share, directory } = parseSmbLocation(sharePath);
  const args = [`//${server}/${share}`];
  appendSmbAuthArgs(args, smbUsername, smbPassword, smbDomain);
  if (directory) {
    args.push('-D', directory);
  }
  args.push('-c', 'ls');
  const { stdout } = await execFileAsync('smbclient', args, {
    timeout: 15000,
    maxBuffer: 5 * 1024 * 1024,
  });
  return parseSmbDirectoryOutput(stdout, server, share, directory);
}

async function scanSmbLibraryFiles(
  sharePath,
  smbUsername,
  smbPassword,
  smbDomain,
  maxItems = 15000
) {
  await ensureSmbClientAvailable();
  const { server, share, directory } = parseSmbLocation(sharePath);
  const args = [`//${server}/${share}`];
  appendSmbAuthArgs(args, smbUsername, smbPassword, smbDomain);
  if (directory) {
    args.push('-D', directory);
  }
  args.push('-c', 'recurse ON;prompt OFF;ls');
  let fast = [];
  try {
    const { stdout } = await execFileAsync('smbclient', args, {
      timeout: 90000,
      maxBuffer: 25 * 1024 * 1024,
    });
    fast = parseSmbLsOutput(stdout, server, share, maxItems);
    if (fast.length > 0) {
      return fast;
    }
    const stdoutPreview = String(stdout ?? '')
      .split(/\r?\n/)
      .map(item => item.trim())
      .filter(Boolean)
      .slice(0, 8)
      .join(' | ');
    console.info(
      `[media-library/catalog] smb-fast-scan-empty share="//${server}/${share}" dir="${directory}" preview="${stdoutPreview}"`
    );
  } catch (error) {
    console.warn(
      `[media-library/catalog] smb-fast-scan-error share="//${server}/${share}" dir="${directory}" error="${String(error?.message ?? error)}"`
    );
  }

  const values = [];
  const pending = [sharePath];
  const seenDirectories = new Set();
  const maxDirectories = 2500;
  while (pending.length > 0 && values.length < maxItems && seenDirectories.size < maxDirectories) {
    const current = pending.pop();
    if (!current || seenDirectories.has(current)) {
      continue;
    }
    seenDirectories.add(current);
    let entries = [];
    try {
      entries = await browseSmbShare(current, smbUsername, smbPassword, smbDomain);
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      if (values.length >= maxItems) {
        break;
      }
      if (entry.type === 'directory') {
        if (!seenDirectories.has(entry.path)) {
          pending.push(entry.path);
        }
        continue;
      }
      if (entry.type !== 'file') {
        continue;
      }
      const ext = path.extname(String(entry.path ?? '')).toLowerCase();
      if (!videoExtensions.has(ext)) {
        continue;
      }
      values.push(entry.path);
    }
  }
  return values;
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

let schemaReady;
async function ensureSchema(pool) {
  if (!schemaReady) {
    schemaReady = (async () => {
      const attemptedSchemas = new Set();
      while (true) {
        attemptedSchemas.add(mediaSchema);
        const connection = await pool.connect();
        try {
          await connection.query('BEGIN');
          await connection.query(`
          CREATE TABLE IF NOT EXISTS ${mediaTable('media_libraries')} (
            id uuid PRIMARY KEY,
            household_id uuid NOT NULL REFERENCES millitop_tv.households(id) ON DELETE CASCADE,
            name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
            share_path text NOT NULL CHECK (length(trim(share_path)) BETWEEN 1 AND 1024),
            enabled boolean NOT NULL DEFAULT true,
            tmdb_enabled boolean NOT NULL DEFAULT true,
            tmdb_api_key text NOT NULL DEFAULT '',
            smb_username text NOT NULL DEFAULT '',
            smb_password text NOT NULL DEFAULT '',
            smb_domain text NOT NULL DEFAULT '',
            created_by uuid NULL,
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now(),
            UNIQUE (household_id, share_path)
          );
        `);
          await connection.query(
          `ALTER TABLE ${mediaTable('media_libraries')}
             ADD COLUMN IF NOT EXISTS smb_username text NOT NULL DEFAULT ''`
        );
          await connection.query(
          `ALTER TABLE ${mediaTable('media_libraries')}
             ADD COLUMN IF NOT EXISTS smb_password text NOT NULL DEFAULT ''`
        );
          await connection.query(
          `ALTER TABLE ${mediaTable('media_libraries')}
             ADD COLUMN IF NOT EXISTS smb_domain text NOT NULL DEFAULT ''`
        );
          await connection.query(`
          CREATE TABLE IF NOT EXISTS ${mediaTable('media_library_acl')} (
            library_id uuid NOT NULL REFERENCES ${mediaTable('media_libraries')}(id) ON DELETE CASCADE,
            profile_id integer NOT NULL CHECK (profile_id >= 1 AND profile_id <= 1000000),
            can_stream boolean NOT NULL DEFAULT true,
            can_download boolean NOT NULL DEFAULT false,
            granted_by uuid NULL,
            granted_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (library_id, profile_id)
          );
        `);
          await connection.query(`
          CREATE TABLE IF NOT EXISTS ${mediaTable('media_library_index')} (
            id uuid PRIMARY KEY,
            library_id uuid NOT NULL REFERENCES ${mediaTable('media_libraries')}(id) ON DELETE CASCADE,
            item_path text NOT NULL CHECK (length(trim(item_path)) BETWEEN 1 AND 2048),
            title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 300),
            media_kind text NOT NULL DEFAULT 'other' CHECK (media_kind IN ('movie', 'series', 'home_video', 'live_show', 'other')),
            season integer NULL CHECK (season IS NULL OR season >= 0),
            episode integer NULL CHECK (episode IS NULL OR episode >= 0),
            poster_url text NULL,
            backdrop_url text NULL,
            overview text NULL,
            tmdb_id integer NULL,
            source_mtime timestamptz NULL,
            last_indexed_at timestamptz NOT NULL DEFAULT now(),
            UNIQUE (library_id, item_path)
          );
        `);
          await connection.query(`
          CREATE TABLE IF NOT EXISTS ${mediaTable('media_library_progress')} (
            household_id uuid NOT NULL REFERENCES millitop_tv.households(id) ON DELETE CASCADE,
            profile_id integer NOT NULL CHECK (profile_id >= 1 AND profile_id <= 1000000),
            item_id uuid NOT NULL REFERENCES ${mediaTable('media_library_index')}(id) ON DELETE CASCADE,
            position_ms bigint NOT NULL DEFAULT 0 CHECK (position_ms >= 0),
            duration_ms bigint NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
            complete boolean NOT NULL DEFAULT false,
            updated_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (household_id, profile_id, item_id)
          );
        `);
          await connection.query(
            `CREATE INDEX IF NOT EXISTS media_library_index_library_idx
             ON ${mediaTable('media_library_index')} (library_id, title)`
          );
          await connection.query(
            `CREATE INDEX IF NOT EXISTS media_library_progress_household_profile_idx
             ON ${mediaTable('media_library_progress')} (household_id, profile_id, updated_at DESC)`
          );
          await connection.query('COMMIT');
          return;
        } catch (error) {
          await connection.query('ROLLBACK').catch(() => {});
          const message = String(error?.message ?? '').toLowerCase();
          if (
            message.includes('permission denied for schema') &&
            mediaSchema === 'millitop_tv' &&
            !attemptedSchemas.has('public')
          ) {
            mediaSchema = 'public';
            continue;
          }
          if (message.includes('permission denied for schema') && mediaSchema === 'public') {
            return;
          }
          throw error;
        } finally {
          connection.release();
        }
      }
    })();
  }
  return schemaReady;
}

async function loadHouseholdProfiles(connection, householdId) {
  const row = await connection.query(
    `SELECT payload
     FROM millitop_tv.profile_sync_entities
     WHERE household_id = $1
       AND profile_id = '00000000-0000-0000-0000-000000000001'
       AND kind = 'preference'
       AND entity_key = 'live_tv_profiles:household'
       AND NOT deleted
     ORDER BY updated_at DESC
     LIMIT 1`,
    [householdId]
  );
  const payload = row.rows[0]?.payload;
  const profiles = Array.isArray(payload?.profiles) ? payload.profiles : [];
  return profiles
    .filter(
      item =>
        item &&
        typeof item === 'object' &&
        item.deleted !== true &&
        Number.isSafeInteger(Number(item.id))
    )
    .map(item => ({
      id: Number(item.id),
      name: String(item.name ?? '').trim() || `Profile ${item.id}`,
    }))
    .sort((a, b) => a.id - b.id);
}

async function scanLibraryFiles(basePath, maxItems = 15000) {
  const values = [];
  const pending = [basePath];
  while (pending.length > 0 && values.length < maxItems) {
    const current = pending.pop();
    let entries = [];
    try {
      entries = await fs.readdir(current, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      if (values.length >= maxItems) {
        break;
      }
      const resolved = path.join(current, entry.name);
      if (entry.isDirectory()) {
        pending.push(resolved);
        continue;
      }
      if (!entry.isFile()) {
        continue;
      }
      const ext = path.extname(entry.name).toLowerCase();
      if (!videoExtensions.has(ext)) {
        continue;
      }
      values.push(resolved);
    }
  }
  return values;
}

function guessMediaKind(filePath) {
  const value = filePath.toLowerCase();
  if (/s\d{1,2}e\d{1,2}/i.test(value) || /season[\s._-]?\d+/i.test(value)) {
    return 'series';
  }
  if (value.includes('concert') || value.includes('live')) {
    return 'live_show';
  }
  if (value.includes('home') || value.includes('family')) {
    return 'home_video';
  }
  return 'movie';
}

function cleanTitle(filePath) {
  return path
    .basename(filePath, path.extname(filePath))
    .replace(/[._]/g, ' ')
    .replace(/\[[^\]]+\]/g, ' ')
    .replace(/\([^\)]*\)/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizeMediaPath(filePath) {
  return String(filePath ?? '').replace(/\\/g, '/');
}

function cleanDisplayValue(value) {
  return String(value ?? '')
    .replace(/[._]/g, ' ')
    .replace(/\[[^\]]+\]/g, ' ')
    .replace(/\([^\)]*\)/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function parseEpisodeMetadata(filePath) {
  const normalizedPath = normalizeMediaPath(filePath);
  const segments = normalizedPath.split('/').filter(Boolean);
  const fileName = path.basename(normalizedPath, path.extname(normalizedPath));
  const cleanedFileName = cleanDisplayValue(fileName);
  let season = null;
  let episode = null;
  let seriesTitle = '';
  let episodeTitle = cleanedFileName;

  const sxe = fileName.match(/s(\d{1,2})[\s._-]*e(\d{1,3})/i);
  const xPattern = fileName.match(/(\d{1,2})x(\d{1,3})/i);
  if (sxe) {
    season = Number.parseInt(sxe[1], 10);
    episode = Number.parseInt(sxe[2], 10);
    seriesTitle = cleanDisplayValue(fileName.slice(0, sxe.index));
    episodeTitle = cleanDisplayValue(fileName.slice((sxe.index ?? 0) + sxe[0].length));
  } else if (xPattern) {
    season = Number.parseInt(xPattern[1], 10);
    episode = Number.parseInt(xPattern[2], 10);
    seriesTitle = cleanDisplayValue(fileName.slice(0, xPattern.index));
    episodeTitle = cleanDisplayValue(fileName.slice((xPattern.index ?? 0) + xPattern[0].length));
  } else {
    const seasonSegmentIndex = segments.findIndex(value => /season[\s._-]?\d+/i.test(value));
    if (seasonSegmentIndex >= 0) {
      const seasonMatch = segments[seasonSegmentIndex].match(/season[\s._-]?(\d{1,2})/i);
      season = seasonMatch ? Number.parseInt(seasonMatch[1], 10) : null;
      const episodeMatch = fileName.match(/(?:episode|ep|e)[\s._-]?(\d{1,3})/i);
      episode = episodeMatch ? Number.parseInt(episodeMatch[1], 10) : null;
      if (seasonSegmentIndex > 0) {
        seriesTitle = cleanDisplayValue(segments[seasonSegmentIndex - 1]);
      }
    }
  }

  if (!seriesTitle && segments.length >= 2) {
    seriesTitle = cleanDisplayValue(segments[segments.length - 2]);
  }
  if (!episodeTitle) {
    episodeTitle = cleanedFileName;
  }
  return {
    season: Number.isSafeInteger(season) ? season : null,
    episode: Number.isSafeInteger(episode) ? episode : null,
    seriesTitle: seriesTitle || cleanDisplayValue(segments[segments.length - 2] ?? ''),
    episodeTitle,
  };
}

async function buildFallbackCatalogLibraries(fallbackLibraries) {
  const allowedLibraries = fallbackLibraries.filter(
    library => library.enabled !== false
  );
  const groupedLibraries = {};
  for (const library of allowedLibraries) {
    const metadata = parseLibraryNameMetadata(library.name);
    const collectionKey = metadata.displayName.toLowerCase();
    if (!groupedLibraries[collectionKey]) {
      groupedLibraries[collectionKey] = {
        id: collectionKey,
        name: metadata.displayName,
        sharePaths: [],
        tmdbEnabled: library.tmdbEnabled !== false,
        items: [],
        seriesMap: {},
      };
    }
    if (!groupedLibraries[collectionKey].sharePaths.includes(library.sharePath)) {
      groupedLibraries[collectionKey].sharePaths.push(library.sharePath);
    }
    if (library.tmdbEnabled === false) {
      groupedLibraries[collectionKey].tmdbEnabled = false;
    }
    let files = [];
    const cacheKey = isSmbPath(library.sharePath)
      ? scanCacheKey({
          type: 'smb',
          pathValue: library.sharePath,
          username: library.smbUsername,
          domain: library.smbDomain,
          password: library.smbPassword,
        })
      : scanCacheKey({
          type: 'local',
          pathValue: library.sharePath,
          username: '',
          domain: '',
          password: '',
        });
    const cachedFiles = readScanCache(cacheKey);
    if (cachedFiles) {
      files = cachedFiles;
    }
    try {
      if (!cachedFiles) {
        files = isSmbPath(library.sharePath)
          ? await scanSmbLibraryFiles(
              library.sharePath,
              library.smbUsername,
              library.smbPassword,
              library.smbDomain,
              15000
            )
          : await scanLibraryFiles(library.sharePath, 15000);
        writeScanCache(cacheKey, files);
      }
    } catch (_) {
      files = [];
    }
    console.info(
      `[media-library/catalog] fallback-scan name="${metadata.displayName}" path="${library.sharePath}" user="${library.smbUsername || ''}" hasPassword=${library.smbPassword ? 'yes' : 'no'} files=${files.length}`
    );

    for (const filePath of files) {
      const title = cleanTitle(filePath);
      if (!title) {
        continue;
      }
      const mediaKind = metadata.mediaKindOverride || guessMediaKind(filePath);
      const episodeMetadata =
        mediaKind === 'series'
          ? parseEpisodeMetadata(filePath)
          : { season: null, episode: null, episodeTitle: title };
      const itemEntry = {
        id: createHash('sha256')
          .update(`${library.id}:${filePath}`)
          .digest('hex')
          .slice(0, 24),
        path: filePath,
        title: mediaKind === 'series' ? episodeMetadata.episodeTitle : title,
        mediaKind,
        season: episodeMetadata.season,
        episode: episodeMetadata.episode,
        posterUrl: null,
        backdropUrl: null,
        overview: null,
        indexedAt: null,
        progress: null,
      };
      groupedLibraries[collectionKey].items.push(itemEntry);

      if (mediaKind === 'series') {
        const seriesKey = episodeMetadata.seriesTitle || metadata.displayName;
        if (!groupedLibraries[collectionKey].seriesMap[seriesKey]) {
          groupedLibraries[collectionKey].seriesMap[seriesKey] = {
            title: seriesKey,
            seasonsMap: {},
          };
        }
        const seasonNumber = itemEntry.season ?? 0;
        if (!groupedLibraries[collectionKey].seriesMap[seriesKey].seasonsMap[seasonNumber]) {
          groupedLibraries[collectionKey].seriesMap[seriesKey].seasonsMap[seasonNumber] = {
            season: seasonNumber,
            episodes: [],
          };
        }
        groupedLibraries[collectionKey].seriesMap[seriesKey].seasonsMap[seasonNumber].episodes.push({
          id: itemEntry.id,
          title: itemEntry.title,
          path: itemEntry.path,
          episode: itemEntry.episode,
          posterUrl: null,
          backdropUrl: null,
          overview: null,
          progress: null,
        });
      }
    }
  }
  return Object.values(groupedLibraries).map(library => {
    const series = Object.values(library.seriesMap ?? {})
      .map(seriesItem => ({
        title: seriesItem.title,
        seasons: Object.values(seriesItem.seasonsMap)
          .sort((a, b) => a.season - b.season)
          .map(seasonItem => ({
            season: seasonItem.season,
            episodes: seasonItem.episodes.sort(
              (a, b) =>
                (a.episode ?? 0) - (b.episode ?? 0) ||
                a.title.localeCompare(b.title)
            ),
          })),
      }))
      .sort((a, b) => a.title.localeCompare(b.title));
    return {
      id: library.id,
      name: library.name,
      sharePaths: library.sharePaths,
      tmdbEnabled: library.tmdbEnabled,
      items: library.items,
      series,
    };
  });
}

export function registerMediaLibraryRoutes(app, pool, deviceLimit) {
  if (typeof deviceLimit !== 'function') {
    throw new Error('Device rate limiter required.');
  }

  app.post('/api/admin/media-library/test-share', async (req, res) => {
    let sharePath;
    const smbUsername = String(req.body?.smbUsername ?? '').trim();
    const smbPassword = String(req.body?.smbPassword ?? '').trim();
    const smbDomain = String(req.body?.smbDomain ?? '').trim();
    try {
      sharePath = parseSharePath(req.body?.sharePath);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    if (isSmbPath(sharePath)) {
      try {
        const entries = await browseSmbShare(
          sharePath,
          smbUsername,
          smbPassword,
          smbDomain
        );
        return res.json({
          reachable: true,
          path: sharePath,
          isDirectory: true,
          sample: entries.slice(0, 20),
          scanned: entries.length,
        });
      } catch (error) {
        return res.json({
          reachable: false,
          path: sharePath,
          error: String(error?.message ?? 'Unable to authenticate or list SMB share.'),
        });
      }
    }
    try {
      const stat = await fs.stat(sharePath);
      const values = stat.isDirectory()
        ? await fs.readdir(sharePath, { withFileTypes: true })
        : [];
      return res.json({
        reachable: true,
        path: sharePath,
        isDirectory: stat.isDirectory(),
        sample: values.slice(0, 20).map(item => ({
          name: item.name,
          kind: item.isDirectory() ? 'directory' : 'file',
          path: path.join(sharePath, item.name),
        })),
      });
    } catch (error) {
      return res.json({
        reachable: false,
        path: sharePath,
        error: String(error?.message ?? 'Unable to access share path.'),
      });
    }
  });

  app.post('/api/admin/media-library/browse-share', async (req, res) => {
    let sharePath;
    const smbUsername = String(req.body?.smbUsername ?? '').trim();
    const smbPassword = String(req.body?.smbPassword ?? '').trim();
    const smbDomain = String(req.body?.smbDomain ?? '').trim();
    try {
      sharePath = parseSharePath(req.body?.sharePath);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    if (isSmbPath(sharePath)) {
      try {
        const entries = await browseSmbShare(sharePath, smbUsername, smbPassword, smbDomain);
        return res.json({
          path: sharePath,
          entries,
        });
      } catch (error) {
        return res.status(400).json({
          error: String(error?.message ?? 'Unable to browse SMB share.'),
        });
      }
    }
    try {
      const values = await fs.readdir(sharePath, { withFileTypes: true });
      return res.json({
        path: sharePath,
        entries: values.slice(0, 500).map(item => ({
          name: item.name,
          type: item.isDirectory() ? 'directory' : 'file',
          path: path.join(sharePath, item.name),
        })),
      });
    } catch (error) {
      return res.status(400).json({
        error: String(error?.message ?? 'Unable to browse path.'),
      });
    }
  });

  app.get('/api/admin/media-library/households/:householdId/sources', async (req, res, next) => {
    let householdId;
    try {
      householdId = parseHouseholdId(req.params.householdId);
      await ensureSchema(pool);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    let connection;
    try {
      connection = await pool.connect();
      const sources = await loadFallbackSources(connection, householdId);
      return res.json({ sources });
    } catch (error) {
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/admin/media-library/households/:householdId/sources', async (req, res, next) => {
    let householdId;
    let sourceInput;
    try {
      householdId = parseHouseholdId(req.params.householdId);
      sourceInput = parseSourceInput(req.body ?? {});
      await ensureSchema(pool);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    const sourceIdRaw = req.body?.id;
    const sourceId = sourceIdRaw ? parseLibraryId(sourceIdRaw) : randomUUID();
    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const existing = await loadFallbackSources(connection, householdId);
      const previous = existing.find(item => item.id === sourceId);
      if (
        sourceInput.smbUsername &&
        !sourceInput.smbPassword &&
        !previous?.smbPassword
      ) {
        await connection.query('ROLLBACK');
        return res.status(400).json({
          error: 'SMB password is required for this source. Enter password and save again.',
        });
      }
      const nextSources = existing.filter(item => item.id !== sourceId);
      nextSources.push({
        id: sourceId,
        name: sourceInput.name,
        rootPath: sourceInput.rootPath,
        smbUsername: sourceInput.smbUsername,
        smbPassword:
          sourceInput.smbPassword ||
          previous?.smbPassword ||
          '',
        smbDomain: sourceInput.smbDomain,
        tmdbApiKey: sourceInput.tmdbApiKey,
        enabled: sourceInput.enabled,
        createdAt: previous?.createdAt ?? new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      await saveFallbackSources(connection, householdId, nextSources);
      await connection.query('COMMIT');
      return res.status(201).json({ saved: true, id: sourceId });
    } catch (error) {
      if (connection) {
        await connection.query('ROLLBACK').catch(() => {});
      }
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/admin/media-library/sources/:sourceId/delete', async (req, res, next) => {
    let sourceId;
    try {
      sourceId = parseLibraryId(req.params.sourceId);
      await ensureSchema(pool);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    let connection;
    try {
      connection = await pool.connect();
      await connection.query('BEGIN');
      const entities = await connection.query(
        `SELECT household_id
         FROM millitop_tv.profile_sync_entities
         WHERE profile_id = $1
           AND kind = $2
           AND entity_key = $3
           AND NOT deleted`,
        [fallbackProfileId, fallbackKind, fallbackSourcesEntityKey]
      );
      let removed = false;
      for (const row of entities.rows) {
        const current = await loadFallbackSources(connection, row.household_id);
        const next = current.filter(item => item.id !== sourceId);
        if (next.length !== current.length) {
          removed = true;
          await saveFallbackSources(connection, row.household_id, next);
        }
      }
      await connection.query('COMMIT');
      if (!removed) {
        return res.status(404).json({ error: 'Source not found.' });
      }
      return res.json({ removed: true });
    } catch (error) {
      if (connection) {
        await connection.query('ROLLBACK').catch(() => {});
      }
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.get('/api/admin/media-library/households/:householdId', async (req, res, next) => {
    let householdId;
    try {
      householdId = parseHouseholdId(req.params.householdId);
      await ensureSchema(pool);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    try {
      const structured = await hasStructuredMediaTables(pool);
      if (!structured) {
        const connection = await pool.connect();
        try {
          const [profiles, libraries] = await Promise.all([
            loadHouseholdProfiles(connection, householdId),
            loadFallbackLibraries(connection, householdId),
          ]);
          return res.json({ libraries, profiles });
        } finally {
          connection.release();
        }
      }
      const [librariesResult, profilesResult] = await Promise.all([
        pool.query(
          `SELECT l.id, l.household_id, l.name, l.share_path, l.enabled, l.tmdb_enabled,
                  l.tmdb_api_key, l.smb_username, l.smb_domain, l.smb_password,
                  l.created_at, l.updated_at,
                  array_remove(array_agg(a.profile_id ORDER BY a.profile_id), NULL) AS profile_ids
           FROM ${mediaTable('media_libraries')} l
           LEFT JOIN ${mediaTable('media_library_acl')} a ON a.library_id = l.id
           WHERE l.household_id = $1
           GROUP BY l.id
           ORDER BY l.created_at DESC`,
          [householdId]
        ),
        (async () => {
          const connection = await pool.connect();
          try {
            return await loadHouseholdProfiles(connection, householdId);
          } finally {
            connection.release();
          }
        })(),
      ]);
      res.json({
        libraries: librariesResult.rows.map(row => ({
          ...parseLibraryNameMetadata(row.name),
          id: row.id,
          householdId: row.household_id,
          name: row.name,
          sharePath: row.share_path,
          enabled: row.enabled,
          tmdbEnabled: row.tmdb_enabled,
          tmdbApiKey: row.tmdb_api_key || '',
          smbUsername: row.smb_username || '',
          smbDomain: row.smb_domain || '',
          hasSmbPassword: Boolean(row.smb_password),
          profileIds: Array.isArray(row.profile_ids)
            ? row.profile_ids.map(value => Number(value))
            : [],
          createdAt: row.created_at,
          updatedAt: row.updated_at,
        })),
        profiles: profilesResult,
      });
    } catch (error) {
      next(error);
    }
  });

  app.post('/api/admin/media-library/households/:householdId/libraries', async (req, res, next) => {
    let householdId;
    let libraryInput;
    let profileIds;
    try {
      householdId = parseHouseholdId(req.params.householdId);
      libraryInput = parseLibraryInput(req.body ?? {});
      profileIds = parseAclProfileIds(req.body?.profileIds ?? []);
      await ensureSchema(pool);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }

    const libraryIdRaw = req.body?.id;
    const libraryId = libraryIdRaw ? parseLibraryId(libraryIdRaw) : randomUUID();
    const storedLibraryName = encodeLibraryName(libraryInput.name, libraryInput.mediaKind);
    let connection;
    try {
      const structured = await hasStructuredMediaTables(pool);
      connection = await pool.connect();
      await connection.query('BEGIN');
      if (!structured) {
        const existing = await loadFallbackLibraries(connection, householdId);
        const next = existing.filter(item => item.id !== libraryId);
        next.push({
          id: libraryId,
          householdId,
          name: storedLibraryName,
          sharePath: libraryInput.sharePath,
          enabled: libraryInput.enabled,
          tmdbEnabled: libraryInput.tmdbEnabled,
          tmdbApiKey: libraryInput.tmdbApiKey,
          smbUsername: libraryInput.smbUsername,
          smbPassword: libraryInput.smbPassword,
          smbDomain: libraryInput.smbDomain,
          profileIds,
          mediaKindOverride: libraryInput.mediaKind === 'auto' ? '' : libraryInput.mediaKind,
          displayName: libraryInput.name,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        });
        await saveFallbackLibraries(connection, householdId, next);
        await connection.query('COMMIT');
        return res.status(201).json({ saved: true, id: libraryId, fallback: true });
      }
      await connection.query(
        `INSERT INTO ${mediaTable('media_libraries')}
           (id, household_id, name, share_path, enabled, tmdb_enabled, tmdb_api_key, smb_username, smb_password, smb_domain, created_by, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, now())
         ON CONFLICT (id)
         DO UPDATE SET
           name = EXCLUDED.name,
           share_path = EXCLUDED.share_path,
           enabled = EXCLUDED.enabled,
           tmdb_enabled = EXCLUDED.tmdb_enabled,
           tmdb_api_key = EXCLUDED.tmdb_api_key,
           smb_username = EXCLUDED.smb_username,
           smb_password = COALESCE(NULLIF(EXCLUDED.smb_password, ''), ${mediaTable('media_libraries')}.smb_password),
           smb_domain = EXCLUDED.smb_domain,
           updated_at = now()`,
        [
          libraryId,
          householdId,
          storedLibraryName,
          libraryInput.sharePath,
          libraryInput.enabled,
          libraryInput.tmdbEnabled,
          libraryInput.tmdbApiKey,
          libraryInput.smbUsername,
          libraryInput.smbPassword,
          libraryInput.smbDomain,
          req.admin.id,
        ]
      );
      await connection.query(
        `DELETE FROM ${mediaTable('media_library_acl')}
         WHERE library_id = $1`,
        [libraryId]
      );
      for (const profileId of profileIds) {
        await connection.query(
          `INSERT INTO ${mediaTable('media_library_acl')}
             (library_id, profile_id, can_stream, can_download, granted_by)
           VALUES ($1, $2, true, false, $3)`,
          [libraryId, profileId, req.admin.id]
        );
      }
      await connection.query('COMMIT');
      res.status(201).json({ saved: true, id: libraryId });
    } catch (error) {
      if (connection) {
        await connection.query('ROLLBACK').catch(() => {});
      }
      next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/admin/media-library/libraries/:libraryId/delete', async (req, res, next) => {
    let libraryId;
    try {
      libraryId = parseLibraryId(req.params.libraryId);
      await ensureSchema(pool);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
    try {
      const structured = await hasStructuredMediaTables(pool);
      if (!structured) {
        const connection = await pool.connect();
        try {
          await connection.query('BEGIN');
          const households = await connection.query(
            `SELECT household_id
             FROM millitop_tv.profile_sync_entities
             WHERE profile_id = $1
               AND kind = $2
               AND entity_key = $3
               AND NOT deleted`,
            [fallbackProfileId, fallbackKind, fallbackEntityKey]
          );
          let removed = false;
          for (const row of households.rows) {
            const existing = await loadFallbackLibraries(connection, row.household_id);
            const next = existing.filter(item => item.id !== libraryId);
            if (next.length !== existing.length) {
              removed = true;
              await saveFallbackLibraries(connection, row.household_id, next);
            }
          }
          await connection.query('COMMIT');
          if (!removed) {
            return res.status(404).json({ error: 'Library not found.' });
          }
          return res.json({ removed: true, fallback: true });
        } catch (error) {
          await connection.query('ROLLBACK').catch(() => {});
          throw error;
        } finally {
          connection.release();
        }
      }
      const result = await pool.query(
        `DELETE FROM ${mediaTable('media_libraries')}
         WHERE id = $1`,
        [libraryId]
      );
      if (!result.rowCount) {
        return res.status(404).json({ error: 'Library not found.' });
      }
      return res.json({ removed: true });
    } catch (error) {
      next(error);
    }
  });

  app.post('/api/admin/media-library/libraries/:libraryId/index', async (req, res, next) => {
    let libraryId;
    try {
      libraryId = parseLibraryId(req.params.libraryId);
      await ensureSchema(pool);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }

    let connection;
    try {
      const structured = await hasStructuredMediaTables(pool);
      if (!structured) {
        return res.json({ indexed: 0, scanned: 0, fallback: true });
      }
      connection = await pool.connect();
      await connection.query('BEGIN');
      const library = await connection.query(
        `SELECT id, household_id, name, share_path, enabled, smb_username, smb_password, smb_domain
         FROM ${mediaTable('media_libraries')}
         WHERE id = $1
         FOR UPDATE`,
        [libraryId]
      );
      if (!library.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(404).json({ error: 'Library not found.' });
      }
      if (!library.rows[0].enabled) {
        await connection.query('ROLLBACK');
        return res.status(400).json({ error: 'Enable the library before indexing.' });
      }
      const libraryRow = library.rows[0];
      const metadata = parseLibraryNameMetadata(libraryRow.name);
      const files = isSmbPath(libraryRow.share_path)
        ? await scanSmbLibraryFiles(
            libraryRow.share_path,
            libraryRow.smb_username,
            libraryRow.smb_password,
            libraryRow.smb_domain
          )
        : await scanLibraryFiles(libraryRow.share_path);
      await connection.query(
        `DELETE FROM ${mediaTable('media_library_index')}
         WHERE library_id = $1`,
        [libraryId]
      );
      let inserted = 0;
      for (const filePath of files) {
        const title = cleanTitle(filePath);
        if (!title) {
          continue;
        }
        let mtime = null;
        try {
          const stat = await fs.stat(filePath);
          mtime = stat.mtime.toISOString();
        } catch (_) {}
        const mediaKind = metadata.mediaKindOverride || guessMediaKind(filePath);
        const episodeMetadata = mediaKind === 'series'
          ? parseEpisodeMetadata(filePath)
          : { season: null, episode: null, episodeTitle: title };
        await connection.query(
          `INSERT INTO ${mediaTable('media_library_index')}
             (id, library_id, item_path, title, media_kind, season, episode, source_mtime, last_indexed_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())`,
          [
            randomUUID(),
            libraryId,
            filePath,
            mediaKind === 'series' ? episodeMetadata.episodeTitle : title,
            mediaKind,
            episodeMetadata.season,
            episodeMetadata.episode,
            mtime
          ]
        );
        inserted++;
      }
      await connection.query('COMMIT');
      return res.json({ indexed: inserted, scanned: files.length });
    } catch (error) {
      if (connection) {
        await connection.query('ROLLBACK').catch(() => {});
      }
      next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/device/media-library/catalog', deviceLimit, async (req, res, next) => {
    let profileId;
    let connection;
    try {
      profileId = parseProfileId(req.body?.profileId);
      await ensureSchema(pool);
      const structured = await hasStructuredMediaTables(pool);
      if (!structured) {
        connection = await pool.connect();
        await connection.query('BEGIN');
        const device = await authenticateDevice(connection, req);
        if (!device) {
          console.warn('[media-library/catalog] unauthorized fallback request');
          await connection.query('ROLLBACK');
          return res.status(401).json({ error: 'Device authentication required.' });
        }
        const [fallbackLibrariesRaw, fallbackSources] = await Promise.all([
          loadFallbackLibraries(connection, device.household_id),
          loadFallbackSources(connection, device.household_id),
        ]);
        const fallbackLibraries = hydrateFallbackLibrariesWithSourceCredentials(
          fallbackLibrariesRaw,
          fallbackSources
        );
        await connection.query('COMMIT');
        connection.release();
        connection = null;
        const normalizedLibraries = await buildFallbackCatalogLibraries(fallbackLibraries);
        console.info(
          `[media-library/catalog] fallback household=${device.household_id} profile=${profileId} libraries=${normalizedLibraries.length}`
        );
        return res.json({ profileId, libraries: normalizedLibraries, fallback: true });
      }
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await authenticateDevice(connection, req);
      if (!device) {
        console.warn('[media-library/catalog] unauthorized structured request');
        await connection.query('ROLLBACK');
        return res.status(401).json({ error: 'Device authentication required.' });
      }
      const result = await connection.query(
        `SELECT
           l.id AS library_id,
           l.name AS library_name,
           l.share_path,
           l.tmdb_enabled,
           i.id AS item_id,
           i.item_path,
           i.title,
           i.media_kind,
           i.season,
           i.episode,
           i.poster_url,
           i.backdrop_url,
           i.overview,
           i.last_indexed_at,
           p.position_ms,
           p.duration_ms,
           p.complete,
           p.updated_at AS progress_updated_at
         FROM ${mediaTable('media_libraries')} l
         JOIN ${mediaTable('media_library_acl')} a
           ON a.library_id = l.id
          AND a.profile_id = $2
          AND a.can_stream = true
         LEFT JOIN ${mediaTable('media_library_index')} i
           ON i.library_id = l.id
         LEFT JOIN ${mediaTable('media_library_progress')} p
           ON p.item_id = i.id
          AND p.household_id = l.household_id
          AND p.profile_id = $2
         WHERE l.household_id = $1
           AND l.enabled = true
         ORDER BY l.name ASC, i.title ASC`,
        [device.household_id, profileId]
      );
      await connection.query('COMMIT');
      const libraries = {};
      for (const row of result.rows) {
        const metadata = parseLibraryNameMetadata(row.library_name);
        const collectionKey = metadata.displayName.toLowerCase();
        if (!libraries[collectionKey]) {
          libraries[collectionKey] = {
            id: collectionKey,
            name: metadata.displayName,
            sharePaths: [],
            tmdbEnabled: row.tmdb_enabled,
            items: [],
            series: [],
          };
        }
        if (!libraries[collectionKey].sharePaths.includes(row.share_path)) {
          libraries[collectionKey].sharePaths.push(row.share_path);
        }
        if (row.item_id) {
          const itemEntry = {
            id: row.item_id,
            path: row.item_path,
            title: row.title,
            mediaKind: row.media_kind,
            season: row.season == null ? null : Number(row.season),
            episode: row.episode == null ? null : Number(row.episode),
            posterUrl: row.poster_url,
            backdropUrl: row.backdrop_url,
            overview: row.overview,
            indexedAt: row.last_indexed_at,
            progress:
              row.position_ms == null
                ? null
                : {
                    positionMs: Number(row.position_ms),
                    durationMs: Number(row.duration_ms ?? 0),
                    complete: row.complete === true,
                    updatedAt: row.progress_updated_at,
                  },
          };
          libraries[collectionKey].items.push(itemEntry);

          if (itemEntry.mediaKind === 'series') {
            const parsed = parseEpisodeMetadata(row.item_path);
            const seriesKey = parsed.seriesTitle || metadata.displayName;
            if (!libraries[collectionKey].seriesMap) {
              libraries[collectionKey].seriesMap = {};
            }
            if (!libraries[collectionKey].seriesMap[seriesKey]) {
              libraries[collectionKey].seriesMap[seriesKey] = {
                title: seriesKey,
                seasonsMap: {},
              };
            }
            const seasonNumber = itemEntry.season ?? parsed.season ?? 0;
            if (!libraries[collectionKey].seriesMap[seriesKey].seasonsMap[seasonNumber]) {
              libraries[collectionKey].seriesMap[seriesKey].seasonsMap[seasonNumber] = {
                season: seasonNumber,
                episodes: [],
              };
            }
            libraries[collectionKey].seriesMap[seriesKey].seasonsMap[seasonNumber].episodes.push({
              id: itemEntry.id,
              title: itemEntry.title,
              path: itemEntry.path,
              episode: itemEntry.episode ?? parsed.episode,
              posterUrl: itemEntry.posterUrl,
              backdropUrl: itemEntry.backdropUrl,
              overview: itemEntry.overview,
              progress: itemEntry.progress,
            });
          }
        }
      }
      const normalizedLibraries = Object.values(libraries).map(library => {
        const series = Object.values(library.seriesMap ?? {})
          .map(seriesItem => ({
            title: seriesItem.title,
            seasons: Object.values(seriesItem.seasonsMap)
              .sort((a, b) => a.season - b.season)
              .map(seasonItem => ({
                season: seasonItem.season,
                episodes: seasonItem.episodes
                  .sort((a, b) => (a.episode ?? 0) - (b.episode ?? 0) || a.title.localeCompare(b.title)),
              })),
          }))
          .sort((a, b) => a.title.localeCompare(b.title));
        return {
          id: library.id,
          name: library.name,
          sharePaths: library.sharePaths,
          tmdbEnabled: library.tmdbEnabled,
          items: library.items,
          series,
        };
      });
      const [fallbackLibrariesRaw, fallbackSources] = await Promise.all([
        loadFallbackLibraries(connection, device.household_id),
        loadFallbackSources(connection, device.household_id),
      ]);
      const fallbackLibraries = hydrateFallbackLibrariesWithSourceCredentials(
        fallbackLibrariesRaw,
        fallbackSources
      );
      const fallbackCatalog = await buildFallbackCatalogLibraries(fallbackLibraries);
      for (const fallbackLibrary of fallbackCatalog) {
        if (!normalizedLibraries.some(entry => entry.name.toLowerCase() === fallbackLibrary.name.toLowerCase())) {
          normalizedLibraries.push(fallbackLibrary);
        }
      }
      console.info(
        `[media-library/catalog] structured household=${device.household_id} profile=${profileId} dbLibraries=${Object.keys(libraries).length} fallbackLibraries=${fallbackCatalog.length} merged=${normalizedLibraries.length}`
      );
      return res.json({ profileId, libraries: normalizedLibraries });
    } catch (error) {
      if (connection) {
        await connection.query('ROLLBACK').catch(() => {});
      }
      if (error?.message?.includes('Profile ID')) {
        return res.status(400).json({ error: error.message });
      }
      return next(error);
    } finally {
      connection?.release();
    }
  });

  app.post('/api/device/media-library/progress', deviceLimit, async (req, res, next) => {
    let connection;
    try {
      await ensureSchema(pool);
      const structured = await hasStructuredMediaTables(pool);
      const action = String(req.body?.action ?? '').trim().toLowerCase();
      const profileId = parseProfileId(req.body?.profileId);
      if (!structured) {
        if (action === 'get') {
          return res.json({ profileId, progress: [], fallback: true });
        }
        if (action === 'set') {
          return res.json({ saved: true, fallback: true });
        }
      }
      connection = await pool.connect();
      await connection.query('BEGIN');
      const device = await authenticateDevice(connection, req);
      if (!device) {
        await connection.query('ROLLBACK');
        return res.status(401).json({ error: 'Device authentication required.' });
      }
      if (action === 'get') {
        const rows = await connection.query(
          `SELECT p.item_id, p.position_ms, p.duration_ms, p.complete, p.updated_at
           FROM ${mediaTable('media_library_progress')} p
           WHERE p.household_id = $1
             AND p.profile_id = $2
           ORDER BY p.updated_at DESC
           LIMIT 500`,
          [device.household_id, profileId]
        );
        await connection.query('COMMIT');
        return res.json({
          profileId,
          progress: rows.rows.map(row => ({
            itemId: row.item_id,
            positionMs: Number(row.position_ms),
            durationMs: Number(row.duration_ms),
            complete: row.complete === true,
            updatedAt: row.updated_at,
          })),
        });
      }
      if (action !== 'set') {
        await connection.query('ROLLBACK');
        return res.status(400).json({ error: 'Unsupported progress action.' });
      }
      const itemId = parseLibraryId(req.body?.itemId);
      const positionMs = Math.max(0, Number.parseInt(String(req.body?.positionMs ?? '0'), 10) || 0);
      const durationMs = Math.max(0, Number.parseInt(String(req.body?.durationMs ?? '0'), 10) || 0);
      const complete = req.body?.complete === true;
      const access = await connection.query(
        `SELECT 1
         FROM ${mediaTable('media_library_index')} i
         JOIN ${mediaTable('media_libraries')} l ON l.id = i.library_id
         JOIN ${mediaTable('media_library_acl')} a
           ON a.library_id = l.id
          AND a.profile_id = $2
          AND a.can_stream = true
         WHERE i.id = $1
           AND l.household_id = $3
         LIMIT 1`,
        [itemId, profileId, device.household_id]
      );
      if (!access.rowCount) {
        await connection.query('ROLLBACK');
        return res.status(403).json({ error: 'Playback progress access denied for this item.' });
      }
      await connection.query(
        `INSERT INTO ${mediaTable('media_library_progress')}
           (household_id, profile_id, item_id, position_ms, duration_ms, complete, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, now())
         ON CONFLICT (household_id, profile_id, item_id)
         DO UPDATE SET
           position_ms = EXCLUDED.position_ms,
           duration_ms = EXCLUDED.duration_ms,
           complete = EXCLUDED.complete,
           updated_at = now()`,
        [device.household_id, profileId, itemId, positionMs, durationMs, complete]
      );
      await connection.query('COMMIT');
      return res.json({ saved: true });
    } catch (error) {
      if (connection) {
        await connection.query('ROLLBACK').catch(() => {});
      }
      if (
        error?.message?.includes('Profile ID') ||
        error?.message?.includes('library ID')
      ) {
        return res.status(400).json({ error: error.message });
      }
      return next(error);
    } finally {
      connection?.release();
    }
  });
}
