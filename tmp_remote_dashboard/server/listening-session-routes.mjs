import {createHash,randomUUID} from 'node:crypto';
import {
 uuid,joinCode,createBody,joinBody,messageBody,requestBody,resolveBody,playbackBody,signalBody,inviteBody,cursorId
} from './listening-session-validation.mjs';
import {sendInvite} from './listening-session-mailer.mjs';

const SKIP_VOTE_RATIO = 0.5; // Majority of active members requests a skip.
const PRESENCE_WINDOW = "interval '45 seconds'";

export function registerListeningSessionRoutes(app, pool, deviceLimit, { publicOrigin = null } = {}) {
 if (typeof deviceLimit !== 'function') throw new Error('Device limiter required.');
 const bad = (res, e) => res.status(400).json({ error: e.message });

 async function tx(req, res, next, work) {
  let c;
  try {
   c = await pool.connect();
   await c.query('BEGIN');
   await c.query("SET LOCAL statement_timeout='15s'");
   const authHeader = req.get('authorization') || '';
   const bearerPattern = new RegExp('^' + 'Bearer' + '\\s+(\\S+)$', 'i');
   const match = bearerPattern.exec(authHeader);
   if (!match) { await c.query('ROLLBACK'); return res.status(401).json({ error: 'Device authentication required.' }); }
   const r = await c.query(
    `SELECT d.id,d.household_id FROM millitop_tv.device_credentials k
     JOIN millitop_tv.devices d ON d.id=k.device_id JOIN millitop_tv.households h ON h.id=d.household_id
     WHERE k.token_hash=$1 AND k.revoked_at IS NULL AND (k.expires_at IS NULL OR k.expires_at>now())
     AND d.revoked_at IS NULL AND h.active FOR SHARE OF k,d,h`,
    [createHash('sha256').update(match[1]).digest('hex')]
   );
   if (!r.rowCount) { await c.query('ROLLBACK'); return res.status(401).json({ error: 'Device credential is invalid or revoked.' }); }
   const result = await work(c, r.rows[0]);
   await c.query('COMMIT');
   res.status(result.status ?? 200).json(result.body);
  } catch (e) {
   if (c) await c.query('ROLLBACK').catch(() => {});
   next(e);
  } finally {
   c?.release();
  }
 }

 const ok = body => ({ body });
 const event = (c, sessionId, deviceId, action, details = {}) =>
  c.query(
   'INSERT INTO millitop_tv.listening_session_events(id,session_id,device_id,action,details) VALUES($1,$2,$3,$4,$5::jsonb)',
   [randomUUID(), sessionId, deviceId, action, JSON.stringify(details)]
  );

 async function activeSession(c, sessionId, { forUpdate = false } = {}) {
  const r = await c.query(
   `SELECT * FROM millitop_tv.listening_sessions WHERE id=$1 AND status='active'${forUpdate ? ' FOR UPDATE' : ''}`,
   [sessionId]
  );
  return r.rows[0] ?? null;
 }

 async function requireMember(c, sessionId, deviceId) {
  const r = await c.query(
   'SELECT * FROM millitop_tv.listening_session_members WHERE session_id=$1 AND device_id=$2 AND left_at IS NULL',
   [sessionId, deviceId]
  );
  return r.rows[0] ?? null;
 }

 function sessionDto(s) {
  return {
   id: s.id, title: s.title, joinCode: s.join_code, status: s.status,
   nowPlaying: s.now_playing, nowPlayingToken: s.now_playing_token, revision: s.revision,
   hostDeviceId: s.host_device_id, createdAt: s.created_at, updatedAt: s.updated_at
  };
 }

 // --- Create -------------------------------------------------------------
 app.post('/api/device/listening-sessions/create', deviceLimit, (req, res, next) => {
  let b; try { b = createBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const id = randomUUID();
   const token = randomUUID().replace(/-/g, '').slice(0, 12);
   const nowPlaying = { ...b.nowPlaying, updatedAt: new Date().toISOString() };
   let code; let attempt = 0;
   let inserted = null;
   while (attempt < 5 && !inserted) {
    code = joinCode();
    try {
     inserted = (await c.query(
      `INSERT INTO millitop_tv.listening_sessions
        (id,host_household_id,host_device_id,host_profile_id,title,join_code,now_playing,now_playing_token)
       VALUES($1,$2,$3,$4,$5,$6,$7::jsonb,$8) RETURNING *`,
      [id, d.household_id, d.id, b.profileId, b.title, code, JSON.stringify(nowPlaying), token]
     )).rows[0];
    } catch (e) {
     if (e.code === '23505') { attempt += 1; continue; }
     throw e;
    }
   }
   if (!inserted) return { status: 503, body: { error: 'Could not allocate a join code. Try again.' } };
   await c.query(
    `INSERT INTO millitop_tv.listening_session_members(session_id,device_id,profile_id,display_name,role)
     VALUES($1,$2,$3,$4,'host')`,
    [id, d.id, b.profileId, b.displayName]
   );
   await event(c, id, d.id, 'session.created');
   return { status: 201, body: { session: sessionDto(inserted) } };
  });
 });

 // --- Join -----------------------------------------------------------------
 app.post('/api/device/listening-sessions/join', deviceLimit, (req, res, next) => {
  let b; try { b = joinBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const s = await c.query(
    "SELECT * FROM millitop_tv.listening_sessions WHERE join_code=$1 AND status='active' FOR UPDATE",
    [b.joinCode]
   );
   if (!s.rowCount) return { status: 404, body: { error: 'Session not found or has ended.' } };
   const session = s.rows[0];
   await c.query(
    `INSERT INTO millitop_tv.listening_session_members(session_id,device_id,profile_id,display_name,role)
     VALUES($1,$2,$3,$4,'guest')
     ON CONFLICT(session_id,device_id) DO UPDATE SET left_at=NULL,display_name=EXCLUDED.display_name,last_seen_at=now()`,
    [session.id, d.id, b.profileId, b.displayName]
   );
   await c.query(
    `INSERT INTO millitop_tv.listening_session_signals(session_id,from_device_id,to_device_id,kind,payload)
     VALUES($1,$2,NULL,'join-announce',$3::jsonb)`,
    [session.id, d.id, JSON.stringify({ displayName: b.displayName })]
   );
   await event(c, session.id, d.id, 'session.joined');
   return { body: { session: sessionDto(session) } };
  });
 });

 // --- Leave ------------------------------------------------------------------
 app.post('/api/device/listening-sessions/leave', deviceLimit, (req, res, next) => {
  if (!uuid(req.body?.sessionId)) return bad(res, new Error('Invalid session.'));
  return tx(req, res, next, async (c, d) => {
   const r = await c.query(
    'UPDATE millitop_tv.listening_session_members SET left_at=now() WHERE session_id=$1 AND device_id=$2 AND left_at IS NULL RETURNING role',
    [req.body.sessionId, d.id]
   );
   if (!r.rowCount) return ok({ accepted: true });
   await c.query(
    `INSERT INTO millitop_tv.listening_session_signals(session_id,from_device_id,to_device_id,kind,payload)
     VALUES($1,$2,NULL,'leave','{}'::jsonb)`,
    [req.body.sessionId, d.id]
   );
   if (r.rows[0].role === 'host') {
    await c.query(
     "UPDATE millitop_tv.listening_sessions SET status='ended',ended_at=now(),revision=revision+1 WHERE id=$1 AND status='active'",
     [req.body.sessionId]
    );
   }
   await event(c, req.body.sessionId, d.id, 'session.left');
   return ok({ accepted: true });
  });
 });

 // --- Combined poll: session state + chat + requests + signals since cursor
 app.post('/api/device/listening-sessions/state', deviceLimit, (req, res, next) => {
  if (!uuid(req.body?.sessionId)) return bad(res, new Error('Invalid session.'));
  let messagesAfter, requestsAfter, signalsAfter;
  try {
   messagesAfter = req.body.messagesAfter ?? null;
   requestsAfter = req.body.requestsAfter ?? null;
   signalsAfter = cursorId(req.body.signalsAfter);
  } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, req.body.sessionId);
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   const member = await requireMember(c, session.id, d.id);
   if (!member) return { status: 403, body: { error: 'Join this session before viewing it.' } };
   await c.query(
    'UPDATE millitop_tv.listening_session_members SET last_seen_at=now() WHERE session_id=$1 AND device_id=$2',
    [session.id, d.id]
   );
   const members = (await c.query(
    `SELECT device_id AS "deviceId",profile_id AS "profileId",display_name AS "displayName",role,
      last_seen_at > now() - ${PRESENCE_WINDOW} AS online
     FROM millitop_tv.listening_session_members WHERE session_id=$1 AND left_at IS NULL ORDER BY joined_at`,
    [session.id]
   )).rows;
   const messages = (await c.query(
    `SELECT id,display_name AS "displayName",body,created_at AS "createdAt" FROM millitop_tv.listening_session_messages
     WHERE session_id=$1 AND ($2::timestamptz IS NULL OR created_at>$2::timestamptz) ORDER BY created_at,id LIMIT 200`,
    [session.id, messagesAfter]
   )).rows;
   const requests = (await c.query(
    `SELECT id,display_name AS "displayName",track_ref AS "track",status,created_at AS "createdAt"
     FROM millitop_tv.listening_session_song_requests
     WHERE session_id=$1 AND ($2::timestamptz IS NULL OR created_at>$2::timestamptz) ORDER BY created_at,id LIMIT 200`,
    [session.id, requestsAfter]
   )).rows;
   const signals = (await c.query(
    `SELECT id,from_device_id AS "fromDeviceId",kind,payload FROM millitop_tv.listening_session_signals
     WHERE session_id=$1 AND id>$2 AND (to_device_id IS NULL OR to_device_id=$3) AND from_device_id<>$3
     ORDER BY id LIMIT 200`,
    [session.id, signalsAfter, d.id]
   )).rows;
   const activeCount = members.length;
   const votes = (await c.query(
    'SELECT count(*)::int AS total FROM millitop_tv.listening_session_skip_votes WHERE session_id=$1 AND now_playing_token=$2',
    [session.id, session.now_playing_token]
   )).rows[0].total;
   return ok({
    session: sessionDto(session), members, messages, requests, signals,
    messagesCursor: messages.length ? messages.at(-1).createdAt : messagesAfter,
    requestsCursor: requests.length ? requests.at(-1).createdAt : requestsAfter,
    signalsCursor: signals.length ? signals.at(-1).id : signalsAfter,
    skipVotes: votes, skipNeeded: Math.max(1, Math.ceil(activeCount * SKIP_VOTE_RATIO)), activeMembers: activeCount
   });
  });
 });

 // --- Chat --------------------------------------------------------------
 app.post('/api/device/listening-sessions/messages', deviceLimit, (req, res, next) => {
  let b; try { b = messageBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, b.sessionId);
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   const member = await requireMember(c, session.id, d.id);
   if (!member) return { status: 403, body: { error: 'Join this session before chatting.' } };
   const id = randomUUID();
   await c.query(
    'INSERT INTO millitop_tv.listening_session_messages(id,session_id,device_id,display_name,body) VALUES($1,$2,$3,$4,$5)',
    [id, session.id, d.id, member.display_name, b.body]
   );
   return { status: 201, body: { accepted: true, id } };
  });
 });

 // --- Song requests ---------------------------------------------------------
 app.post('/api/device/listening-sessions/song-requests', deviceLimit, (req, res, next) => {
  let b; try { b = requestBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, b.sessionId);
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   const member = await requireMember(c, session.id, d.id);
   if (!member) return { status: 403, body: { error: 'Join this session before requesting songs.' } };
   const pending = await c.query(
    "SELECT count(*)::int AS total FROM millitop_tv.listening_session_song_requests WHERE session_id=$1 AND status='pending'",
    [session.id]
   );
   if (pending.rows[0].total >= 100) return { status: 409, body: { error: 'Too many pending requests. Wait for the host to review them.' } };
   const id = randomUUID();
   await c.query(
    'INSERT INTO millitop_tv.listening_session_song_requests(id,session_id,device_id,display_name,track_ref) VALUES($1,$2,$3,$4,$5::jsonb)',
    [id, session.id, d.id, member.display_name, JSON.stringify(b.track)]
   );
   return { status: 201, body: { accepted: true, id } };
  });
 });

 app.post('/api/device/listening-sessions/song-requests/resolve', deviceLimit, (req, res, next) => {
  let b; try { b = resolveBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, b.sessionId, { forUpdate: true });
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   if (session.host_device_id !== d.id) return { status: 403, body: { error: 'Only the host can resolve requests.' } };
   const status = b.action === 'approve' ? 'queued' : 'rejected';
   const r = await c.query(
    "UPDATE millitop_tv.listening_session_song_requests SET status=$3,resolved_at=now() WHERE id=$1 AND session_id=$2 AND status='pending' RETURNING id",
    [b.requestId, b.sessionId, status]
   );
   if (!r.rowCount) return { status: 409, body: { error: 'Request already resolved.' } };
   return ok({ accepted: true });
  });
 });

 // --- Playback / skip votes ---------------------------------------------
 app.post('/api/device/listening-sessions/playback', deviceLimit, (req, res, next) => {
  let b; try { b = playbackBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, b.sessionId, { forUpdate: true });
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   if (session.host_device_id !== d.id) return { status: 403, body: { error: 'Only the host controls playback.' } };
   const nowPlaying = { ...b.nowPlaying, updatedAt: new Date().toISOString() };
   const token = b.advance ? randomUUID() : session.now_playing_token;
   const updated = (await c.query(
    `UPDATE millitop_tv.listening_sessions SET now_playing=$2::jsonb,now_playing_token=$3,revision=revision+1,updated_at=now()
     WHERE id=$1 RETURNING *`,
    [session.id, JSON.stringify(nowPlaying), token]
   )).rows[0];
   return ok({ session: sessionDto(updated) });
  });
 });

 app.post('/api/device/listening-sessions/skip-vote', deviceLimit, (req, res, next) => {
  if (!uuid(req.body?.sessionId)) return bad(res, new Error('Invalid session.'));
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, req.body.sessionId);
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   const member = await requireMember(c, session.id, d.id);
   if (!member) return { status: 403, body: { error: 'Join this session before voting.' } };
   await c.query(
    `INSERT INTO millitop_tv.listening_session_skip_votes(session_id,now_playing_token,device_id)
     VALUES($1,$2,$3) ON CONFLICT DO NOTHING`,
    [session.id, session.now_playing_token, d.id]
   );
   const activeCount = (await c.query(
    'SELECT count(*)::int AS total FROM millitop_tv.listening_session_members WHERE session_id=$1 AND left_at IS NULL',
    [session.id]
   )).rows[0].total;
   const votes = (await c.query(
    'SELECT count(*)::int AS total FROM millitop_tv.listening_session_skip_votes WHERE session_id=$1 AND now_playing_token=$2',
    [session.id, session.now_playing_token]
   )).rows[0].total;
   const needed = Math.max(1, Math.ceil(activeCount * SKIP_VOTE_RATIO));
   return ok({ accepted: true, skipVotes: votes, skipNeeded: needed, skipReached: votes >= needed });
  });
 });

 // --- WebRTC signaling relay (for voice chat) ----------------------------
 app.post('/api/device/listening-sessions/signal', deviceLimit, (req, res, next) => {
  let b; try { b = signalBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, b.sessionId);
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   const member = await requireMember(c, session.id, d.id);
   if (!member) return { status: 403, body: { error: 'Join this session before signaling.' } };
   await c.query(
    `INSERT INTO millitop_tv.listening_session_signals(session_id,from_device_id,to_device_id,kind,payload)
     VALUES($1,$2,$3,$4,$5::jsonb)`,
    [session.id, d.id, b.toDeviceId, b.kind, JSON.stringify(b.payload)]
   );
   return { status: 201, body: { accepted: true } };
  });
 });

 // --- Email invites (Microsoft Graph wiring pending) ------------------------
 app.post('/api/device/listening-sessions/invite', deviceLimit, (req, res, next) => {
  let b; try { b = inviteBody(req.body); } catch (e) { return bad(res, e); }
  return tx(req, res, next, async (c, d) => {
   const session = await activeSession(c, b.sessionId);
   if (!session) return { status: 404, body: { error: 'Session not found or has ended.' } };
   const member = await requireMember(c, session.id, d.id);
   if (!member) return { status: 403, body: { error: 'Join this session before inviting others.' } };
   const id = randomUUID();
   const token = randomUUID().replace(/-/g, '');
   await c.query(
    'INSERT INTO millitop_tv.listening_session_invites(id,session_id,invited_by_device_id,email,token) VALUES($1,$2,$3,$4,$5)',
    [id, session.id, d.id, b.email, token]
   );
   const joinUrl = `${publicOrigin ?? 'https://tvadmin.millitop.net'}/listen/${session.join_code}`;
   const result = await sendInvite({ email: b.email, sessionTitle: session.title, joinUrl });
   await c.query(
    "UPDATE millitop_tv.listening_session_invites SET status=$2,sent_at=CASE WHEN $2='sent' THEN now() ELSE NULL END WHERE id=$1",
    [id, result.delivered ? 'sent' : 'pending']
   );
   return {
    status: 201,
    body: {
     accepted: true, id, joinCode: session.join_code, joinUrl,
     emailDelivered: result.delivered,
     note: result.delivered ? null : 'Email delivery is not wired up yet (Microsoft Graph tenant pending). Share the join code or link directly for now.'
    }
   };
  });
 });

 // --- Resume: sessions this device currently belongs to -------------------
 app.post('/api/device/listening-sessions/mine', deviceLimit, (req, res, next) => {
  return tx(req, res, next, async (c, d) => {
   const rows = (await c.query(
    `SELECT s.* FROM millitop_tv.listening_sessions s
     JOIN millitop_tv.listening_session_members m ON m.session_id=s.id
     WHERE m.device_id=$1 AND m.left_at IS NULL AND s.status='active' ORDER BY s.created_at DESC LIMIT 20`,
    [d.id]
   )).rows;
   return ok({ sessions: rows.map(sessionDto) });
  });
 });
}
