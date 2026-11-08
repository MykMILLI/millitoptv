import React, { useEffect, useMemo, useState } from 'react';

function formatDate(value) {
  return value ? new Date(value).toLocaleString() : 'Not reported';
}

function blankSource() {
  return {
    id: `src-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
    name: '',
    type: 'm3u',
    m3uUrl: '',
    epgUrl: '',
    m3uMoviesUrl: '',
    m3uSeriesUrls: '',
    serverUrl: '',
    username: '',
    password: ''
  };
}

function normalizeSource(source) {
  const base = {
    id: String(source.id ?? '').trim(),
    name: String(source.name ?? '').trim(),
    type: String(source.type ?? 'm3u').trim().toLowerCase(),
    epgUrl: String(source.epgUrl ?? '').trim()
  };
  if (base.type === 'xtream') {
    return {
      ...base,
      serverUrl: String(
        source.serverUrl ?? source.url ?? source.server ?? source.host ?? '',
      ).trim(),
      username: String(source.username ?? '').trim(),
      password: String(source.password ?? '').trim()
    };
  }
  return {
    ...base,
    m3uUrl: String(source.m3uUrl ?? source.m3uLiveUrl ?? '').trim(),
    m3uMoviesUrl: String(source.m3uMoviesUrl ?? '').trim(),
    m3uSeriesUrls: String(source.m3uSeriesUrls ?? '').trim()
  };
}

function sourceIsValid(source) {
  if (!source.id || !source.name || !source.type) {
    return false;
  }
  if (source.type === 'xtream') {
    return Boolean(source.serverUrl && source.username && source.password);
  }
  return Boolean(source.m3uUrl);
}

export default function DevicesPanel({ request, households, token }) {
  const [devices, setDevices] = useState([]);
  const [liveTvByDevice, setLiveTvByDevice] = useState({});
  const [profileByDevice, setProfileByDevice] = useState({});
  const [tmdbByDevice, setTmdbByDevice] = useState({});
  const [sourcesByDevice, setSourcesByDevice] = useState({});
  const [expandedLiveTv, setExpandedLiveTv] = useState({});
  const [channelsByDevice, setChannelsByDevice] = useState({});
  const [loadingChannelsByDevice, setLoadingChannelsByDevice] = useState({});
  const [channelSourceByDevice, setChannelSourceByDevice] = useState({});
  const [channelGroupByDevice, setChannelGroupByDevice] = useState({});
  const [channelSearchByDevice, setChannelSearchByDevice] = useState({});
  const [householdId, setHouseholdId] = useState('');
  const [deviceName, setDeviceName] = useState('Living Room TV');
  const [pairing, setPairing] = useState(null);
  const [aclHouseholdId, setAclHouseholdId] = useState('');
  const [aclLibraries, setAclLibraries] = useState([]);
  const [aclProfiles, setAclProfiles] = useState([]);
  const [aclLoading, setAclLoading] = useState(false);
  const [aclEditor, setAclEditor] = useState({
    id: '',
    name: '',
    sharePath: '',
    enabled: true,
    tmdbEnabled: true,
    tmdbApiKey: '',
    profileIds: []
  });
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function load() {
    const [values, liveTvStates] = await Promise.all([
      request('/api/admin/devices'),
      request('/api/admin/live-tv/devices')
    ]);
    setDevices(values);
    const nextStates = {};
    const nextProfiles = {};
    const nextTmdb = {};
    const nextSources = {};
    for (const row of liveTvStates) {
      const config = row.config_payload && typeof row.config_payload === 'object'
        ? row.config_payload
        : {};
      const parsedSources = Array.isArray(config.sources)
        ? config.sources.map(item => normalizeSource(item))
        : [];
      nextStates[row.device_id] = row;
      nextProfiles[row.device_id] = String(config.profileId ?? 1);
      nextTmdb[row.device_id] = config.tmdbApiKey ?? '';
      nextSources[row.device_id] = parsedSources;
    }
    setLiveTvByDevice(nextStates);
    setProfileByDevice(current => ({ ...nextProfiles, ...current }));
    setTmdbByDevice(current => ({ ...nextTmdb, ...current }));
    setSourcesByDevice(current => ({ ...nextSources, ...current }));
  }

  useEffect(() => {
    let active = true;
    async function refresh() {
      try {
        await load();
      } catch (exception) {
        if (active) setError(exception.message);
      }
    }
    refresh();
    const timer = setInterval(refresh, 10000);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [token]);

  useEffect(() => {
    if (!aclHouseholdId && households.length > 0) {
      setAclHouseholdId(households[0].id);
    }
  }, [households, aclHouseholdId]);

  useEffect(() => {
    if (aclHouseholdId) {
      loadAcl(aclHouseholdId);
    }
  }, [aclHouseholdId]);

  async function generate(event) {
    event.preventDefault();
    setBusy(true);
    setError('');
    setPairing(null);
    try {
      const result = await request('/api/admin/pairing-codes', {
        method: 'POST',
        body: JSON.stringify({
          householdId: householdId || households[0]?.id,
          deviceName
        })
      });
      setPairing(result);
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  async function loadAcl(householdValue = aclHouseholdId) {
    const householdTarget = householdValue || households[0]?.id || '';
    if (!householdTarget) {
      setAclLibraries([]);
      setAclProfiles([]);
      return;
    }
    setAclLoading(true);
    try {
      const result = await request(`/api/admin/media-library/households/${householdTarget}`);
      setAclLibraries(Array.isArray(result.libraries) ? result.libraries : []);
      setAclProfiles(Array.isArray(result.profiles) ? result.profiles : []);
    } catch (exception) {
      setError(exception.message);
    } finally {
      setAclLoading(false);
    }
  }

  async function saveAclLibrary(event) {
    event?.preventDefault();
    const householdTarget = aclHouseholdId || households[0]?.id || '';
    if (!householdTarget) {
      setError('Select a household.');
      return;
    }
    if (!aclEditor.name.trim() || !aclEditor.sharePath.trim()) {
      setError('Library name and SMB/mounted path are required.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await request(`/api/admin/media-library/households/${householdTarget}/libraries`, {
        method: 'POST',
        body: JSON.stringify({
          id: aclEditor.id || undefined,
          name: aclEditor.name,
          sharePath: aclEditor.sharePath,
          enabled: aclEditor.enabled,
          tmdbEnabled: aclEditor.tmdbEnabled,
          tmdbApiKey: aclEditor.tmdbApiKey,
          profileIds: aclEditor.profileIds
        })
      });
      await loadAcl(householdTarget);
      setAclEditor({
        id: '',
        name: '',
        sharePath: '',
        enabled: true,
        tmdbEnabled: true,
        tmdbApiKey: '',
        profileIds: []
      });
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  async function removeAclLibrary(libraryId) {
    if (!window.confirm('Remove this media library and all its indexed items?')) {
      return;
    }
    setBusy(true);
    setError('');
    try {
      await request(`/api/admin/media-library/libraries/${libraryId}/delete`, {
        method: 'POST',
        body: '{}'
      });
      await loadAcl();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  async function indexAclLibrary(libraryId) {
    setBusy(true);
    setError('');
    try {
      const result = await request(`/api/admin/media-library/libraries/${libraryId}/index`, {
        method: 'POST',
        body: '{}'
      });
      await loadAcl();
      window.alert(`Indexed ${result.indexed ?? 0} items (${result.scanned ?? 0} scanned).`);
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  async function deleteDevice(device) {
    if (
      !window.confirm(
        `Delete ${device.name} from this console? It will need a new pairing code to reconnect.`,
      )
    ) {
      return;
    }
    setBusy(true);
    setError('');
    try {
      await request(`/api/admin/devices/${device.id}/delete`, {
        method: 'POST',
        body: '{}'
      });
      await load();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  function updateSource(deviceId, sourceId, patch) {
    setSourcesByDevice(current => {
      const existing = current[deviceId] ?? [];
      const updated = existing.map(source =>
        source.id === sourceId ? { ...source, ...patch } : source,
      );
      return { ...current, [deviceId]: updated };
    });
  }

  function addSource(deviceId) {
    setSourcesByDevice(current => ({
      ...current,
      [deviceId]: [...(current[deviceId] ?? []), blankSource()]
    }));
  }

  function removeSource(deviceId, sourceId) {
    setSourcesByDevice(current => ({
      ...current,
      [deviceId]: (current[deviceId] ?? []).filter(source => source.id !== sourceId)
    }));
  }

  async function saveLiveTvConfig(device) {
    const profileText = profileByDevice[device.id] ?? '1';
    const profileId = Number.parseInt(profileText, 10);
    if (!Number.isSafeInteger(profileId) || profileId < 1) {
      setError('Profile must be a positive number.');
      return;
    }
    const configuredSources = (sourcesByDevice[device.id] ?? []).map(normalizeSource);
    const invalid = configuredSources.find(source => !sourceIsValid(source));
    if (invalid) {
      setError('Each source needs required fields (name/type/url or Xtream credentials).');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await request(`/api/admin/live-tv/devices/${device.id}/config`, {
        method: 'POST',
        body: JSON.stringify({
          profileId,
          tmdbApiKey: tmdbByDevice[device.id] ?? '',
          sources: configuredSources
        })
      });
      await load();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  async function loadChannels(device) {
    const profileText = profileByDevice[device.id] ?? '1';
    const profileId = Number.parseInt(profileText, 10);
    if (!Number.isSafeInteger(profileId) || profileId < 1) {
      setError('Profile must be a positive number.');
      return;
    }
    setLoadingChannelsByDevice(current => ({ ...current, [device.id]: true }));
    setError('');
    try {
      const sourceId = channelSourceByDevice[device.id] ?? '';
      const query = sourceId
        ? `?profileId=${profileId}&sourceId=${encodeURIComponent(sourceId)}`
        : `?profileId=${profileId}`;
      const result = await request(
        `/api/admin/live-tv/devices/${device.id}/channels${query}`,
      );
      setChannelsByDevice(current => ({ ...current, [device.id]: result.sources ?? [] }));
      setChannelGroupByDevice(current => ({ ...current, [device.id]: 'All' }));
    } catch (exception) {
      setError(exception.message);
    } finally {
      setLoadingChannelsByDevice(current => ({ ...current, [device.id]: false }));
    }
  }

  async function startPlayback(device, channel) {
    const profileText = profileByDevice[device.id] ?? '1';
    const profileId = Number.parseInt(profileText, 10);
    if (!Number.isSafeInteger(profileId) || profileId < 1) {
      setError('Profile must be a positive number.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await request(`/api/admin/live-tv/devices/${device.id}/playback/start`, {
        method: 'POST',
        body: JSON.stringify({
          profileId,
          item: {
            mediaType: 'channel',
            mediaId: channel.id,
            title: channel.title,
            streamUrl: channel.streamUrl,
            sourceId: channel.sourceId,
            sourceName: channel.sourceName
          }
        })
      });
      await load();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBusy(false);
    }
  }

  function visibleChannels(deviceId) {
    const query = (channelSearchByDevice[deviceId] ?? '').trim().toLowerCase();
    const selectedGroup = channelGroupByDevice[deviceId] ?? 'All';
    const values = [];
    for (const source of channelsByDevice[deviceId] ?? []) {
      for (const channel of source.channels ?? []) {
        const item = {
          ...channel,
          sourceId: source.sourceId,
          sourceName: source.sourceName
        };
        if (selectedGroup !== 'All' && (item.group || '') !== selectedGroup) {
          continue;
        }
        if (
          query &&
          !item.title.toLowerCase().includes(query) &&
          !(item.group || '').toLowerCase().includes(query)
        ) {
          continue;
        }
        values.push(item);
      }
    }
    return values.slice(0, 500);
  }

  function groupOptions(deviceId) {
    const groups = new Set();
    for (const source of channelsByDevice[deviceId] ?? []) {
      for (const channel of source.channels ?? []) {
        if (channel.group) {
          groups.add(channel.group);
        }
      }
    }
    return ['All', ...Array.from(groups).sort((a, b) => a.localeCompare(b))];
  }

  const totalDevices = useMemo(() => devices.length, [devices]);

  return (
    <section className="panel">
      <h2>Devices</h2>
      <p>
        Generate a pairing code, then enter it in the Windows app.
        Codes expire after ten minutes and can be used once.
      </p>

      {error && <div className="error" role="alert">{error}</div>}

      {households.length > 0 ? (
        <form className="pairing-form" onSubmit={generate}>
          <label>
            Household
            <select
              value={householdId || households[0]?.id || ''}
              onChange={event => setHouseholdId(event.target.value)}
            >
              {households.map(household => (
                <option key={household.id} value={household.id}>
                  {household.name}
                </option>
              ))}
            </select>
          </label>

          <label>
            Device name
            <input
              required
              maxLength={120}
              value={deviceName}
              onChange={event => setDeviceName(event.target.value)}
            />
          </label>

          <button disabled={busy}>{busy ? 'Working…' : 'Generate pairing code'}</button>
        </form>
      ) : (
        <p>Create a household first.</p>
      )}

      {pairing && (
        <div className="pairing-result">
          <div>Pairing code for {pairing.deviceName}</div>
          <strong>{pairing.code}</strong>
          <small>Expires: {formatDate(pairing.expiresAt)}</small>
          <p>Anyone with this code can enroll a device into this household.</p>
        </div>
      )}

      <section className="device-live-tv">
        <h3>Household media ACL (SMB libraries)</h3>
        <small>
          Create SMB/mounted libraries and grant profile-level access. This ACL is enforced by the server catalog APIs.
        </small>
        <div className="inline-fields">
          <label>
            Household
            <select
              value={aclHouseholdId || households[0]?.id || ''}
              onChange={event => setAclHouseholdId(event.target.value)}
            >
              {households.map(household => (
                <option key={household.id} value={household.id}>
                  {household.name}
                </option>
              ))}
            </select>
          </label>
          <button
            className="secondary"
            disabled={aclLoading}
            onClick={() => loadAcl()}
          >
            {aclLoading ? 'Loading ACL…' : 'Load ACL'}
          </button>
        </div>

        <form className="source-card" onSubmit={saveAclLibrary}>
          <div className="inline-fields">
            <label>
              Library name
              <input
                required
                value={aclEditor.name}
                onChange={event => setAclEditor(current => ({ ...current, name: event.target.value }))}
              />
            </label>
            <label>
              SMB/mounted path
              <input
                required
                placeholder="/mnt/media/movies or \\\\SERVER\\Share\\Movies"
                value={aclEditor.sharePath}
                onChange={event => setAclEditor(current => ({ ...current, sharePath: event.target.value }))}
              />
            </label>
          </div>
          <div className="inline-fields">
            <label>
              TMDB API key (optional)
              <input
                value={aclEditor.tmdbApiKey}
                onChange={event => setAclEditor(current => ({ ...current, tmdbApiKey: event.target.value }))}
              />
            </label>
            <label>
              <input
                type="checkbox"
                checked={aclEditor.enabled}
                onChange={event => setAclEditor(current => ({ ...current, enabled: event.target.checked }))}
              />{' '}
              Enabled
            </label>
            <label>
              <input
                type="checkbox"
                checked={aclEditor.tmdbEnabled}
                onChange={event => setAclEditor(current => ({ ...current, tmdbEnabled: event.target.checked }))}
              />{' '}
              TMDB enrichment
            </label>
          </div>
          <div>
            <strong>Allowed household profiles</strong>
            <div className="inline-fields">
              {aclProfiles.length === 0 ? (
                <small>No synced household profiles yet. Sync profile identities from a paired app first.</small>
              ) : (
                aclProfiles.map(profile => (
                  <label key={profile.id}>
                    <input
                      type="checkbox"
                      checked={aclEditor.profileIds.includes(profile.id)}
                      onChange={event =>
                        setAclEditor(current => ({
                          ...current,
                          profileIds: event.target.checked
                            ? [...current.profileIds, profile.id]
                            : current.profileIds.filter(value => value !== profile.id)
                        }))
                      }
                    />{' '}
                    {profile.name} (#{profile.id})
                  </label>
                ))
              )}
            </div>
          </div>
          <button disabled={busy}>{busy ? 'Saving…' : (aclEditor.id ? 'Update library ACL' : 'Create library ACL')}</button>
        </form>

        {aclLibraries.length === 0 ? (
          <p className="empty">No ACL-managed libraries yet.</p>
        ) : (
          aclLibraries.map(library => (
            <article className="source-card" key={library.id}>
              <div className="device-heading">
                <div>
                  <strong>{library.name}</strong>
                  <p>{library.sharePath}</p>
                </div>
                <span className={`device-state ${library.enabled ? 'online' : 'offline'}`}>
                  {library.enabled ? 'enabled' : 'disabled'}
                </span>
              </div>
              <p>
                ACL profiles:{' '}
                {(library.profileIds ?? [])
                  .map(id => {
                    const profile = aclProfiles.find(value => value.id === id);
                    return profile ? `${profile.name} (#${id})` : `#${id}`;
                  })
                  .join(', ') || 'none'}
              </p>
              <div className="device-actions">
                <button
                  className="secondary"
                  onClick={() =>
                    setAclEditor({
                      id: library.id,
                      name: library.name ?? '',
                      sharePath: library.sharePath ?? '',
                      enabled: library.enabled !== false,
                      tmdbEnabled: library.tmdbEnabled !== false,
                      tmdbApiKey: library.tmdbApiKey ?? '',
                      profileIds: Array.isArray(library.profileIds)
                        ? library.profileIds.map(value => Number(value))
                        : []
                    })
                  }
                >
                  Edit ACL
                </button>
                <button className="secondary" onClick={() => indexAclLibrary(library.id)}>
                  Rebuild index
                </button>
                <button className="secondary" onClick={() => removeAclLibrary(library.id)}>
                  Remove
                </button>
              </div>
            </article>
          ))
        )}
      </section>

      {totalDevices === 0 ? (
        <p>No devices have enrolled yet.</p>
      ) : (
        devices.map(device => {
          const sourceRows = sourcesByDevice[device.id] ?? [];
          const groups = groupOptions(device.id);
          const listedChannels = visibleChannels(device.id);
          return (
            <article className="device-card" key={device.id}>
              <div className="device-heading">
                <div>
                  <h3>{device.name}</h3>
                  <p>{device.household_name}</p>
                </div>
                <span className={`device-state ${device.connection_status}`}>
                  {device.connection_status}
                </span>
              </div>

              <dl>
                <dt>Last opened</dt>
                <dd>{formatDate(device.last_opened_at)}</dd>
                <dt>Last contact</dt>
                <dd>{formatDate(device.last_seen_at)}</dd>
                <dt>Reported activity</dt>
                <dd>{device.reported_state.replaceAll('_', ' ')}</dd>
                <dt>App version</dt>
                <dd>{device.app_version || 'Not reported'}</dd>
              </dl>

              <>
                <div className="device-actions">
                  <button
                    className="secondary"
                    disabled={busy}
                    onClick={() =>
                      setExpandedLiveTv(current => ({
                        ...current,
                        [device.id]: !current[device.id]
                      }))
                    }
                  >
                    {expandedLiveTv[device.id] ? 'Hide Live TV controls' : 'Live TV controls'}
                  </button>
                  <button className="secondary" disabled={busy} onClick={() => deleteDevice(device)}>
                    Delete device
                  </button>
                </div>

                {expandedLiveTv[device.id] && (
                    <section className="device-live-tv">
                      <h4>Live TV remote controls</h4>
                      <small>
                        Configure sources with forms (no JSON) and start channel playback from a channel list.
                      </small>
                      {liveTvByDevice[device.id]?.playback_updated_at && (
                        <p>
                          Current playback: {liveTvByDevice[device.id].playback_payload?.title || 'Unknown'} ·{' '}
                          {liveTvByDevice[device.id].playback_payload?.active ? 'active' : 'stopped'} ·{' '}
                          {formatDate(liveTvByDevice[device.id].playback_updated_at)}
                        </p>
                      )}

                      <div className="inline-fields">
                        <label>
                          Profile ID
                          <input
                            value={profileByDevice[device.id] ?? '1'}
                            onChange={event =>
                              setProfileByDevice(current => ({
                                ...current,
                                [device.id]: event.target.value
                              }))
                            }
                          />
                        </label>
                        <label>
                          TMDB API key
                          <input
                            value={tmdbByDevice[device.id] ?? ''}
                            onChange={event =>
                              setTmdbByDevice(current => ({
                                ...current,
                                [device.id]: event.target.value
                              }))
                            }
                          />
                        </label>
                      </div>

                      <div className="sources-toolbar">
                        <strong>IPTV Sources</strong>
                        <button className="secondary" onClick={() => addSource(device.id)}>
                          Add source
                        </button>
                      </div>
                      {sourceRows.length === 0 && (
                        <p className="empty">No sources configured yet for this device profile.</p>
                      )}
                      {sourceRows.map(source => (
                        <div className="source-card" key={source.id}>
                          <div className="inline-fields">
                            <label>
                              Source ID
                              <input
                                value={source.id}
                                onChange={event =>
                                  updateSource(device.id, source.id, { id: event.target.value })
                                }
                              />
                            </label>
                            <label>
                              Source name
                              <input
                                value={source.name}
                                onChange={event =>
                                  updateSource(device.id, source.id, { name: event.target.value })
                                }
                              />
                            </label>
                          </div>
                          <div className="inline-fields">
                            <label>
                              Type
                              <select
                                value={source.type}
                                onChange={event =>
                                  updateSource(device.id, source.id, {
                                    type: event.target.value,
                                    ...(event.target.value === 'xtream'
                                      ? {
                                          serverUrl:
                                            source.serverUrl?.trim() ||
                                            source.m3uUrl?.trim() ||
                                            ''
                                        }
                                      : {
                                          m3uUrl:
                                            source.m3uUrl?.trim() ||
                                            source.serverUrl?.trim() ||
                                            ''
                                        })
                                  })
                                }
                              >
                                <option value="m3u">M3U</option>
                                <option value="xtream">Xtream</option>
                              </select>
                            </label>
                            <label>
                              EPG URL (optional)
                              <input
                                value={source.epgUrl ?? ''}
                                onChange={event =>
                                  updateSource(device.id, source.id, { epgUrl: event.target.value })
                                }
                              />
                            </label>
                          </div>
                          {source.type === 'xtream' ? (
                            <div className="inline-fields">
                              <label>
                                Server URL
                                <input
                                  value={source.serverUrl ?? ''}
                                  onChange={event =>
                                    updateSource(device.id, source.id, { serverUrl: event.target.value })
                                  }
                                />
                              </label>
                              <label>
                                Username
                                <input
                                  value={source.username ?? ''}
                                  onChange={event =>
                                    updateSource(device.id, source.id, { username: event.target.value })
                                  }
                                />
                              </label>
                              <label>
                                Password
                                <input
                                  value={source.password ?? ''}
                                  onChange={event =>
                                    updateSource(device.id, source.id, { password: event.target.value })
                                  }
                                />
                              </label>
                            </div>
                          ) : (
                            <div className="inline-fields">
                              <label>
                                Live M3U URL
                                <input
                                  value={source.m3uUrl ?? ''}
                                  onChange={event =>
                                    updateSource(device.id, source.id, { m3uUrl: event.target.value })
                                  }
                                />
                              </label>
                              <label>
                                Movies URL (optional)
                                <input
                                  value={source.m3uMoviesUrl ?? ''}
                                  onChange={event =>
                                    updateSource(device.id, source.id, { m3uMoviesUrl: event.target.value })
                                  }
                                />
                              </label>
                              <label>
                                Series URLs (optional)
                                <input
                                  value={source.m3uSeriesUrls ?? ''}
                                  onChange={event =>
                                    updateSource(device.id, source.id, { m3uSeriesUrls: event.target.value })
                                  }
                                />
                              </label>
                            </div>
                          )}
                          <button
                            className="secondary"
                            onClick={() => removeSource(device.id, source.id)}
                          >
                            Remove source
                          </button>
                        </div>
                      ))}

                      <button disabled={busy} onClick={() => saveLiveTvConfig(device)}>
                        Save device IPTV sources
                      </button>

                      <div className="channels-toolbar">
                        <strong>Channel browser</strong>
                        <button
                          className="secondary"
                          disabled={loadingChannelsByDevice[device.id]}
                          onClick={() => loadChannels(device)}
                        >
                          {loadingChannelsByDevice[device.id] ? 'Loading channels…' : 'Load channels'}
                        </button>
                      </div>

                      <div className="inline-fields">
                        <label>
                          Source filter
                          <select
                            value={channelSourceByDevice[device.id] ?? ''}
                            onChange={event =>
                              setChannelSourceByDevice(current => ({
                                ...current,
                                [device.id]: event.target.value
                              }))
                            }
                          >
                            <option value="">All sources</option>
                            {(sourcesByDevice[device.id] ?? []).map(source => (
                              <option key={source.id} value={source.id}>
                                {source.name || source.id}
                              </option>
                            ))}
                          </select>
                        </label>
                        <label>
                          Category
                          <select
                            value={channelGroupByDevice[device.id] ?? 'All'}
                            onChange={event =>
                              setChannelGroupByDevice(current => ({
                                ...current,
                                [device.id]: event.target.value
                              }))
                            }
                          >
                            {groups.map(group => (
                              <option key={group} value={group}>
                                {group}
                              </option>
                            ))}
                          </select>
                        </label>
                        <label>
                          Search channels
                          <input
                            value={channelSearchByDevice[device.id] ?? ''}
                            onChange={event =>
                              setChannelSearchByDevice(current => ({
                                ...current,
                                [device.id]: event.target.value
                              }))
                            }
                          />
                        </label>
                      </div>

                      <div className="channel-list">
                        {listedChannels.length === 0 ? (
                          <p className="empty">No channels loaded yet. Click “Load channels”.</p>
                        ) : (
                          listedChannels.map(channel => (
                            <div className="channel-row" key={`${channel.sourceId}|${channel.id}`}>
                              <div>
                                <strong>{channel.title}</strong>
                                <small>
                                  {(channel.group || 'Uncategorized')} · {channel.sourceName}
                                </small>
                              </div>
                              <button
                                className="secondary"
                                disabled={busy}
                                onClick={() => startPlayback(device, channel)}
                              >
                                Play on device
                              </button>
                            </div>
                          ))
                        )}
                      </div>
                    </section>
                  )}
              </>
            </article>
          );
        })
      )}

      <small>
        Device list refreshes every ten seconds.
        “Offline” means no recent heartbeat, not proof the PC is powered off.
      </small>
    </section>
  );
}
