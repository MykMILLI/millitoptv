// Watch parties: shared, synchronized playback with chat and voice.
//
// Roles
//   host  - a paired MILLITOP TV device (device credential) that creates the
//           party and is the single source of truth for media and position.
//   guest - anyone with the link or an email invite, in a browser
//           (/watch/CODE) or in the app. Guests get a party-scoped token.
//
// Realtime: one Server-Sent Events stream per participant
// (GET /api/watch/events) carries state, playback, chat and WebRTC
// signalling. This process keeps live fan-out state in memory, so run a
// single dashboard instance (the current deployment does).
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { rateLimit } from 'express-rate-limit';
import { WatchPartyKeys, loadMasterSecret, hashToken, newToken, newRelayKey, newJoinCode, turnCredentials } from './watch-party-crypto.mjs';
import { WatchPartyRelay, RelayError } from './watch-party-relay.mjs';
import { WatchPartyMailer, composeInvite } from './watch-party-mailer.mjs';
import * as v from './watch-party-validation.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB_DIR = join(HERE, 'watch-party-web');
const HOST_TIMEOUT_MINUTES = 10;
const MAX_PARTY_HOURS = 18;
const TOKEN_PATTERN = /^Bearer (wp_[A-Za-z0-9_-]{43})$/;
const DEVICE_TOKEN_PATTERN = /^Bearer\s+(\S+)$/i;

export class WatchPartyError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

// ---------------------------------------------------------------------------
// In-memory realtime hub
// ---------------------------------------------------------------------------
export class WatchPartyHub {
  constructor() { this.parties = new Map(); }

  room(partyId) {
    let room = this.parties.get(partyId);
    if (!room) {
      room = { streams: new Map(), voice: new Map(), playback: null, playbackPersistedAt: 0 };
      this.parties.set(partyId, room);
    }
    return room;
  }

  attach(partyId, participantId, res) {
    const room = this.room(partyId);
    let set = room.streams.get(participantId);
    if (!set) { set = new Set(); room.streams.set(participantId, set); }
    set.add(res);
    return () => {
      set.delete(res);
      if (!set.size) {
        room.streams.delete(participantId);
        room.voice.delete(participantId);
      }
    };
  }

  online(partyId, participantId) { return Boolean(this.parties.get(partyId)?.streams.get(participantId)?.size); }

  send(partyId, event, data, { to = null, except = null } = {}) {
    const room = this.parties.get(partyId);
    if (!room) return 0;
    const payload = `event: ${event}\ndata: ${JSON.stringify({ ...data, serverTimeMs: Date.now() })}\n\n`;
    let delivered = 0;
    for (const [participantId, set] of room.streams) {
      if (to && participantId !== to) continue;
      if (except && participantId === except) continue;
      for (const res of set) { res.write(payload); delivered += 1; }
    }
    return delivered;
  }

  close(partyId, participantId = null) {
    const room = this.parties.get(partyId);
    if (!room) return;
    for (const [id, set] of room.streams) {
      if (participantId && id !== participantId) continue;
      for (const res of set) res.end();
    }
    if (!participantId) this.parties.delete(partyId);
  }
}

// ---------------------------------------------------------------------------
// Settings (SMTP / voice / limits), secrets encrypted at rest
// ---------------------------------------------------------------------------
export class WatchPartySettings {
  constructor(pool, keys) { this.pool = pool; this.keys = keys; this.cache = new Map(); }

  async read(key) {
    const cached = this.cache.get(key);
    if (cached && Date.now() - cached.at < 30000) return cached.value;
    const r = await this.pool.query('SELECT value, secret_ct, updated_at FROM millitop_tv.watch_party_settings WHERE key=$1', [key]);
    const row = r.rows[0];
    const value = row ? { ...row.value, updatedAt: row.updated_at } : null;
    let secret;
    if (row?.secret_ct) {
      const opened = this.keys.openSetting(row.secret_ct);
      secret = opened?.secret;
      if (!opened) value.secretUnreadable = true;
    }
    const result = { value, secret };
    this.cache.set(key, { at: Date.now(), value: result });
    return result;
  }

  async write(key, value, secret, adminId) {
    const keepSecret = secret === undefined;
    const ct = keepSecret ? null : secret === null ? null : this.keys.sealSetting({ secret });
    await this.pool.query(
      `INSERT INTO millitop_tv.watch_party_settings(key, value, secret_ct, updated_at, updated_by)
       VALUES ($1, $2::jsonb, $3, now(), $4)
       ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value,
         secret_ct=CASE WHEN $5 THEN millitop_tv.watch_party_settings.secret_ct ELSE EXCLUDED.secret_ct END,
         updated_at=now(), updated_by=EXCLUDED.updated_by`,
      [key, JSON.stringify(value), ct, adminId ?? null, keepSecret]
    );
    this.cache.delete(key);
  }

  async smtp() {
    const { value, secret } = await this.read('smtp');
    return value ? { ...value, password: secret } : null;
  }

