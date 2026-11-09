import StandaloneDownloadsPanel from './StandaloneDownloadsPanel.jsx';
import previews from './standalone-downloads.json';
import { formatSize, registeredWindows, safeDownloadUrl } from './download-links.mjs';
import React, { useEffect, useMemo, useState } from 'react';

const emptyForm = {
  version: '',
  build: '',
  notes: '',
  installerUrl: '',
  sha256: '',
  sizeBytes: '',
  platform: 'windows-x64',
};

const releasePlatforms = [
  { value: 'windows-x64', label: 'Windows installer (.exe)' },
  { value: 'android-universal', label: 'Android sideload APK (development signed)' },
  { value: 'source', label: 'Source archive (not deployable)' },
];

const releaseStatesPending = new Set(['offered', 'deferred', 'downloading', 'downloaded', 'installing', 'awaiting_confirmation']);
const cancelableOfferStates = new Set(['assigned', 'offered', 'deferred', 'downloading', 'downloaded', 'installing', 'awaiting_confirmation']);

function packageType(platform) {
  if (/^windows/i.test(platform)) return 'Windows installer';
  if (/^android/i.test(platform)) return 'Android test build';
  if (/^source/i.test(platform)) return 'Source archive';
  return 'Other package';
}

function publishedAt(release) {
  return release.published_at ?? release.released_at ?? null;
}

function registeredAt(release) {
  return release.created_at ?? release.registered_at ?? release.assigned_at ?? null;
}

function normalizeRelease(raw) {
  return {
    ...raw,
    installerUrl: raw.installer_url ?? raw.installerUrl ?? '',
    sizeBytes: Number(raw.size_bytes ?? raw.sizeBytes ?? 0),
    platform: String(raw.platform ?? 'windows-x64').toLowerCase(),
    build: Number(raw.build ?? 0),
  };
}

function sortNewest(a, b) {
  const left = Date.parse(registeredAt(a) ?? '') || 0;
  const right = Date.parse(registeredAt(b) ?? '') || 0;
  if (left !== right) return right - left;
  if (a.version !== b.version) return String(b.version).localeCompare(String(a.version), undefined, { numeric: true });
  return (b.build || 0) - (a.build || 0);
}

function parseVersionBuild(value) {
  const match = /^(\d+\.\d+\.\d+)\+(\d+)$/.exec(String(value ?? '').trim());
  if (!match) return null;
  return { version: match[1], build: Number(match[2]) };
}

function newerRelease(version, build, installed, installedBuild) {
  const parse = input => {
    if (!/^\d+\.\d+\.\d+$/.test(String(input))) return null;
    return String(input).split('.').map(Number);
  };
  const next = parse(version);
  const current = parse(installed);
  if (!next || !current) return false;
  for (let index = 0; index < 3; index += 1) {
    if (next[index] !== current[index]) return next[index] > current[index];
  }
  return Number(build) > Number(installedBuild || 0);
}

function formatStamp(value) {
  if (!value) return 'Not recorded';
  const when = new Date(value);
  if (Number.isNaN(when.getTime())) return 'Not recorded';
  return when.toLocaleString();
}

function releaseLabel(release) {
  return `${release.version}+${release.build} · ${packageType(release.platform)}`;
}

function androidOtaSignal(report) {
  if (!String(report.platform ?? '').startsWith('android')) {
    return null;
  }
  if (report.status === 'installing') {
    return {
      title: 'installer opened',
      detail: 'pending user confirmation',
    };
  }
  if (report.status === 'awaiting_confirmation') {
    return {
      title: 'pending user confirmation',
      detail: 'install verified on next heartbeat',
    };
  }
  if (report.status === 'verified') {
    return {
      title: 'install verified on next heartbeat',
      detail: 'confirmed by device heartbeat',
    };
  }
  return null;
}

function cancelledByAdmin(report) {
  return String(report.status ?? '') === 'failed'
    && /^Cancelled by admin from Release Center\./i.test(String(report.last_error ?? ''));
}

