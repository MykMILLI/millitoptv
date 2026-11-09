import React, { useEffect, useState } from 'react';

const emptySmtp = {
  enabled: true,
  host: '',
  port: 587,
  security: 'starttls',
  username: '',
  password: '',
  fromEmail: '',
  fromName: 'MILLITOP TV',
  replyTo: '',
};

const securityPorts = { ssl: 465, starttls: 587, none: 25 };

function when(value) {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString();
}

export default function WatchPartyPanel({ request }) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [publicOrigin, setPublicOrigin] = useState('');
  const [smtp, setSmtp] = useState(emptySmtp);
  const [hasPassword, setHasPassword] = useState(false);
  const [passwordUnreadable, setPasswordUnreadable] = useState(false);
  const [clearPassword, setClearPassword] = useState(false);
  const [testTo, setTestTo] = useState('');
  const [voice, setVoice] = useState({ turnUrls: '', turnSecret: '' });
  const [hasTurnSecret, setHasTurnSecret] = useState(false);
  const [limits, setLimits] = useState({ maxParticipants: 12, allowPublicJoin: true });
  const [parties, setParties] = useState([]);
  const [busy, setBusy] = useState('');

  async function load() {
    setError('');
    const [settings, active] = await Promise.all([
      request('/api/admin/watch-party/settings'),
      request('/api/admin/watch-party/parties'),
    ]);
    setPublicOrigin(settings.publicOrigin ?? '');
    if (settings.smtp) {
      setSmtp({
        ...emptySmtp,
        ...settings.smtp,
        username: settings.smtp.username ?? '',
        replyTo: settings.smtp.replyTo ?? '',
        password: '',
      });
      setHasPassword(Boolean(settings.smtp.hasPassword));
      setPasswordUnreadable(Boolean(settings.smtp.passwordUnreadable));
    }
    setClearPassword(false);
    setVoice({ turnUrls: (settings.voice?.turnUrls ?? []).join('\n'), turnSecret: '' });
    setHasTurnSecret(Boolean(settings.voice?.hasSecret));
    setLimits(settings.limits ?? { maxParticipants: 12, allowPublicJoin: true });
    setParties(active.parties ?? []);
  }

  useEffect(() => {
    load().catch(e => setError(e.message)).finally(() => setLoading(false));
  }, []);

  async function run(label, action, success) {
    setBusy(label);
    setError('');
    setNotice('');
    try {
      await action();
      if (success) setNotice(success);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy('');
    }
  }

  const updateSmtp = (field, value) => setSmtp(current => ({ ...current, [field]: value }));

  function saveSmtp(event) {
    event.preventDefault();
    run('smtp', async () => {
      const body = {
        ...smtp,
        port: Number(smtp.port),
        username: smtp.username.trim() || null,
        replyTo: smtp.replyTo.trim() || null,
        password: smtp.password || undefined,
        clearPassword,
      };
      await request('/api/admin/watch-party/settings/smtp', { method: 'PUT', body: JSON.stringify(body) });
      await load();
    }, 'Email settings saved.');
  }

  function sendTest(event) {
    event.preventDefault();
    run('test', async () => {
      await request('/api/admin/watch-party/settings/test-email', { method: 'POST', body: JSON.stringify({ to: testTo.trim() }) });
    }, `Test email sent to ${testTo.trim()}. Check the inbox (and junk folder).`);
  }

  function saveVoice(event) {
    event.preventDefault();
    run('voice', async () => {
      await request('/api/admin/watch-party/settings/voice', {
        method: 'PUT',
        body: JSON.stringify({ turnUrls: voice.turnUrls, turnSecret: voice.turnSecret || undefined }),
      });
      await load();
    }, 'Voice settings saved.');
  }

  function saveLimits(event) {
    event.preventDefault();
    run('limits', async () => {
      await request('/api/admin/watch-party/settings/limits', {
        method: 'PUT',
        body: JSON.stringify({ maxParticipants: Number(limits.maxParticipants), allowPublicJoin: limits.allowPublicJoin }),
      });
      await load();
    }, 'Party limits saved.');
  }

  function endParty(party) {
    if (!window.confirm(`End "${party.title}" for everyone?`)) return;
    run(`end-${party.id}`, async () => {
      await request(`/api/admin/watch-party/parties/${party.id}/end`, { method: 'POST', body: '{}' });
      await load();
    }, 'Party ended.');
  }

  if (loading) return <section className="panel"><h2>Watch parties</h2><p>Loading…</p></section>;

  return (
    <div className="page-stack">
      {error && <div className="error" role="alert">{error}</div>}
      {notice && <div className="success" role="status" style={{ padding: 16, borderRadius: 10, background: '#1f4d36', margin: '18px 0' }}>{notice}</div>}

      <section className="panel">
        <h2>Active watch parties</h2>
        <p>
          Guests join at <strong>{publicOrigin || 'this site'}/watch/CODE</strong>. Parties end automatically when the host
          has been gone for 10 minutes, or after 18 hours.
        </p>
        <button type="button" className="secondary" onClick={() => run('refresh', load)} disabled={busy === 'refresh'}>Refresh list</button>
        {parties.length === 0 ? <p>No parties are running right now.</p> : (
          <div className="device-list">
            {parties.map(party => (
              <article className="device-card" key={party.id}>
                <div>
                  <h3>{party.title}</h3>
                  <p>{party.household} · code <strong>{party.join_code}</strong> · {party.people} {party.people === 1 ? 'person' : 'people'} ({party.online} connected)</p>
                  <p>{party.now_playing ? `Playing: ${party.now_playing}` : 'Nothing playing yet'} · started {when(party.created_at)} · host seen {when(party.host_seen_at)}</p>
                </div>
                <button type="button" className="secondary" disabled={busy === `end-${party.id}`} onClick={() => endParty(party)}>End party</button>
              </article>
            ))}
          </div>
        )}
      </section>

      <section className="panel">
        <h2>Invite email (SMTP)</h2>
        <p>Used for watch party invitations. The password is encrypted on the server and never shown again.</p>
        <form className="pairing-form" onSubmit={saveSmtp}>
          <label>
            <input type="checkbox" checked={smtp.enabled} onChange={e => updateSmtp('enabled', e.target.checked)} /> Send invite emails
          </label>
          <label>
            SMTP server
            <input value={smtp.host} onChange={e => updateSmtp('host', e.target.value)} placeholder="smtp.zoho.com" required />
          </label>
          <label>
            Security
            <select
              value={smtp.security}
              onChange={e => setSmtp(current => ({
                ...current,
                security: e.target.value,
                port: Object.values(securityPorts).includes(Number(current.port)) ? securityPorts[e.target.value] : current.port,
              }))}
            >
              <option value="starttls">STARTTLS (usually port 587)</option>
              <option value="ssl">SSL/TLS (usually port 465)</option>
              <option value="none">None (local relay only)</option>
            </select>
          </label>
          <label>
            Port
            <input type="number" min="1" max="65535" value={smtp.port} onChange={e => updateSmtp('port', e.target.value)} required />
          </label>
          <label>
            Username
            <input value={smtp.username} onChange={e => updateSmtp('username', e.target.value)} autoComplete="off" placeholder="tv@millitop.net" />
          </label>
          <label>
            Password {hasPassword && !clearPassword ? '(saved — leave blank to keep)' : ''}
            <input type="password" value={smtp.password} onChange={e => updateSmtp('password', e.target.value)} autoComplete="new-password" placeholder={hasPassword ? '••••••••' : 'App password'} />
          </label>
          {passwordUnreadable && <p className="error">The saved password can no longer be decrypted (server secret changed). Enter it again.</p>}
          {hasPassword && (
            <label>
              <input type="checkbox" checked={clearPassword} onChange={e => setClearPassword(e.target.checked)} /> Remove saved password
            </label>
          )}
          <label>
            From email
            <input type="email" value={smtp.fromEmail} onChange={e => updateSmtp('fromEmail', e.target.value)} placeholder="tv@millitop.net" required />
          </label>
          <label>
            From name
            <input value={smtp.fromName} onChange={e => updateSmtp('fromName', e.target.value)} />
          </label>
          <label>
            Reply-to (optional)
            <input type="email" value={smtp.replyTo} onChange={e => updateSmtp('replyTo', e.target.value)} />
          </label>
          <button type="submit" disabled={busy === 'smtp'}>{busy === 'smtp' ? 'Saving…' : 'Save email settings'}</button>
        </form>
        <form className="pairing-form" onSubmit={sendTest}>
          <label>
            Send a test email to
            <input type="email" value={testTo} onChange={e => setTestTo(e.target.value)} required placeholder="you@example.com" />
          </label>
          <button type="submit" className="secondary" disabled={busy === 'test'}>{busy === 'test' ? 'Sending…' : 'Send test email'}</button>
        </form>
      </section>

      <section className="panel">
        <h2>Voice chat</h2>
        <p>
          Voice works peer-to-peer. Public STUN is always used. For guests on strict mobile or corporate networks, add a TURN
          server (coturn with <code>use-auth-secret</code>).
        </p>
        <form className="pairing-form" onSubmit={saveVoice}>
          <label>
            TURN URLs (one per line)
            <textarea rows={3} value={voice.turnUrls} onChange={e => setVoice(v => ({ ...v, turnUrls: e.target.value }))} placeholder={'turn:turn.millitop.net:3478?transport=udp\nturns:turn.millitop.net:5349?transport=tcp'} />
          </label>
          <label>
            TURN shared secret {hasTurnSecret ? '(saved — leave blank to keep)' : ''}
            <input type="password" value={voice.turnSecret} onChange={e => setVoice(v => ({ ...v, turnSecret: e.target.value }))} autoComplete="new-password" />
          </label>
          <button type="submit" disabled={busy === 'voice'}>Save voice settings</button>
        </form>
      </section>

      <section className="panel">
        <h2>Limits</h2>
        <form className="pairing-form" onSubmit={saveLimits}>
          <label>
            Maximum people per party (including host)
            <input type="number" min="2" max="50" value={limits.maxParticipants} onChange={e => setLimits(l => ({ ...l, maxParticipants: e.target.value }))} />
          </label>
          <label>
            <input type="checkbox" checked={limits.allowPublicJoin} onChange={e => setLimits(l => ({ ...l, allowPublicJoin: e.target.checked }))} /> Anyone with the link or code can join (turn off to require email invites)
          </label>
          <button type="submit" disabled={busy === 'limits'}>Save limits</button>
        </form>
      </section>
    </div>
  );
}
