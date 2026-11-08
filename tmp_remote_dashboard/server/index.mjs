import {registerProfileSyncRoutes} from './profile-sync-routes.mjs';
import {TmdbDiscovery,registerTmdbDiscoveryRoutes} from './tmdb-discovery.mjs';
import {registerCommunityRoutes} from './community-routes.mjs';
import { registerBillingRoutes, billingRateKey } from './billing-routes.mjs';
import { registerWebAppRoutes } from './web-app-routes.mjs';
import { registerUpdateRoutes } from './update-routes.mjs';
import { registerMessageRoutes } from './message-routes.mjs';
import { registerDeviceRoutes } from './device-routes.mjs';
import { registerLiveTvRoutes } from './live-tv-routes.mjs';
import { registerMediaLibraryRoutes } from './media-library-routes.mjs';
import { registerListeningSessionRoutes } from './listening-session-routes.mjs';
import { registerDvrRoutes } from './dvr-routes.mjs';
import { DvrRecorder, DvrSigner } from './dvr-recorder.mjs';
import { PgDvrStore } from './dvr-store.mjs';
import { registerTelemetryRoutes } from './telemetry-routes.mjs';
import { PgTelemetryStore } from './telemetry-store.mjs';
import express from 'express';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import { Pool } from 'pg';
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing configuration: ${name}`);
  return value;
}

function secret(name) {
  const value = readFileSync(`/run/secrets/${name}`, 'utf8').trim();
  if (!value) throw new Error(`Empty secret: ${name}`);
  return value;
}

const supabaseUrl = required('SUPABASE_URL');
const publicKey = secret('supabase_public_key');

function authClient() {
  return createClient(supabaseUrl, publicKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false
    }
  });
}

// This client is used only for token validation, never sign-in.
const verifier = authClient();

const pool = new Pool({
  host: required('DB_HOST'),
  port: Number(required('DB_PORT')),
  database: required('DB_NAME'),
  user: required('DB_USER'),
  password: secret('db_password'),
  max: 5,
  connectionTimeoutMillis: 10000,
  idleTimeoutMillis: 30000,
  ssl: false
});

pool.on('error', () => {
  console.error('Idle database connection error.');
});

const allowedOrigins = new Set(
  required('ALLOWED_ORIGINS').split(',').map(value => value.trim())
);

const app = express();
app.disable('x-powered-by');

// Do not trust arbitrary forwarded headers.
// Reverse-proxy trust will be configured when NPM is connected.
app.set('trust proxy', 1);

app.use(helmet({
  strictTransportSecurity: false,
  contentSecurityPolicy: {
    directives: {
      upgradeInsecureRequests: null
    }
  }
}));

app.use('/api/admin/content/articles', express.json({ limit: '256kb' }));
app.use('/api/device/profile-sync/push', express.json({ limit: '1mb' }));
app.use('/api/device/live-tv/config', express.json({ limit: '1mb' }));
app.use('/api/device/household/profiles', express.json({ limit: '64mb' }));
app.use('/api/device/telemetry', express.json({ limit: '1mb' }));
app.use(express.json({ limit: '32kb' }));

app.use('/api', (req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');

  const origin = req.get('origin');

  if (origin && !allowedOrigins.has(origin)) {
    return res.status(403).json({ error: 'Origin not permitted.' });
  }

  next();
});

const loginLimit = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 20,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: 'Too many sign-in attempts. Try again later.' }
});

const adminLimit = rateLimit({
  windowMs: 60 * 1000,
  limit: 120,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: 'Too many requests. Try again shortly.' }
});

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', application: 'Millitop TV Dashboard' });
});

app.post('/api/login', loginLimit, async (req, res, next) => {
  try {
    const { email, password } = req.body ?? {};

    if (
      typeof email !== 'string' ||
      typeof password !== 'string' ||
      !email.trim() ||
      email.length > 320 ||
      !password ||
      password.length > 4096
    ) {
      return res.status(400).json({ error: 'Enter your email and password.' });
    }

    // Separate client per sign-in: no shared mutable user session.
    const client = authClient();

    const { data, error } = await client.auth.signInWithPassword({
      email: email.trim(),
      password
    });

    if (error || !data.user || !data.session) {
      console.warn('Supabase sign-in rejected:', JSON.stringify({
        status: error?.status ?? null,
        code: error?.code ?? null,
        type: error?.name ?? null,
        hasUser: Boolean(data?.user),
        hasSession: Boolean(data?.session)
      }));

      return res.status(401).json({ error: 'Sign-in failed.' });
    }

    const membership = await pool.query(
      `SELECT role
       FROM millitop_tv.admin_members
       WHERE user_id = $1 AND active = true`,
      [data.user.id]
    );

    if (!membership.rowCount) {
      return res.status(403).json({
        error: 'This account is not authorized for the dashboard.'
      });
    }

    // Return no refresh token. This first slice keeps the access token
    // only in browser memory; refresh/reopen requires sign-in.
    res.json({
      accessToken: data.session.access_token,
      expiresAt: data.session.expires_at
    });
  } catch (error) {
    next(error);
  }
});

async function requireAdmin(req, res, next) {
  try {
    const header = req.get('authorization') ?? '';
    const match = /^Bearer ([^\s]+)$/.exec(header);

    if (!match || match[1].length > 16000) {
      return res.status(401).json({ error: 'Sign in to continue.' });
    }

    const { data, error } = await verifier.auth.getUser(match[1]);

    if (error || !data.user) {
      return res.status(401).json({ error: 'Your session has expired.' });
    }

    const membership = await pool.query(
      `SELECT role
       FROM millitop_tv.admin_members
       WHERE user_id = $1 AND active = true`,
      [data.user.id]
    );

    if (!membership.rowCount) {
      return res.status(403).json({ error: 'Dashboard access is not permitted.' });
    }

    req.admin = {
      id: data.user.id,
      email: data.user.email,
      role: membership.rows[0].role
    };

    next();
  } catch (error) {
    next(error);
  }
}

app.use('/api/admin', adminLimit, requireAdmin);

app.get('/api/admin/overview', async (req, res, next) => {
  try {
    const result = await pool.query(`
      SELECT
        (SELECT count(*)::int
         FROM millitop_tv.households WHERE active) AS households,
        (SELECT count(*)::int
         FROM millitop_tv.devices WHERE revoked_at IS NULL) AS devices,
        (SELECT count(*)::int
         FROM millitop_tv.devices
         WHERE revoked_at IS NULL
           AND last_seen_at > now() - interval '90 seconds') AS online,
        (SELECT count(*)::int
         FROM millitop_tv.messages WHERE archived_at IS NULL) AS messages,
        (SELECT max(version)
         FROM millitop_tv.schema_migrations) AS schema_version
    `);

    res.json({ admin: req.admin, ...result.rows[0] });
  } catch (error) {
    next(error);
  }
});

app.get('/api/admin/households', async (req, res, next) => {
  try {
    const result = await pool.query(`
      SELECT h.id, h.name, h.created_at,
        count(d.id) FILTER (WHERE d.revoked_at IS NULL)::int AS devices
      FROM millitop_tv.households h
      LEFT JOIN millitop_tv.devices d ON d.household_id = h.id
      WHERE h.active = true
      GROUP BY h.id
      ORDER BY h.created_at DESC
    `);

    res.json(result.rows);
  } catch (error) {
    next(error);
  }
});

app.post('/api/admin/households', async (req, res, next) => {
  const name = req.body?.name;

  if (
    typeof name !== 'string' ||
    !name.trim() ||
    name.trim().length > 120
  ) {
    return res.status(400).json({
      error: 'Household name must contain 1–120 characters.'
    });
  }

  let connection;

  try {
    connection = await pool.connect();
    await connection.query('BEGIN');

    const result = await connection.query(
      `INSERT INTO millitop_tv.households (name, created_by)
       VALUES ($1, $2)
       RETURNING id, name, created_at`,
      [name.trim(), req.admin.id]
    );

    await connection.query(
      `INSERT INTO millitop_tv.audit_log
       (actor_user_id, action, entity_type, entity_id)
       VALUES ($1, 'household.created', 'household', $2)`,
      [req.admin.id, result.rows[0].id]
    );

    await connection.query('COMMIT');
    res.status(201).json(result.rows[0]);
  } catch (error) {
    if (connection) {
      await connection.query('ROLLBACK').catch(() => {});
    }
    next(error);
  } finally {
    connection?.release();
  }
});

registerDeviceRoutes(app, pool);
registerLiveTvRoutes(
  app,
  pool,
  rateLimit({
    windowMs: 60000,
    limit: 120,
    standardHeaders: 'draft-8',
    legacyHeaders: false
  })
);
registerMediaLibraryRoutes(
  app,
  pool,
  rateLimit({
    windowMs: 60000,
    limit: 120,
    standardHeaders: 'draft-8',
    legacyHeaders: false
  })
);
registerTelemetryRoutes(app, {
  store: new PgTelemetryStore(pool),
  deviceLimit: rateLimit({
    windowMs: 60000,
    limit: 30,
    standardHeaders: 'draft-8',
    legacyHeaders: false
  }),
  options: { retentionDays: Number(process.env.TELEMETRY_RETENTION_DAYS ?? 90) }
});
const dvr = registerDvrRoutes(app, {
  store: new PgDvrStore(pool),
  recorder: new DvrRecorder({
    storageDir: process.env.DVR_STORAGE_DIR ?? '/recordings',
    ffmpegPath: process.env.DVR_FFMPEG_PATH ?? 'ffmpeg',
    minFreeBytes: Number(process.env.DVR_MIN_FREE_GB ?? 5) * 1024 * 1024 * 1024
  }),
  signer: new DvrSigner(process.env.DVR_SIGNING_SECRET),
  deviceLimit: rateLimit({
    windowMs: 60000,
    limit: 120,
    standardHeaders: 'draft-8',
    legacyHeaders: false
  }),
  options: {
    maxConcurrent: Number(process.env.DVR_MAX_CONCURRENT ?? 4),
    maxRecordingHours: Number(process.env.DVR_MAX_RECORDING_HOURS ?? 4)
  }
});
registerProfileSyncRoutes(app,pool,rateLimit({windowMs:60000,limit:90,keyGenerator:billingRateKey,standardHeaders:'draft-8',legacyHeaders:false}));
const tmdbDiscovery=new TmdbDiscovery();tmdbDiscovery.start();
registerCommunityRoutes(app,pool,rateLimit({windowMs:60000,limit:60,standardHeaders:'draft-8',legacyHeaders:false}),{discovery:tmdbDiscovery});
registerTmdbDiscoveryRoutes(app,tmdbDiscovery);

registerMessageRoutes(app, pool);
registerUpdateRoutes(app, pool);
registerListeningSessionRoutes(
  app,
  pool,
  rateLimit({
    windowMs: 60000,
    limit: 120,
    standardHeaders: 'draft-8',
    legacyHeaders: false
  }),
  { publicOrigin: process.env.PUBLIC_ORIGIN ?? null }
);
registerBillingRoutes(app, pool, {device:rateLimit({windowMs:60000,limit:120,standardHeaders:'draft-8',legacyHeaders:false}),unlock:rateLimit({windowMs:900000,limit:10,keyGenerator:billingRateKey,standardHeaders:'draft-8',legacyHeaders:false})});
registerWebAppRoutes(app, pool, rateLimit({windowMs:60000,limit:120,standardHeaders:'draft-8',legacyHeaders:false}));

app.use('/downloads', express.static('/releases', {index:false, dotfiles:'deny', redirect:false, maxAge:'1y', immutable:true}));

app.use('/api', (req, res) => {
  res.status(404).json({ error: 'API route not found.' });
});

app.use(express.static(resolve('dist'), {
  index: 'index.html',
  maxAge: 0
}));

app.use((error, req, res, next) => {
  const reference = randomUUID();
  const message = String(error?.message ?? 'Unknown error');
  const code = String(error?.code ?? '');
  const stackTop = String(error?.stack ?? '').split('\n').slice(0, 2).join(' | ');

  // Never log request bodies, credentials, or Authorization headers.
  console.error(
    `Request failed: ${reference}; ${req.method} ${req.originalUrl}; ${error?.name ?? 'Error'}; code=${code}; message=${message}; stack=${stackTop}`
  );

  if (!res.headersSent) {
    res.status(500).json({
      error: 'The request could not be completed.',
      reference
    });
  }
});

const server = app.listen(3000, '0.0.0.0', () => {
  console.log('Millitop TV Dashboard listening on port 3000.');
});

async function shutdown() {
  tmdbDiscovery.stop();
  // Finalize in-progress recordings before the database pool closes.
  await dvr.shutdown().catch(() => {});
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });

  setTimeout(() => process.exit(1), 10000).unref();
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