function assignmentStatusLabel(report) {
  return cancelledByAdmin(report) ? 'cancelled' : String(report.status ?? 'unknown');
}

function canCancelOffer(report) {
  return cancelableOfferStates.has(String(report.status ?? ''));
}

export default function ReleasesPanel({ request, token }) {
  const [form, setForm] = useState(emptyForm);
  const [releases, setReleases] = useState([]);
  const [devices, setDevices] = useState([]);
  const [reports, setReports] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [tab, setTab] = useState('library');
  const [search, setSearch] = useState('');
  const [platformFilter, setPlatformFilter] = useState('');
  const [availabilityFilter, setAvailabilityFilter] = useState('');
  const [detailsReleaseId, setDetailsReleaseId] = useState('');
  const [deployPlatform, setDeployPlatform] = useState('windows');
  const [deployReleaseId, setDeployReleaseId] = useState('');
  const [targets, setTargets] = useState([]);
  const [expandedHistoryDevice, setExpandedHistoryDevice] = useState('');

  const load = async () => {
    const [releaseRows, deviceRows, statusRows] = await Promise.all([
      request('/api/admin/releases'),
      request('/api/admin/devices'),
      request('/api/admin/update-status'),
    ]);
    setReleases((Array.isArray(releaseRows) ? releaseRows : []).map(normalizeRelease).sort(sortNewest));
    setDevices((Array.isArray(deviceRows) ? deviceRows : []).filter(device => !device.revoked_at));
    setReports(Array.isArray(statusRows) ? statusRows : []);
  };

  useEffect(() => {
    let active = true;
    const refresh = async () => {
      try {
        const [releaseRows, deviceRows, statusRows] = await Promise.all([
          request('/api/admin/releases'),
          request('/api/admin/devices'),
          request('/api/admin/update-status'),
        ]);
        if (!active) return;
        setReleases((Array.isArray(releaseRows) ? releaseRows : []).map(normalizeRelease).sort(sortNewest));
        setDevices((Array.isArray(deviceRows) ? deviceRows : []).filter(device => !device.revoked_at));
        setReports(Array.isArray(statusRows) ? statusRows : []);
      } catch (exception) {
        if (active) setError(exception.message);
      }
    };
    refresh();
    const timer = setInterval(refresh, 30000);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [token]);

  async function act(work, message) {
    setBusy(true);
    setError('');
    setNotice('');
    try {
      await work();
      await load();
      setNotice(message);
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  const releaseById = useMemo(() => {
    const map = new Map();
    for (const release of releases) map.set(release.id, release);
    return map;
  }, [releases]);

  const releaseDetails = detailsReleaseId ? releaseById.get(detailsReleaseId) : null;

  const latestWindows = useMemo(() => registeredWindows(releases)[0] ?? null, [releases]);
  const latestAndroidRelease = useMemo(
    () => releases.find(release => /^android/.test(release.platform)) ?? null,
    [releases],
  );
  const latestAndroidPreview = useMemo(
    () => (previews.downloads ?? []).find(item => /^android/i.test(String(item.platform ?? ''))) ?? null,
    [],
  );

  const releaseRows = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return releases.filter(release => {
      if (platformFilter && !release.platform.startsWith(platformFilter)) return false;
      if (availabilityFilter === 'enabled' && !release.enabled) return false;
      if (availabilityFilter === 'paused' && release.enabled) return false;
      if (availabilityFilter === 'test' && !/^android/.test(release.platform)) return false;
      if (availabilityFilter === 'source' && !/^source/.test(release.platform)) return false;
      if (!needle) return true;
      return [
        release.version,
        String(release.build),
        release.platform,
        release.notes ?? '',
      ].join(' ').toLowerCase().includes(needle);
    });
  }, [availabilityFilter, platformFilter, releases, search]);

  const deployableReleases = useMemo(
    () => releases.filter(release => !/^source/.test(release.platform) && release.platform.startsWith(deployPlatform)),
    [deployPlatform, releases],
  );

  useEffect(() => {
    if (!deployableReleases.length) {
      setDeployReleaseId('');
      setTargets([]);
      return;
    }
    if (!deployableReleases.some(release => release.id === deployReleaseId)) {
      setDeployReleaseId(deployableReleases[0].id);
      setTargets([]);
    }
  }, [deployableReleases, deployReleaseId]);

  const selectedDeployRelease = deployReleaseId ? releaseById.get(deployReleaseId) : null;

  const deployDeviceRows = useMemo(() => {
    if (!selectedDeployRelease) return [];
    return devices.map(device => {
      const parsed = parseVersionBuild(device.app_version);
      const eligible = !parsed || newerRelease(selectedDeployRelease.version, selectedDeployRelease.build, parsed.version, parsed.build);
      return {
        ...device,
        eligible,
        reason: eligible
          ? ''
          : `Already on ${device.app_version} (not older than target ${selectedDeployRelease.version}+${selectedDeployRelease.build}).`,
      };
    });
  }, [devices, selectedDeployRelease]);

  const reportRowsByDevice = useMemo(() => {
    const grouped = new Map();
    for (const row of reports) {
      const key = row.device_id ?? row.device_name;
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(row);
    }
    for (const rows of grouped.values()) {
      rows.sort((left, right) => {
        const leftStamp = Date.parse(left.assigned_at ?? left.updated_at ?? '') || 0;
        const rightStamp = Date.parse(right.assigned_at ?? right.updated_at ?? '') || 0;
        return rightStamp - leftStamp;
      });
    }
    return grouped;
  }, [reports]);

  const currentDeviceRows = useMemo(() => {
    const rows = [];
    for (const [deviceKey, list] of reportRowsByDevice) {
      const current = list[0];
      const history = list.slice(1);
      rows.push({ deviceKey, current, history });
    }
    rows.sort((left, right) => {
      const leftStamp = Date.parse(left.current.assigned_at ?? left.current.updated_at ?? '') || 0;
      const rightStamp = Date.parse(right.current.assigned_at ?? right.current.updated_at ?? '') || 0;
      return rightStamp - leftStamp;
    });
    return rows;
  }, [reportRowsByDevice]);

  const deploymentAttention = useMemo(() => {
    const pending = reports.filter(report => releaseStatesPending.has(String(report.status ?? ''))).length;
    const historicalFailures = reports
      .filter(report => String(report.status ?? '') === 'failed' && !cancelledByAdmin(report))
      .length;
    const cancelled = reports.filter(report => cancelledByAdmin(report)).length;
    return { pending, historicalFailures, cancelled };
  }, [reports]);

  async function toggleReleaseEnabled(release) {
    const text = release.enabled
      ? 'Pause future offers for this package? Running installers are not cancelled.'
      : 'Enable this package so assigned devices can receive the offer?';
    if (!window.confirm(text)) return;
    await act(
      () => request(`/api/admin/releases/${release.id}/enabled`, { method: 'POST', body: JSON.stringify({ enabled: !release.enabled }) }),
      release.enabled ? 'Release paused.' : 'Release enabled.',
    );
  }

  async function createRelease(event) {
    event.preventDefault();
    if (!window.confirm('Register immutable package metadata? This records metadata only and does not upload files.')) return;
    await act(async () => {
      await request('/api/admin/releases', {
        method: 'POST',
        body: JSON.stringify({
          ...form,
          build: Number(form.build),
          sizeBytes: Number(form.sizeBytes),
          sha256: form.sha256.trim().toLowerCase(),
        }),
      });
      setForm(emptyForm);
    }, 'Release package registered.');
  }

  async function assignRelease(event) {
    event.preventDefault();
    if (!selectedDeployRelease || !targets.length) return;
    if (!window.confirm(`Assign ${releaseLabel(selectedDeployRelease)} to ${targets.length} selected device(s)?`)) return;
    await act(async () => {
      await request(`/api/admin/releases/${selectedDeployRelease.id}/assign`, {
        method: 'POST',
        body: JSON.stringify({ deviceIds: targets }),
      });
      setTargets([]);
    }, 'Device assignments saved.');
  }

  async function cancelOffer(assignment) {
    if (!assignment?.id || !canCancelOffer(assignment)) return;
    const target = `${assignment.device_name ?? 'device'} → ${assignment.version}+${assignment.build}`;
    if (!window.confirm(`Cancel the offered release assignment for ${target}?`)) return;
    await act(
      () => request(`/api/admin/update-status/${assignment.id}/cancel`, { method: 'POST' }),
      'Offered release assignment cancelled.',
    );
  }

  return (
    <section className="panel release-center" id="app-releases">
      <div className="release-center-head">
        <div>
          <h2>Release Center</h2>
          <p>Find the right package, deploy to compatible devices, and track rollout state without scrolling through long notes.</p>
        </div>
        <button
          type="button"
          className="secondary"
          disabled={busy}
          onClick={() => act(async () => {}, 'Release center refreshed.')}
        >
          Refresh
        </button>
      </div>

      <div className="release-cards">
        <article className="release-card">
          <h3>Latest Windows installer</h3>
          {latestWindows ? (
            <>
              <p className="release-card-version">{latestWindows.title.replace('Windows ', '')}</p>
              <p>{latestWindows.platform} · {formatSize(latestWindows.sizeBytes)}</p>
              <div className="release-actions">
                {safeDownloadUrl(latestWindows.url) && (
                  <a href={safeDownloadUrl(latestWindows.url)} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Download .exe</a>
                )}
                <button type="button" className="secondary" onClick={() => {
                  const found = releases.find(release => release.id === latestWindows.id);
                  if (found) {
                    setDetailsReleaseId(found.id);
                    setTab('library');
                  }
                }}
                >View release</button>
              </div>
            </>
          ) : <p>No Windows installer is currently registered.</p>}
        </article>

        <article className="release-card">
          <h3>Latest Android APK</h3>
          {latestAndroidRelease || latestAndroidPreview ? (
            <>
              <p className="release-card-version">
                {latestAndroidRelease
                  ? `${latestAndroidRelease.version}+${latestAndroidRelease.build}`
                  : latestAndroidPreview.version}
              </p>
              <p>
                {String(latestAndroidRelease?.notes ?? '').toLowerCase().includes('development')
                  ? 'Development-signed sideload package.'
                  : 'Production-signed Android package for OTA deployment.'}
              </p>
              <div className="release-actions">
                {safeDownloadUrl((latestAndroidRelease?.installerUrl ?? latestAndroidPreview?.url)) && (
                  <a href={safeDownloadUrl(latestAndroidRelease?.installerUrl ?? latestAndroidPreview?.url)} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Download APK</a>
                )}
                {latestAndroidRelease && (
                  <button type="button" className="secondary" onClick={() => {
                    setDetailsReleaseId(latestAndroidRelease.id);
                    setTab('library');
                  }}
                  >View release</button>
                )}
              </div>
            </>
          ) : <p>No Android build metadata is currently registered.</p>}
        </article>

        <article className="release-card">
          <h3>Deployment attention</h3>
          <p className="release-card-version">{deploymentAttention.pending} pending</p>
          <p>{deploymentAttention.historicalFailures} historical failures</p>
          <p>{deploymentAttention.cancelled} cancelled offers</p>
          <div className="release-actions">
            <button type="button" className="secondary" onClick={() => setTab('devices')}>Review device status</button>
          </div>
        </article>
      </div>

      <nav className="release-tabs" aria-label="Release center sections">
        <button type="button" className={tab === 'library' ? 'selected' : ''} onClick={() => setTab('library')}>Release library</button>
        <button type="button" className={tab === 'deploy' ? 'selected' : ''} onClick={() => setTab('deploy')}>Deploy updates</button>
        <button type="button" className={tab === 'devices' ? 'selected' : ''} onClick={() => setTab('devices')}>Device status</button>
      </nav>

      {error && <div role="alert" className="error">{error}</div>}
      {notice && <p role="status">{notice}</p>}

      {tab === 'library' && (
        <div className="release-tab-panel">
          <div className="release-toolbar">
            <input
              aria-label="Search releases"
              type="search"
              placeholder="Search versions, builds, platforms or notes"
              value={search}
              onChange={event => setSearch(event.target.value)}
            />
            <select value={platformFilter} onChange={event => setPlatformFilter(event.target.value)} aria-label="Filter release platform">
              <option value="">All platforms</option>
              <option value="windows">Windows</option>
              <option value="android">Android</option>
              <option value="source">Source</option>
            </select>
            <select value={availabilityFilter} onChange={event => setAvailabilityFilter(event.target.value)} aria-label="Filter release availability">
              <option value="">All availability</option>
              <option value="enabled">Enabled</option>
              <option value="paused">Paused</option>
              <option value="test">Android test build</option>
              <option value="source">Source only</option>
            </select>
          </div>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Version / build</th>
                  <th>Platform / package</th>
                  <th>Released at</th>
                  <th>Availability</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {releaseRows.map(release => (
                  <tr key={release.id}>
                    <td>
                      <strong>{release.version}+{release.build}</strong>
                      <small>Registered: {formatStamp(registeredAt(release))}</small>
                    </td>
                    <td>{packageType(release.platform)}<small>{release.platform}</small></td>
                    <td>{formatStamp(publishedAt(release))}</td>
                    <td>{release.enabled ? 'Enabled' : 'Paused'}</td>
                    <td className="release-row-actions">
                      <button type="button" className="secondary" onClick={() => setDetailsReleaseId(release.id)}>View details</button>
                      {!/^source/.test(release.platform) && (
                        <button type="button" className="secondary" disabled={busy} onClick={() => toggleReleaseEnabled(release)}>
                          {release.enabled ? 'Pause' : 'Enable'}
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {!releaseRows.length && <p>No release packages match the current filters.</p>}
          <p className="release-table-foot">Published date appears as "Not recorded" when release publication timestamps were not captured.</p>
          <details className="release-register">
            <summary>Register release package metadata</summary>
            <form onSubmit={createRelease} className="release-form">
              <label>Version
                <input name="version" pattern="[0-9]+\.[0-9]+\.[0-9]+" value={form.version} onChange={event => setForm(old => ({ ...old, version: event.target.value }))} required disabled={busy} />
              </label>
              <label>Build number
                <input type="number" min="1" max="2147483647" step="1" name="build" value={form.build} onChange={event => setForm(old => ({ ...old, build: event.target.value }))} required disabled={busy} />
              </label>
              <label>Platform / package
                <select name="platform" value={form.platform} onChange={event => setForm(old => ({ ...old, platform: event.target.value }))} disabled={busy}>
                  {releasePlatforms.map(platform => <option key={platform.value} value={platform.value}>{platform.label}</option>)}
                </select>
              </label>
              <label>Release notes
                <textarea name="notes" rows={4} maxLength={12000} value={form.notes} onChange={event => setForm(old => ({ ...old, notes: event.target.value }))} disabled={busy} />
              </label>
              <label>HTTPS package URL
                <input type="url" name="installerUrl" maxLength={2048} value={form.installerUrl} onChange={event => setForm(old => ({ ...old, installerUrl: event.target.value }))} required disabled={busy} />
              </label>
              <label>SHA-256
                <input name="sha256" pattern="[a-fA-F0-9]{64}" minLength={64} maxLength={64} value={form.sha256} onChange={event => setForm(old => ({ ...old, sha256: event.target.value }))} required disabled={busy} />
              </label>
              <label>File size in bytes
                <input type="number" min="1" max="9007199254740991" step="1" name="sizeBytes" value={form.sizeBytes} onChange={event => setForm(old => ({ ...old, sizeBytes: event.target.value }))} required disabled={busy} />
              </label>
              <button disabled={busy}>Register package</button>
            </form>
          </details>
          <StandaloneDownloadsPanel releases={releases} />
        </div>
      )}

      {tab === 'deploy' && (
        <div className="release-tab-panel">
          <p>Deploying updates is separate from downloads. Choose the release, select eligible devices, then confirm assignment.</p>
          <form onSubmit={assignRelease} className="deploy-grid">
            <section>
              <h3>1. Choose platform and release</h3>
              <label>Platform
                <select value={deployPlatform} onChange={event => setDeployPlatform(event.target.value)} disabled={busy}>
                  <option value="windows">Windows</option>
                  <option value="android">Android</option>
                </select>
              </label>
              <label>Release package
                <select value={deployReleaseId} onChange={event => setDeployReleaseId(event.target.value)} disabled={busy || !deployableReleases.length}>
                  {!deployableReleases.length && <option value="">No deployable release for this platform</option>}
                  {deployableReleases.map(release => (
                    <option key={release.id} value={release.id}>{releaseLabel(release)} ({release.enabled ? 'enabled' : 'paused'})</option>
                  ))}
                </select>
              </label>
              {selectedDeployRelease && (
                <p>
                  {selectedDeployRelease.enabled ? 'Enabled for offers.' : 'Paused. Enable this release before deployment.'}
                  {' '}
                  {!selectedDeployRelease.enabled && (
                    <button type="button" className="secondary" disabled={busy} onClick={() => toggleReleaseEnabled(selectedDeployRelease)}>Enable now</button>
                  )}
                </p>
              )}
              {deployPlatform === 'android' && (
                <p>Android assignments open a development-signed APK link for manual sideload. They do not perform silent OTA installation.</p>
              )}
            </section>

            <section>
              <h3>2. Select compatible devices</h3>
              <fieldset disabled={busy || !selectedDeployRelease}>
                {!deployDeviceRows.length && <p>No eligible devices.</p>}
                {deployDeviceRows.map(device => (
                  <label key={device.id} className="ack-option">
                    <input
                      type="checkbox"
                      checked={targets.includes(device.id)}
                      disabled={!device.eligible || (!targets.includes(device.id) && targets.length >= 100)}
                      onChange={event => {
                        setTargets(previous => event.target.checked
                          ? [...previous, device.id]
                          : previous.filter(id => id !== device.id));
                      }}
                    />
                    <span>
                      {device.name} / {device.household_name} / {device.app_version || 'version unknown'}
                      {!device.eligible && <small>{device.reason}</small>}
                    </span>
                  </label>
                ))}
              </fieldset>
            </section>

            <section>
              <h3>3. Review and assign</h3>
              <p>Target release: {selectedDeployRelease ? releaseLabel(selectedDeployRelease) : 'None selected'}</p>
              <p>Selected devices: {targets.length}</p>
              <button disabled={busy || !selectedDeployRelease || !targets.length || !selectedDeployRelease.enabled}>Assign release</button>
            </section>
          </form>
        </div>
      )}

      {tab === 'devices' && (
        <div className="release-tab-panel">
          <p>Each device shows one current deployment row. Previous assignment attempts are available in a per-device history panel.</p>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Device</th>
                  <th>Reported version</th>
                  <th>Target version</th>
                  <th>Update state</th>
                  <th>Android OTA signal</th>
                  <th>Last contact</th>
                  <th>History</th>
                </tr>
              </thead>
              <tbody>
                {currentDeviceRows.map(({ deviceKey, current, history }) => {
                  const signal = androidOtaSignal(current);
                  return (
                  <React.Fragment key={deviceKey}>
                    <tr>
                      <td>{current.device_name}</td>
                      <td>{current.reported_version || 'Not reported'}</td>
                      <td>{current.version}+{current.build}</td>
                      <td>
                        <span>{assignmentStatusLabel(current)}</span>
                        {canCancelOffer(current) && (
                          <div className="release-history-actions">
                            <button type="button" className="secondary" disabled={busy} onClick={() => cancelOffer(current)}>
                              Cancel offer
                            </button>
                          </div>
                        )}
                      </td>
                      <td>
                        {signal
                          ? (
                            <>
                              <strong>{signal.title}</strong>
                              <small>{signal.detail}</small>
                            </>
                            )
                          : '—'}
                      </td>
                      <td>{formatStamp(current.last_seen_at)}</td>
                      <td>
                        {history.length > 0 ? (
                          <button
                            type="button"
                            className="secondary"
                            onClick={() => setExpandedHistoryDevice(expandedHistoryDevice === deviceKey ? '' : deviceKey)}
                          >
                            {expandedHistoryDevice === deviceKey ? 'Hide history' : `View history (${history.length})`}
                          </button>
                        ) : 'No history'}
                      </td>
                    </tr>
                    {expandedHistoryDevice === deviceKey && history.length > 0 && (
                      <tr>
                        <td colSpan={7}>
                          <div className="release-history-panel">
                            {history.map(item => (
                              <div key={item.id} className="release-history-row">
                                <strong>{item.version}+{item.build}</strong>
                                <span>{assignmentStatusLabel(item)}</span>
                                <span>{formatStamp(item.updated_at ?? item.assigned_at)}</span>
                                <span>{item.last_error || 'No error details.'}</span>
                                <div className="release-history-actions">
                                  {canCancelOffer(item) && (
                                    <button type="button" className="secondary" disabled={busy} onClick={() => cancelOffer(item)}>
                                      Cancel offer
                                    </button>
                                  )}
                                </div>
                              </div>
                            ))}
                          </div>
                        </td>
                      </tr>
                    )}
                  </React.Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
          {!currentDeviceRows.length && <p>No device update assignments are currently recorded.</p>}
        </div>
      )}

      {releaseDetails && (
        <div className="release-details-backdrop" onClick={() => setDetailsReleaseId('')}>
          <aside className="release-details" role="dialog" aria-modal="true" aria-label="Release details" onClick={event => event.stopPropagation()}>
            <h3>{releaseDetails.version}+{releaseDetails.build}</h3>
            <p>{packageType(releaseDetails.platform)} · {releaseDetails.platform}</p>
            <p>Published: {formatStamp(publishedAt(releaseDetails))}</p>
            <p>Registered: {formatStamp(registeredAt(releaseDetails))}</p>
            <p>Enabled: {releaseDetails.enabled ? 'Yes' : 'No'}</p>
            <p>SHA-256: <code>{releaseDetails.sha256 || 'Not recorded'}</code></p>
            <p>Size: {formatSize(releaseDetails.sizeBytes)}</p>
            <div className="release-actions">
              {safeDownloadUrl(releaseDetails.installerUrl) && (
                <a href={safeDownloadUrl(releaseDetails.installerUrl)} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Download package</a>
              )}
              {!/^source/.test(releaseDetails.platform) && (
                <button type="button" className="secondary" disabled={busy} onClick={() => toggleReleaseEnabled(releaseDetails)}>
                  {releaseDetails.enabled ? 'Pause release' : 'Enable release'}
                </button>
              )}
              <button type="button" className="secondary" onClick={() => setDetailsReleaseId('')}>Close</button>
            </div>
            <h4>Release notes</h4>
            <p style={{ whiteSpace: 'pre-wrap' }}>{releaseDetails.notes || 'No release notes recorded.'}</p>
          </aside>
        </div>
      )}
    </section>
  );
}
