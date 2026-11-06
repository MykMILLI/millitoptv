import CommunityPanel from './CommunityPanel.jsx';
import BillingPanel from './BillingPanel.jsx';
import WebAppsPanel from './WebAppsPanel.jsx';
import ReleasesPanel from './ReleasesPanel.jsx';
import MessagesPanel from './MessagesPanel.jsx';
import DevicesPanel from './DevicesPanel.jsx';
import SmbSharesPanel from './SmbSharesPanel.jsx';
import React, { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './style.css';

const TOKEN_STORAGE_KEY = 'millitop.dashboard.admin.token';
const EMAIL_STORAGE_KEY = 'millitop.dashboard.admin.email';

function App() {
  const [token, setToken] = useState(() => {
    try {
      return window.localStorage.getItem(TOKEN_STORAGE_KEY) ?? '';
    } catch (exception) {
      console.warn('Unable to load stored dashboard token.', exception);
      return '';
    }
  });
  const [email, setEmail] = useState(() => {
    try {
      return window.localStorage.getItem(EMAIL_STORAGE_KEY) ?? 'mykal.mills@millitop.net';
    } catch (exception) {
      console.warn('Unable to load stored dashboard email.', exception);
      return 'mykal.mills@millitop.net';
    }
  });
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [overview, setOverview] = useState(null);
  const [households, setHouseholds] = useState([]);
  const [name, setName] = useState('');
  const [page, setPage] = useState('overview');

  function clearSession() {
    setToken('');
    try {
      window.localStorage.removeItem(TOKEN_STORAGE_KEY);
    } catch (exception) {
      console.warn('Unable to clear stored dashboard token.', exception);
    }
  }

  async function request(path, options = {}, accessToken = token) {
    const response = await fetch(path, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {})
      }
    });

    const data = await response.json();

    if (!response.ok) {
      if (response.status === 401 && accessToken) {
        clearSession();
      }
      throw new Error(data.error || 'Request failed.');
    }

    return data;
  }

  async function refresh() {
    const [summary, list] = await Promise.all([
      request('/api/admin/overview'),
      request('/api/admin/households')
    ]);

    setOverview(summary);
    setHouseholds(list);
  }

  useEffect(() => {
    if (!token) {
      setOverview(null);
      setHouseholds([]);
      return;
    }

    refresh().catch(exception => setError(exception.message));

    const timer = setInterval(() => {
      refresh().catch(exception => setError(exception.message));
    }, 10000);

    return () => clearInterval(timer);
  }, [token]);

  useEffect(() => {
    try {
      if (token) {
        window.localStorage.setItem(TOKEN_STORAGE_KEY, token);
      } else {
        window.localStorage.removeItem(TOKEN_STORAGE_KEY);
      }
    } catch (exception) {
      console.warn('Unable to persist dashboard token.', exception);
    }
  }, [token]);

  useEffect(() => {
    try {
      if (email?.trim()) {
        window.localStorage.setItem(EMAIL_STORAGE_KEY, email.trim());
      }
    } catch (exception) {
      console.warn('Unable to persist dashboard email.', exception);
    }
  }, [email]);

  async function login(event) {
    event.preventDefault();
    setBusy(true);
    setError('');

    try {
      const result = await request('/api/login', {
        method: 'POST',
        body: JSON.stringify({ email, password })
      }, '');

      setPassword('');
      setToken(result.accessToken);
    } catch (exception) {
      setPassword('');
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  async function createHousehold(event) {
    event.preventDefault();
    setBusy(true);
    setError('');

    try {
      await request('/api/admin/households', {
        method: 'POST',
        body: JSON.stringify({ name })
      });

      setName('');
      await refresh();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  if (!token) {
    return (
      <main className="login">
        <section className="panel login-panel">
          <div className="brand">MILLITOP TV</div>
          <h1>Dashboard sign-in</h1>
          <p>Authorized administrators only.</p>

          <form onSubmit={login}>
            <label>Email
              <input
                type="email"
                autoComplete="username"
                required
                value={email}
                onChange={event => setEmail(event.target.value)}
              />
            </label>

            <label>Password
              <input
                type="password"
                autoComplete="current-password"
                required
                value={password}
                onChange={event => setPassword(event.target.value)}
              />
            </label>

            {error && <div role="alert" className="error">{error}</div>}

            <button disabled={busy}>
              {busy ? 'Signing in…' : 'Sign in'}
            </button>
          </form>
        </section>
      </main>
    );
  }

  const navigation = [['overview','Overview'],['households','Households'],['devices','Devices'],['smb','SMB Shares'],['billing','Billing & projects'],['webapps','Web apps'],['messages','Messages'],['community','Support & content'],['releases','Releases']];
  return <div className="admin-shell">
    <a className="skip-link" href="#workspace">Skip to workspace</a>
    <aside className="sidebar"><div className="sidebar-brand">MILLITOP TV<small>ADMIN CONSOLE</small></div>
      <nav aria-label="Dashboard sections">{navigation.map(([id,label])=><button type="button" key={id} aria-current={page===id?'page':undefined} className={'nav-item '+(page===id?'selected':'')} onClick={()=>{setPage(id);setError('');}}>{label}</button>)}</nav>
      <div className="sidebar-session"><small>ADMIN SESSION</small><span>{overview?.admin?.email}</span><small>{overview?.admin?.role}</small><button className="secondary" onClick={()=>{clearSession();setError('');setPage('overview');}}>Sign out</button></div>
    </aside>
    <div className="workspace-shell"><header className="workspace-header"><div><h1>{navigation.find(([id])=>id===page)?.[1]}</h1><p>{page==='billing'?'Square customer links, account access and project progress':'Millitop TV administration'}</p></div><button className="secondary" onClick={()=>refresh().catch(e=>setError(e.message))}>Refresh summary</button></header>
    <main id="workspace" className="workspace" tabIndex={-1}>
      {error&&<div role="alert" className="error">{error}</div>}
      {page==='overview'&&<div className="page-stack">      <section className="stats">
        {[
          ['Households', overview?.households],
          ['Enrolled devices', overview?.devices],
          ['Online', overview?.online],
          ['Messages', overview?.messages]
        ].map(([label, value]) => (
          <article className="panel stat" key={label}>
            <span>{label}</span>
            <strong>{value ?? '—'}</strong>
          </article>
        ))}
      </section>


        <section className="panel"><h2>Your workspace</h2><p>Choose an area to manage. Forms and technical details stay in their own workspace.</p><div className="quick-links">{navigation.slice(1).map(([id,label])=><button className="secondary" key={id} onClick={()=>setPage(id)}>{label}<span aria-hidden="true"> →</span></button>)}</div></section>
        <section className="panel"><h2>Households</h2>{households.length?<ul className="households">{households.map(h=><li key={h.id}><span>{h.name}</span><span>{h.devices} devices</span></li>)}</ul>:<p>No households yet.</p>}<button className="secondary" onClick={()=>setPage('households')}>Manage households</button></section>
      </div>}
      {page==='households'&&<>      <section className="panel">
        <h2>Households</h2>
        <p>Create a household before enrolling its Windows devices.</p>

        <form className="inline" onSubmit={createHousehold}>
          <input
            aria-label="Household name"
            placeholder="Household name"
            maxLength={120}
            required
            value={name}
            onChange={event => setName(event.target.value)}
          />
          <button disabled={busy}>
            {busy ? 'Saving…' : 'Add household'}
          </button>
        </form>

        {households.length === 0 ? (
          <p className="empty">No households have been created.</p>
        ) : (
          <ul className="households">
            {households.map(household => (
              <li key={household.id}>
                <span>{household.name}</span>
                <span>{household.devices} devices</span>
              </li>
            ))}
          </ul>
        )}
      </section>

</>}
      {page==='devices'&&<DevicesPanel request={request} token={token} households={households}/>}
      {page==='smb'&&<SmbSharesPanel request={request} households={households}/>}
      {page==='billing'&&<BillingPanel request={request} token={token} households={households}/>}
      {page==='webapps'&&<WebAppsPanel request={request} token={token}/>}
      {page==='messages'&&<MessagesPanel request={request} token={token} households={households}/>}
      {page==='community'&&<CommunityPanel request={request} token={token} households={households}/>}
      {page==='releases'&&<ReleasesPanel request={request} token={token}/>}
    </main><footer className="workspace-footer"><span>Database migration: {overview?.schema_version??'checking'}</span><span>Dashboard layout v2</span></footer></div>
  </div>;

}

createRoot(document.getElementById('root')).render(<App />);