  async limits() {
    const { value } = await this.read('limits');
    return { maxParticipants: value?.maxParticipants ?? 12, allowPublicJoin: value?.allowPublicJoin !== false };
  }

  async iceServers(subject) {
    const { value, secret } = await this.read('voice');
    const servers = [{ urls: ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478'] }];
    if (value?.turnUrls?.length && secret) {
      servers.push({ urls: value.turnUrls, ...turnCredentials(secret, subject) });
    }
    return servers;
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
export function registerWatchPartyRoutes(app, pool, {
  publicOrigin = 'https://tvadmin.millitop.net',
  keys = new WatchPartyKeys(loadMasterSecret()),
  hub = new WatchPartyHub(),
  relay = null,
  mailer = null,
  settings = null,
  limiter = rateLimit,
  sweepIntervalMs = 60000,
  log = console
} = {}) {
  const origin = String(publicOrigin).replace(/\/+$/, '');
  settings ??= new WatchPartySettings(pool, keys);
  mailer ??= new WatchPartyMailer({ loadSmtp: () => settings.smtp() });
  const relayCache = new Map();
  relay ??= new WatchPartyRelay({ keys, resolveRelay: key => resolveRelay(key), log });
  let schemaReady = null;

  const tokenKey = req => {
    const match = TOKEN_PATTERN.exec(req.get('authorization') ?? '');
    return match ? 'wp-' + hashToken(match[1]).slice(0, 32) : 'wp-ip-' + (req.ip ?? 'unknown');
  };
  const limits = {
    lookup: limiter({ windowMs: 60000, limit: 60, standardHeaders: 'draft-8', legacyHeaders: false, message: { error: 'Too many requests. Try again shortly.' } }),
    join: limiter({ windowMs: 10 * 60000, limit: 30, standardHeaders: 'draft-8', legacyHeaders: false, message: { error: 'Too many join attempts. Try again in a few minutes.' } }),
    api: limiter({ windowMs: 60000, limit: 300, keyGenerator: tokenKey, standardHeaders: 'draft-8', legacyHeaders: false, message: { error: 'Too many requests. Slow down a little.' } }),
    signal: limiter({ windowMs: 60000, limit: 900, keyGenerator: tokenKey, standardHeaders: 'draft-8', legacyHeaders: false, message: { error: 'Too many voice messages.' } }),
    invite: limiter({ windowMs: 60 * 60000, limit: 40, keyGenerator: tokenKey, standardHeaders: 'draft-8', legacyHeaders: false, message: { error: 'Invite limit reached for this hour.' } }),
    device: limiter({ windowMs: 60000, limit: 30, standardHeaders: 'draft-8', legacyHeaders: false, message: { error: 'Too many requests. Try again shortly.' } })
  };

  async function ensureSchema() {
    if (schemaReady === true) return;
    const r = await pool.query("SELECT to_regclass('millitop_tv.watch_parties') AS t, to_regclass('millitop_tv.watch_party_schema') AS s");
    if (!r.rows[0].t || !r.rows[0].s) throw new WatchPartyError(503, 'Watch parties are not set up on the server yet (database migration pending).');
    schemaReady = true;
  }

  const wrap = handler => async (req, res, next) => {
    try {
      await ensureSchema();
      await handler(req, res);
    } catch (error) {
      if (error instanceof WatchPartyError || error instanceof RelayError) {
        if (!res.headersSent) res.status(error.status).json({ error: error.message });
        return;
      }
      if (error instanceof v.ValidationError) {
        if (!res.headersSent) res.status(400).json({ error: error.message });
        return;
      }
      next(error);
    }
  };

  const event = (partyId, participantId, action, details = {}) =>
    pool.query('INSERT INTO millitop_tv.watch_party_events(party_id, participant_id, action, details) VALUES ($1,$2,$3,$4::jsonb)',
      [partyId, participantId, action, JSON.stringify(details)]).catch(() => {});

  async function deviceFromRequest(req) {
    const match = DEVICE_TOKEN_PATTERN.exec(req.get('authorization') ?? '');
    if (!match) throw new WatchPartyError(401, 'Device authentication required.');
    const r = await pool.query(
      `SELECT d.id, d.household_id FROM millitop_tv.device_credentials k
       JOIN millitop_tv.devices d ON d.id = k.device_id
       JOIN millitop_tv.households h ON h.id = d.household_id
       WHERE k.token_hash = $1 AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at > now())
         AND d.revoked_at IS NULL AND h.active`,
      [hashToken(match[1])]
    );
    if (!r.rowCount) throw new WatchPartyError(401, 'Device credential is invalid or revoked.');
    return r.rows[0];
  }

  async function participantFromRequest(req, { hostOnly = false } = {}) {
    const match = TOKEN_PATTERN.exec(req.get('authorization') ?? '');
    if (!match) throw new WatchPartyError(401, 'Join the watch party first.');
    const r = await pool.query(
      `SELECT p.id, p.party_id, p.display_name, p.role, p.client_kind, p.relay_key, w.status, w.host_device_id
       FROM millitop_tv.watch_party_participants p
       JOIN millitop_tv.watch_parties w ON w.id = p.party_id
       WHERE p.token_hash = $1 AND p.left_at IS NULL AND p.removed_at IS NULL`,
      [hashToken(match[1])]
    );
    const participant = r.rows[0];
    if (!participant) throw new WatchPartyError(401, 'You are no longer in this watch party.');
    if (participant.status !== 'active') throw new WatchPartyError(410, 'This watch party has ended.');
    if (hostOnly && participant.role !== 'host') throw new WatchPartyError(403, 'Only the host can do that.');
    pool.query('UPDATE millitop_tv.watch_party_participants SET last_seen_at = now() WHERE id = $1 AND last_seen_at < now() - interval \'20 seconds\'', [participant.id]).catch(() => {});
    if (participant.role === 'host') {
      pool.query('UPDATE millitop_tv.watch_parties SET host_seen_at = now() WHERE id = $1 AND host_seen_at < now() - interval \'20 seconds\'', [participant.party_id]).catch(() => {});
    }
    return participant;
  }

  async function loadParty(partyId) {
    const r = await pool.query('SELECT * FROM millitop_tv.watch_parties WHERE id = $1', [partyId]);
    return r.rows[0] ?? null;
  }

  async function participants(partyId) {
    const room = hub.room(partyId);
    const r = await pool.query(
      `SELECT id, display_name, role, client_kind, joined_at FROM millitop_tv.watch_party_participants
       WHERE party_id = $1 AND left_at IS NULL AND removed_at IS NULL ORDER BY role = 'host' DESC, joined_at`,
      [partyId]
    );
    return r.rows.map(row => ({
      id: row.id,
      name: row.display_name,
      role: row.role,
      client: row.client_kind,
      online: hub.online(partyId, row.id),
      voice: room.voice.get(row.id) ?? null
    }));
  }

  function publicMedia(party) {
    if (!party.media_rev || !party.media?.kind) return null;
    return { ...party.media, rev: party.media_rev };
  }

  function currentPlayback(party) {
    const room = hub.room(party.id);
    const stored = room.playback ?? (party.playback?.mediaRev ? party.playback : null);
    return stored ?? null;
  }

  async function snapshot(party, { includeMessages = true } = {}) {
    const people = await participants(party.id);
    const host = people.find(p => p.role === 'host');
    const result = {
      party: {
        id: party.id, title: party.title, code: party.join_code, status: party.status, locked: party.locked,
        joinUrl: `${origin}/watch/${party.join_code}`, hostName: host?.name ?? 'Host', hostOnline: host?.online ?? false,
        createdAt: party.created_at
      },
      media: publicMedia(party),
      playback: currentPlayback(party),
      participants: people,
      serverTimeMs: Date.now()
    };
    if (includeMessages) {
      const messages = await pool.query(
        `SELECT id, participant_id, display_name, body, created_at FROM millitop_tv.watch_party_messages
         WHERE party_id = $1 ORDER BY id DESC LIMIT 100`, [party.id]);
      result.messages = messages.rows.reverse().map(messageDto);
    }
    return result;
  }

  const messageDto = row => ({ id: Number(row.id), from: row.participant_id, name: row.display_name, body: row.body, at: row.created_at });

  async function broadcastState(partyId) {
    const party = await loadParty(partyId);
    if (!party) return;
    hub.send(partyId, 'state', await snapshot(party, { includeMessages: false }));
  }

  async function resolveRelay(relayKey) {
    if (typeof relayKey !== 'string' || !/^[A-Za-z0-9_-]{24}$/.test(relayKey)) return null;
    const cached = relayCache.get(relayKey);
    if (cached && Date.now() - cached.at < 5000) return cached.value;
    const r = await pool.query(
      `SELECT w.id, w.media, w.media_rev, w.upstream_ct FROM millitop_tv.watch_party_participants p
       JOIN millitop_tv.watch_parties w ON w.id = p.party_id
       WHERE p.relay_key = $1 AND p.left_at IS NULL AND p.removed_at IS NULL AND w.status = 'active'`,
      [relayKey]
    );
    const row = r.rows[0];
    const upstream = row?.upstream_ct ? keys.openRelay(row.upstream_ct) : null;
    const value = row ? {
      partyId: row.id, mediaRev: row.media_rev, upstream,
      relayType: row.media?.relay?.type ?? 'file', live: row.media?.live === true
    } : null;
    relayCache.set(relayKey, { at: Date.now(), value });
    if (relayCache.size > 5000) relayCache.delete(relayCache.keys().next().value);
    return value;
  }

  const invalidateRelay = () => relayCache.clear();

  async function addParticipant(client, { partyId, name, role, clientKind, deviceId = null, inviteId = null }) {
    const token = newToken('wp_');
    const relayKey = newRelayKey();
    const id = randomUUID();
    await client.query(
      `INSERT INTO millitop_tv.watch_party_participants(id, party_id, token_hash, relay_key, display_name, role, client_kind, device_id, invite_id)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
      [id, partyId, hashToken(token), relayKey, name, role, clientKind, deviceId, inviteId]
    );
    return { id, token, relayKey, name, role };
  }

  async function transaction(work) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL statement_timeout = '15s'");
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async function endParty(partyId, reason, actor = null) {
    const r = await pool.query(
      `UPDATE millitop_tv.watch_parties SET status = 'ended', ended_at = now(), end_reason = $2, updated_at = now()
       WHERE id = $1 AND status = 'active' RETURNING id`, [partyId, reason]);
    if (!r.rowCount) return false;
    invalidateRelay();
    hub.send(partyId, 'ended', { reason });
    hub.close(partyId);
    await event(partyId, actor, 'party.ended', { reason });
    return true;
  }

  async function sendInvites(party, inviter, emails, note) {
    const media = publicMedia(party);
    const results = [];
    for (const address of emails) {
      const inviteToken = newToken('wi_');
      const inviteId = randomUUID();
      await pool.query(
        `INSERT INTO millitop_tv.watch_party_invites(id, party_id, invited_by, email, token_hash) VALUES ($1,$2,$3,$4,$5)`,
        [inviteId, party.id, inviter.id, address, hashToken(inviteToken)]
      );
      const joinUrl = `${origin}/watch/${party.join_code}?invite=${encodeURIComponent(inviteToken)}`;
      const message = composeInvite({
        hostName: inviter.display_name, partyTitle: party.title,
        nowPlaying: media ? media.title : null, joinUrl, code: party.join_code, note
      });
      const outcome = await mailer.send({ to: address, ...message });
      await pool.query(
        `UPDATE millitop_tv.watch_party_invites SET status = $2, error = $3, sent_at = CASE WHEN $2 = 'sent' THEN now() END WHERE id = $1`,
        [inviteId, outcome.delivered ? 'sent' : 'failed', outcome.delivered ? null : outcome.error?.slice(0, 300) ?? 'Unknown error']
      );
      results.push({ email: address, delivered: outcome.delivered, error: outcome.delivered ? null : outcome.error });
    }
    await event(party.id, inviter.id, 'party.invited', { count: emails.length, delivered: results.filter(r => r.delivered).length });
    return results;
  }

  // ---- Host (paired device) ------------------------------------------------
  app.post('/api/device/watch-parties/create', limits.device, wrap(async (req, res) => {
    const device = await deviceFromRequest(req);
    const title = v.text(req.body?.title ?? 'Watch party', 'Party name', { max: 120 });
    const displayName = v.text(req.body?.displayName ?? 'Host', 'Your name', { max: 60 });
    const created = await transaction(async client => {
      // One active party per device: starting a new one ends the old one.
      const previous = await client.query(
        "UPDATE millitop_tv.watch_parties SET status = 'ended', ended_at = now(), end_reason = 'replaced' WHERE host_device_id = $1 AND status = 'active' RETURNING id",
        [device.id]);
      let party = null;
      for (let attempt = 0; attempt < 6 && !party; attempt += 1) {
        try {
          await client.query('SAVEPOINT code_attempt');
          party = (await client.query(
            `INSERT INTO millitop_tv.watch_parties(id, host_household_id, host_device_id, title, join_code)
             VALUES ($1,$2,$3,$4,$5) RETURNING *`,
            [randomUUID(), device.household_id, device.id, title, newJoinCode()]
          )).rows[0];
        } catch (error) {
          await client.query('ROLLBACK TO SAVEPOINT code_attempt');
          if (error.code !== '23505') throw error;
        }
      }
      if (!party) throw new WatchPartyError(503, 'Could not create a party code. Try again.');
      const host = await addParticipant(client, { partyId: party.id, name: displayName, role: 'host', clientKind: 'app', deviceId: device.id });
      return { party, host, previous: previous.rows.map(r => r.id) };
    });
    for (const id of created.previous) { hub.send(id, 'ended', { reason: 'replaced' }); hub.close(id); }
    await event(created.party.id, created.host.id, 'party.created');
    res.status(201).json({
      participant: { id: created.host.id, token: created.host.token, relayKey: created.host.relayKey, role: 'host', name: created.host.name },
      ...(await snapshot(created.party))
    });
  }));

  // ---- Public lookup & join ------------------------------------------------
  app.get('/api/watch/lookup/:code', limits.lookup, wrap(async (req, res) => {
    const code = v.joinCode(req.params.code);
    const r = await pool.query(
      `SELECT w.id, w.title, w.locked, w.status, w.media, w.media_rev,
         (SELECT display_name FROM millitop_tv.watch_party_participants p WHERE p.party_id = w.id AND p.role = 'host' LIMIT 1) AS host_name,
         (SELECT count(*)::int FROM millitop_tv.watch_party_participants p WHERE p.party_id = w.id AND p.left_at IS NULL AND p.removed_at IS NULL) AS people
       FROM millitop_tv.watch_parties w WHERE w.join_code = $1`, [code]);
    const party = r.rows[0];
    if (!party || party.status !== 'active') throw new WatchPartyError(404, 'This watch party has ended or the code is wrong.');
    res.json({
      title: party.title, hostName: party.host_name ?? 'Host', locked: party.locked, people: party.people,
      nowPlaying: party.media_rev && party.media?.title ? { title: party.media.title, kind: party.media.kind, posterUrl: party.media.posterUrl ?? null } : null
    });
  }));

  app.post('/api/watch/join', limits.join, wrap(async (req, res) => {
    const code = v.joinCode(req.body?.code);
    const name = v.text(req.body?.displayName, 'Your name', { max: 60 });
    const clientKind = req.body?.client === 'app' ? 'app' : 'web';
    const inviteToken = typeof req.body?.invite === 'string' && /^wi_[A-Za-z0-9_-]{43}$/.test(req.body.invite) ? req.body.invite : null;
    const { maxParticipants, allowPublicJoin } = await settings.limits();
    const joined = await transaction(async client => {
      const partyRow = await client.query("SELECT * FROM millitop_tv.watch_parties WHERE join_code = $1 AND status = 'active' FOR UPDATE", [code]);
      const party = partyRow.rows[0];
      if (!party) throw new WatchPartyError(404, 'This watch party has ended or the code is wrong.');
      let invite = null;
      if (inviteToken) {
        invite = (await client.query(
          "SELECT id FROM millitop_tv.watch_party_invites WHERE party_id = $1 AND token_hash = $2", [party.id, hashToken(inviteToken)])).rows[0] ?? null;
      }
      if (!invite && (party.locked || !allowPublicJoin)) throw new WatchPartyError(403, 'The host has locked this party. Ask them for an invite.');
      const count = (await client.query(
        'SELECT count(*)::int AS n FROM millitop_tv.watch_party_participants WHERE party_id = $1 AND left_at IS NULL AND removed_at IS NULL', [party.id])).rows[0].n;
      if (count >= maxParticipants) throw new WatchPartyError(409, `This party is full (${maxParticipants} people).`);
      if (invite) await client.query("UPDATE millitop_tv.watch_party_invites SET status = 'accepted', accepted_at = now() WHERE id = $1", [invite.id]);
      const participant = await addParticipant(client, { partyId: party.id, name, role: 'guest', clientKind, inviteId: invite?.id ?? null });
      return { party, participant };
    });
    await event(joined.party.id, joined.participant.id, 'party.joined', { client: clientKind });
    hub.send(joined.party.id, 'notice', { text: `${name} joined` });
    await broadcastState(joined.party.id);
    res.status(201).json({
      participant: { id: joined.participant.id, token: joined.participant.token, relayKey: joined.participant.relayKey, role: 'guest', name },
      ...(await snapshot(joined.party))
    });
  }));

  // ---- Participant API -----------------------------------------------------
  app.get('/api/watch/session', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    const party = await loadParty(me.party_id);
    res.json({ me: { id: me.id, name: me.display_name, role: me.role, relayKey: me.relay_key }, ...(await snapshot(party)) });
  }));

  app.get('/api/watch/ice', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    res.json({ iceServers: await settings.iceServers(me.id) });
  }));

  app.get('/api/watch/events', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    const party = await loadParty(me.party_id);
    res.status(200);
    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store, no-transform');
    res.setHeader('X-Accel-Buffering', 'no');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders?.();
    res.socket?.setKeepAlive?.(true);
    res.socket?.setNoDelay?.(true);
    req.setTimeout?.(0);
    const wasOnline = hub.online(party.id, me.id);
    const detach = hub.attach(party.id, me.id, res);
    res.write(`retry: 3000\nevent: hello\ndata: ${JSON.stringify({ me: { id: me.id, name: me.display_name, role: me.role, relayKey: me.relay_key }, ...(await snapshot(party)) })}\n\n`);
    if (!wasOnline) broadcastState(party.id).catch(() => {});
    const heartbeat = setInterval(() => {
      res.write(`: keep-alive ${Date.now()}\n\n`);
      pool.query('UPDATE millitop_tv.watch_party_participants SET last_seen_at = now() WHERE id = $1', [me.id]).catch(() => {});
      if (me.role === 'host') pool.query('UPDATE millitop_tv.watch_parties SET host_seen_at = now() WHERE id = $1', [party.id]).catch(() => {});
    }, 15000);
    res.on('close', () => {
      clearInterval(heartbeat);
      const hadVoice = hub.room(party.id).voice.has(me.id);
      detach();
      if (!hub.online(party.id, me.id)) {
        if (hadVoice) hub.send(party.id, 'signal', { from: me.id, kind: 'hangup', payload: {} });
        broadcastState(party.id).catch(() => {});
      }
    });
  }));

  app.post('/api/watch/chat', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    const body = v.text(req.body?.body, 'Message', { max: 1000, multiline: true });
    const row = (await pool.query(
      `INSERT INTO millitop_tv.watch_party_messages(party_id, participant_id, display_name, body) VALUES ($1,$2,$3,$4)
       RETURNING id, participant_id, display_name, body, created_at`, [me.party_id, me.id, me.display_name, body])).rows[0];
    const message = messageDto(row);
    hub.send(me.party_id, 'chat', { message });
    res.status(201).json({ message });
  }));

  app.post('/api/watch/reaction', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    const emoji = typeof req.body?.emoji === 'string' && ['👍', '😂', '😮', '❤️', '👏', '🔥'].includes(req.body.emoji) ? req.body.emoji : null;
    if (!emoji) throw new WatchPartyError(400, 'Unsupported reaction.');
    hub.send(me.party_id, 'reaction', { from: me.id, name: me.display_name, emoji });
    res.json({ ok: true });
  }));

  app.post('/api/watch/voice', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    const room = hub.room(me.party_id);
    if (req.body?.active === true) room.voice.set(me.id, { muted: req.body?.muted === true, listenOnly: req.body?.listenOnly === true });
    else room.voice.delete(me.id);
    await broadcastState(me.party_id);
    res.json({ ok: true });
  }));

  app.post('/api/watch/signal', limits.signal, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    const signal = v.signal(req.body);
    const delivered = hub.send(me.party_id, 'signal', { from: me.id, kind: signal.kind, payload: signal.payload }, { to: signal.to });
    res.json({ delivered: delivered > 0 });
  }));

  app.post('/api/watch/leave', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req);
    if (me.role === 'host') {
      await endParty(me.party_id, 'host-ended', me.id);
      return res.json({ ended: true });
    }
    await pool.query('UPDATE millitop_tv.watch_party_participants SET left_at = now() WHERE id = $1', [me.id]);
    invalidateRelay();
    hub.room(me.party_id).voice.delete(me.id);
    hub.send(me.party_id, 'signal', { from: me.id, kind: 'hangup', payload: {} });
    hub.close(me.party_id, me.id);
    hub.send(me.party_id, 'notice', { text: `${me.display_name} left` });
    await broadcastState(me.party_id);
    await event(me.party_id, me.id, 'party.left');
    res.json({ ended: false });
  }));

  // ---- Host controls -------------------------------------------------------
  app.post('/api/watch/media', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req, { hostOnly: true });
    const { publicMedia: mediaInfo, upstream } = v.media(req.body?.media ?? req.body);
    let probe = null;
    if (upstream) {
      probe = await relay.probe(upstream);
      mediaInfo.relay = { type: probe.type };
    }
    const updated = (await pool.query(
      `UPDATE millitop_tv.watch_parties SET media = $2::jsonb, media_rev = media_rev + 1, upstream_ct = $3,
         playback = '{}'::jsonb, updated_at = now(), host_seen_at = now()
       WHERE id = $1 AND status = 'active' RETURNING *`,
      [me.party_id, JSON.stringify(mediaInfo), upstream ? keys.sealRelay(upstream) : null])).rows[0];
    if (!updated) throw new WatchPartyError(410, 'This watch party has ended.');
    invalidateRelay();
    const room = hub.room(me.party_id);
    room.playback = { mediaRev: updated.media_rev, positionMs: Number(req.body?.positionMs) > 0 ? Math.floor(Number(req.body.positionMs)) : 0, playing: false, buffering: true, rate: 1, updatedAtMs: Date.now() };
    await broadcastState(me.party_id);
    await event(me.party_id, me.id, 'media.changed', { kind: mediaInfo.kind, relay: probe?.type ?? null, reachable: probe?.reachable ?? null });
    res.json({
      mediaRev: updated.media_rev,
      relay: probe ? { type: probe.type, reachable: probe.reachable, warning: probe.reachable ? null : probe.error } : null
    });
  }));

  app.post('/api/watch/playback', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req, { hostOnly: true });
    const state = v.playback(req.body);
    const room = hub.room(me.party_id);
    const party = await loadParty(me.party_id);
    if (state.mediaRev !== party.media_rev) return res.status(409).json({ error: 'Media revision is stale.', mediaRev: party.media_rev });
    const previous = room.playback;
    room.playback = { ...state, updatedAtMs: Date.now() };
    hub.send(me.party_id, 'playback', { playback: room.playback }, { except: me.id });
    const significant = !previous || previous.playing !== state.playing || previous.mediaRev !== state.mediaRev;
    if (significant || Date.now() - room.playbackPersistedAt > 10000) {
      room.playbackPersistedAt = Date.now();
      await pool.query('UPDATE millitop_tv.watch_parties SET playback = $2::jsonb, host_seen_at = now() WHERE id = $1', [me.party_id, JSON.stringify(room.playback)]);
    }
    res.json({ ok: true, serverTimeMs: Date.now() });
  }));

  app.post('/api/watch/invite', limits.invite, wrap(async (req, res) => {
    const me = await participantFromRequest(req, { hostOnly: true });
    const emails = v.emailList(req.body?.emails);
    const note = v.text(req.body?.note, 'Note', { max: 300, optional: true, multiline: true });
    const party = await loadParty(me.party_id);
    const results = await sendInvites(party, me, emails, note);
    res.json({ results, joinUrl: `${origin}/watch/${party.join_code}` });
  }));

  app.post('/api/watch/lock', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req, { hostOnly: true });
    await pool.query('UPDATE millitop_tv.watch_parties SET locked = $2, updated_at = now() WHERE id = $1', [me.party_id, req.body?.locked === true]);
    await broadcastState(me.party_id);
    res.json({ locked: req.body?.locked === true });
  }));

  app.post('/api/watch/remove', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req, { hostOnly: true });
    if (!v.isUuid(req.body?.participantId) || req.body.participantId === me.id) throw new WatchPartyError(400, 'Choose a guest to remove.');
    const r = await pool.query(
      `UPDATE millitop_tv.watch_party_participants SET removed_at = now() WHERE id = $1 AND party_id = $2 AND role = 'guest' AND removed_at IS NULL RETURNING display_name`,
      [req.body.participantId, me.party_id]);
    if (!r.rowCount) throw new WatchPartyError(404, 'That guest is not in the party.');
    invalidateRelay();
    hub.room(me.party_id).voice.delete(req.body.participantId);
    hub.send(me.party_id, 'removed', {}, { to: req.body.participantId });
    hub.send(me.party_id, 'signal', { from: req.body.participantId, kind: 'hangup', payload: {} });
    hub.close(me.party_id, req.body.participantId);
    await broadcastState(me.party_id);
    await event(me.party_id, me.id, 'party.removed', { participantId: req.body.participantId });
    res.json({ removed: true });
  }));

  app.post('/api/watch/end', limits.api, wrap(async (req, res) => {
    const me = await participantFromRequest(req, { hostOnly: true });
    await endParty(me.party_id, 'host-ended', me.id);
    res.json({ ended: true });
  }));

  // ---- Relay ---------------------------------------------------------------
  const relayRoute = wrap(async (req, res) => {
    try {
      await relay.handle(req, res);
    } catch (error) {
      if (res.headersSent) { res.destroy(); return; }
      if (error?.name === 'AbortError') { res.status(504).type('text/plain').send('The stream server took too long to answer.'); return; }
      if (error instanceof RelayError) { res.status(error.status).type('text/plain').send(error.message); return; }
      log.error(`Watch party relay failed: ${error?.name ?? 'Error'} ${error?.message ?? ''}`);
      res.status(502).type('text/plain').send('The stream could not be relayed.');
    }
  });
  app.get('/watch-relay/:relayKey/:mediaRev/main', relayRoute);
  app.get('/watch-relay/:relayKey/:mediaRev/s/:blob/:name', relayRoute);

  // ---- Admin (dashboard; /api/admin is already behind requireAdmin) --------
  app.get('/api/admin/watch-party/settings', wrap(async (req, res) => {
    const smtp = await settings.read('smtp');
    const voice = await settings.read('voice');
    const limitsValue = await settings.limits();
    res.json({
      smtp: smtp.value ? { ...smtp.value, hasPassword: Boolean(smtp.secret), passwordUnreadable: smtp.value.secretUnreadable === true } : null,
      voice: voice.value ? { turnUrls: voice.value.turnUrls ?? [], hasSecret: Boolean(voice.secret) } : { turnUrls: [], hasSecret: false },
      limits: limitsValue,
      publicOrigin: origin
    });
  }));

  app.put('/api/admin/watch-party/settings/smtp', wrap(async (req, res) => {
    const parsed = v.smtpSettings(req.body);
    const { password, ...value } = parsed;
    const clear = req.body?.clearPassword === true;
    await settings.write('smtp', value, clear ? null : password, req.admin?.id);
    await event(null, null, 'settings.smtp.updated', { by: req.admin?.email ?? null, host: value.host });
    res.json({ saved: true });
  }));

  app.put('/api/admin/watch-party/settings/voice', wrap(async (req, res) => {
    const parsed = v.voiceSettings(req.body);
    const { turnSecret, ...value } = parsed;
    await settings.write('voice', value, req.body?.clearSecret === true ? null : turnSecret, req.admin?.id);
    res.json({ saved: true });
  }));

  app.put('/api/admin/watch-party/settings/limits', wrap(async (req, res) => {
    await settings.write('limits', v.limitSettings(req.body), undefined, req.admin?.id);
    res.json({ saved: true });
  }));

  app.post('/api/admin/watch-party/settings/test-email', wrap(async (req, res) => {
    const to = v.email(req.body?.to);
    const verify = await mailer.verify();
    if (!verify.ok) return res.status(400).json({ error: verify.error });
    const outcome = await mailer.send({
      to,
      subject: 'MILLITOP TV watch party email test',
      text: 'Watch party invite email is working. Guests will receive links to ' + origin + '/watch/CODE.',
      html: `<p>Watch party invite email is working.</p><p>Guests will receive links to <strong>${origin}/watch/CODE</strong>.</p>`
    });
    if (!outcome.delivered) return res.status(400).json({ error: outcome.error });
    res.json({ delivered: true });
  }));

  app.get('/api/admin/watch-party/parties', wrap(async (req, res) => {
    const r = await pool.query(
      `SELECT w.id, w.title, w.join_code, w.created_at, w.host_seen_at, w.media->>'title' AS now_playing, w.media->>'kind' AS kind, h.name AS household,
         (SELECT count(*)::int FROM millitop_tv.watch_party_participants p WHERE p.party_id = w.id AND p.left_at IS NULL AND p.removed_at IS NULL) AS people
       FROM millitop_tv.watch_parties w JOIN millitop_tv.households h ON h.id = w.host_household_id
       WHERE w.status = 'active' ORDER BY w.created_at DESC LIMIT 100`);
    res.json({ parties: r.rows.map(row => ({ ...row, online: hub.parties.get(row.id)?.streams.size ?? 0 })), relay: relay.stats() });
  }));

  app.post('/api/admin/watch-party/parties/:id/end', wrap(async (req, res) => {
    if (!v.isUuid(req.params.id)) throw new WatchPartyError(400, 'Invalid party.');
    res.json({ ended: await endParty(req.params.id, 'admin-ended') });
  }));

  // ---- Browser join page ---------------------------------------------------
  const pageHeaders = res => {
    res.setHeader('Content-Security-Policy', [
      "default-src 'self'",
      "script-src 'self' https://www.youtube.com https://s.ytimg.com",
      "frame-src https://www.youtube.com https://www.youtube-nocookie.com",
      "img-src 'self' data: blob: https:",
      "media-src 'self' blob:",
      "connect-src 'self'",
      "worker-src 'self' blob:",
      "style-src 'self' 'unsafe-inline'",
      "object-src 'none'",
      "base-uri 'none'",
      "frame-ancestors 'none'"
    ].join('; '));
    // YouTube embeds require a referrer.
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    res.setHeader('Permissions-Policy', 'microphone=(self), camera=(), geolocation=()');
    res.setHeader('Cache-Control', 'no-store');
  };
  const page = async (req, res, next) => {
    try {
      const html = await readFile(join(WEB_DIR, 'index.html'), 'utf8');
      pageHeaders(res);
      res.type('html').send(html);
    } catch (error) { next(error); }
  };
  app.get('/watch', page);
  app.get('/watch/:code', page);
  app.get('/listen/:code', (req, res) => res.redirect(302, '/watch'));
  const ASSETS = new Map([
    ['watch.js', 'application/javascript'], ['watch.css', 'text/css'], ['voice.js', 'application/javascript'],
    ['hls.min.js', 'application/javascript'], ['mpegts.min.js', 'application/javascript'], ['icon.svg', 'image/svg+xml']
  ]);
  app.get('/watch-assets/:file', async (req, res, next) => {
    const type = ASSETS.get(req.params.file);
    if (!type) return res.status(404).end();
    try {
      const body = await readFile(join(WEB_DIR, req.params.file));
      res.setHeader('Content-Type', type);
      res.setHeader('Cache-Control', 'public, max-age=300');
      res.send(body);
    } catch (error) { next(error); }
  });

  // ---- Housekeeping --------------------------------------------------------
  async function sweep() {
    try {
      await ensureSchema();
      const stale = await pool.query(
        `SELECT id FROM millitop_tv.watch_parties WHERE status = 'active'
         AND (host_seen_at < now() - make_interval(mins => $1) OR created_at < now() - make_interval(hours => $2))`,
        [HOST_TIMEOUT_MINUTES, MAX_PARTY_HOURS]);
      for (const row of stale.rows) {
        if (hub.online(row.id, (await hostId(row.id)))) continue;
        await endParty(row.id, 'host-timeout');
      }
    } catch {
      // Schema missing or database unavailable; retry next interval.
    }
  }
  async function hostId(partyId) {
    const r = await pool.query("SELECT id FROM millitop_tv.watch_party_participants WHERE party_id = $1 AND role = 'host' LIMIT 1", [partyId]);
    return r.rows[0]?.id ?? null;
  }
  const timer = sweepIntervalMs > 0 ? setInterval(sweep, sweepIntervalMs) : null;
  timer?.unref?.();

  return {
    hub, relay, settings, sweep,
    stop() { if (timer) clearInterval(timer); for (const id of [...hub.parties.keys()]) hub.close(id); }
  };
}
