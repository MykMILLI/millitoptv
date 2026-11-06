import React, { useEffect, useMemo, useState } from 'react';

function sourceGroupKey(source) {
  return [
    String(source.name ?? '').trim().toLowerCase(),
    String(source.rootPath ?? '').trim().toLowerCase(),
    String(source.smbUsername ?? '').trim().toLowerCase(),
    String(source.smbDomain ?? '').trim().toLowerCase(),
  ].join('::');
}

function defaultSourceEditor(households) {
  return {
    name: '',
    rootPath: '',
    smbUsername: '',
    smbPassword: '',
    smbDomain: '',
    tmdbApiKey: '',
    enabled: true,
    selectedHouseholds: households.map(item => item.id),
  };
}

function defaultLibraryEditor(households) {
  return {
    name: '',
    mediaKind: 'movie',
    selectedHouseholds: households.map(item => item.id),
    selectedSourceKey: '',
    selectedDirectoryPath: '',
    selectedDirectories: [],
    manualPath: '',
  };
}

function libraryGroupKey(library) {
  return `${String(library.displayName ?? library.name ?? '').trim().toLowerCase()}::${String(
    library.mediaKindOverride ?? 'auto'
  ).trim().toLowerCase()}`;
}

export default function SmbSharesPanel({ request, households }) {
  const [loading, setLoading] = useState(false);
  const [savingSource, setSavingSource] = useState(false);
  const [savingLibrary, setSavingLibrary] = useState(false);
  const [browsingSourceKey, setBrowsingSourceKey] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [sources, setSources] = useState([]);
  const [libraries, setLibraries] = useState([]);
  const [editingSourceKey, setEditingSourceKey] = useState('');
  const [sourceEditor, setSourceEditor] = useState(() => defaultSourceEditor([]));
  const [libraryEditor, setLibraryEditor] = useState(() => defaultLibraryEditor([]));
  const [browseEntriesBySource, setBrowseEntriesBySource] = useState({});
  const [profilesByHousehold, setProfilesByHousehold] = useState({});

  useEffect(() => {
    setSourceEditor(current => {
      if (current.selectedHouseholds.length > 0) {
        return current;
      }
      return defaultSourceEditor(households);
    });
    setLibraryEditor(current => {
      if (current.selectedHouseholds.length > 0) {
        return current;
      }
      return defaultLibraryEditor(households);
    });
  }, [households]);

  async function load() {
    setLoading(true);
    setError('');
    try {
      const sourceGrouped = new Map();
      const libraryGrouped = new Map();
      const profiles = {};

      for (const household of households) {
        const [sourceResult, libraryResult] = await Promise.all([
          request(`/api/admin/media-library/households/${household.id}/sources`),
          request(`/api/admin/media-library/households/${household.id}`),
        ]);
        profiles[household.id] = Array.isArray(libraryResult.profiles) ? libraryResult.profiles : [];

        for (const source of sourceResult.sources ?? []) {
          const key = sourceGroupKey(source);
          if (!sourceGrouped.has(key)) {
            sourceGrouped.set(key, {
              key,
              name: source.name ?? '',
              rootPath: source.rootPath ?? '',
              smbUsername: source.smbUsername ?? '',
              smbPassword: source.smbPassword ?? '',
              hasSmbPassword: String(source.smbPassword ?? '').length > 0,
              smbDomain: source.smbDomain ?? '',
              tmdbApiKey: source.tmdbApiKey ?? '',
              enabled: source.enabled !== false,
              assignments: [],
            });
          } else if (String(source.smbPassword ?? '').length > 0) {
            sourceGrouped.get(key).hasSmbPassword = true;
          }
          sourceGrouped.get(key).assignments.push({
            householdId: household.id,
            householdName: household.name,
            sourceId: source.id,
          });
        }

        for (const library of libraryResult.libraries ?? []) {
          const key = libraryGroupKey(library);
          if (!libraryGrouped.has(key)) {
            libraryGrouped.set(key, {
              key,
              name: library.displayName ?? library.name ?? '',
              mediaKind: library.mediaKindOverride || 'auto',
              directories: [],
              households: new Set(),
            });
          }
          const target = libraryGrouped.get(key);
          target.directories.push(library.sharePath);
          target.households.add(household.name);
        }
      }

      setSources(
        Array.from(sourceGrouped.values()).sort((a, b) => a.name.localeCompare(b.name))
      );
      setLibraries(
        Array.from(libraryGrouped.values())
          .map(item => ({
            ...item,
            directories: Array.from(new Set(item.directories)),
            households: Array.from(item.households),
          }))
          .sort((a, b) => a.name.localeCompare(b.name))
      );
      setProfilesByHousehold(profiles);
    } catch (exception) {
      setError(exception.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (households.length > 0) {
      load();
    } else {
      setSources([]);
      setLibraries([]);
      setProfilesByHousehold({});
    }
  }, [households.map(item => item.id).join('|')]);

  function resetSourceEditor() {
    setEditingSourceKey('');
    setSourceEditor(defaultSourceEditor(households));
  }

  function editSource(source) {
    setEditingSourceKey(source.key);
    setSourceEditor({
      name: source.name ?? '',
      rootPath: source.rootPath ?? '',
      smbUsername: source.smbUsername ?? '',
      smbPassword: '',
      smbDomain: source.smbDomain ?? '',
      tmdbApiKey: source.tmdbApiKey ?? '',
      enabled: source.enabled !== false,
      selectedHouseholds: source.assignments.map(item => item.householdId),
    });
    setError('');
    setNotice('');
  }

  function resetLibraryEditor() {
    setLibraryEditor(defaultLibraryEditor(households));
    setBrowseEntriesBySource({});
  }

  async function saveSource(event) {
    event.preventDefault();
    const name = sourceEditor.name.trim();
    const rootPath = sourceEditor.rootPath.trim();
    if (!name || !rootPath) {
      setError('Source name and root SMB path are required.');
      return;
    }
    if (sourceEditor.selectedHouseholds.length === 0) {
      setError('Select at least one household for this source.');
      return;
    }

    const existing = editingSourceKey
      ? sources.find(item => item.key === editingSourceKey)
      : sources.find(item => sourceGroupKey(item) === sourceGroupKey(sourceEditor));
    if (
      sourceEditor.smbUsername.trim() &&
      !sourceEditor.smbPassword.trim() &&
      !(existing?.hasSmbPassword)
    ) {
      setError('SMB password is required for this source.');
      return;
    }
    const selectedHouseholds = new Set(sourceEditor.selectedHouseholds);

    setSavingSource(true);
    setError('');
    setNotice('');
    try {
      for (const householdId of selectedHouseholds) {
        const assignment = existing?.assignments.find(item => item.householdId === householdId);
        await request(`/api/admin/media-library/households/${householdId}/sources`, {
          method: 'POST',
          body: JSON.stringify({
            id: assignment?.sourceId,
            name,
            rootPath,
            smbUsername: sourceEditor.smbUsername,
            smbPassword: sourceEditor.smbPassword,
            smbDomain: sourceEditor.smbDomain,
            tmdbApiKey: sourceEditor.tmdbApiKey,
            enabled: sourceEditor.enabled,
          }),
        });
      }
      for (const assignment of existing?.assignments ?? []) {
        if (!selectedHouseholds.has(assignment.householdId)) {
          await request(`/api/admin/media-library/sources/${assignment.sourceId}/delete`, {
            method: 'POST',
            body: '{}',
          });
        }
      }
      setNotice('SMB source saved.');
      resetSourceEditor();
      await load();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setSavingSource(false);
    }
  }

  async function removeSource(source) {
    if (!window.confirm(`Remove source "${source.name}" from all assigned households?`)) {
      return;
    }
    setSavingSource(true);
    setError('');
    setNotice('');
    try {
      for (const assignment of source.assignments) {
        await request(`/api/admin/media-library/sources/${assignment.sourceId}/delete`, {
          method: 'POST',
          body: '{}',
        });
      }
      setNotice(`Source "${source.name}" removed.`);
      await load();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setSavingSource(false);
    }
  }

  async function browseSource(sourceKeyValue) {
    const source = sources.find(item => item.key === sourceKeyValue);
    if (!source) {
      return;
    }
    setBrowsingSourceKey(sourceKeyValue);
    setError('');
    try {
      const result = await request('/api/admin/media-library/browse-share', {
        method: 'POST',
        body: JSON.stringify({
          sharePath: source.rootPath,
          smbUsername: source.smbUsername,
          smbPassword: source.smbPassword,
          smbDomain: source.smbDomain,
        }),
      });
      const directories = (result.entries ?? []).filter(item => item.type === 'directory');
      setBrowseEntriesBySource(current => ({ ...current, [sourceKeyValue]: directories }));
      if (directories.length === 0) {
        setNotice(`No subdirectories found for ${source.name}.`);
      }
    } catch (exception) {
      setError(exception.message);
    } finally {
      setBrowsingSourceKey('');
    }
  }

  function selectedSourceObjects() {
    return sources.filter(item => item.key === libraryEditor.selectedSourceKey);
  }

  function addManualDirectory() {
    const pathValue = libraryEditor.manualPath.trim();
    if (!pathValue) {
      return;
    }

    function addSelectedDirectory() {
      const source = sources.find(item => item.key === libraryEditor.selectedSourceKey);
      if (!source) {
        setError('Select a source first.');
        return;
      }
      const pathValue = libraryEditor.selectedDirectoryPath.trim();
      if (!pathValue) {
        setError('Select a directory first.');
        return;
      }
      const key = `${source.key}::${pathValue}`;
      setLibraryEditor(current => {
        if (current.selectedDirectories.some(item => item.key === key)) {
          return current;
        }
        return {
          ...current,
          selectedDirectories: [...current.selectedDirectories, { key, sourceKey: source.key, path: pathValue }],
          selectedDirectoryPath: '',
        };
      });
    }
    const source = selectedSourceObjects()[0];
    if (!source) {
      setError('Select at least one source before adding directories.');
      return;
    }
    const next = [...libraryEditor.selectedDirectories];
    const key = `${source.key}::${pathValue}`;
    if (!next.find(item => item.key === key)) {
      next.push({
        key,
        sourceKey: source.key,
        path: pathValue,
      });
    }
    setLibraryEditor(current => ({ ...current, selectedDirectories: next, manualPath: '' }));
  }

  async function saveLibrary(event) {
    event.preventDefault();
    const name = libraryEditor.name.trim();
    if (!name) {
      setError('Library name is required.');
      return;
    }
    if (libraryEditor.selectedHouseholds.length === 0) {
      setError('Select at least one household.');
      return;
    }
    if (libraryEditor.selectedDirectories.length === 0) {
      setError('Select at least one directory for this library.');
      return;
    }

    const sourceMap = new Map(sources.map(item => [item.key, item]));
    const selectedHouseholds = new Set(libraryEditor.selectedHouseholds);
    const selectedMediaKind = libraryEditor.mediaKind || 'auto';

    setSavingLibrary(true);
    setError('');
    setNotice('');
    try {
      for (const householdId of selectedHouseholds) {
        const profiles = (profilesByHousehold[householdId] ?? []).map(item => Number(item.id));
        for (const directory of libraryEditor.selectedDirectories) {
          const source = sourceMap.get(directory.sourceKey);
          if (!source) {
            continue;
          }
          await request(`/api/admin/media-library/households/${householdId}/libraries`, {
            method: 'POST',
            body: JSON.stringify({
              name,
              sharePath: directory.path,
              enabled: true,
              tmdbEnabled: true,
              tmdbApiKey: source.tmdbApiKey ?? '',
              smbUsername: source.smbUsername,
              smbPassword: source.smbPassword,
              smbDomain: source.smbDomain,
              mediaKind: selectedMediaKind,
              profileIds: profiles,
            }),
          });
        }
      }
      setNotice('Library saved. Directories from multiple shares were combined under one library.');
      resetLibraryEditor();
      await load();
    } catch (exception) {
      setError(exception.message);
    } finally {
      setSavingLibrary(false);
    }
  }

  const selectedSources = useMemo(() => selectedSourceObjects(), [libraryEditor.selectedSourceKey, sources]);

  return (
    <section className="panel page-stack">
      <section className="panel">
        <h2>SMB shares</h2>
        <p>
          Step 1: Add SMB sources once. Step 2: Build media libraries by selecting folders from those sources.
        </p>
        {error && <div className="error" role="alert">{error}</div>}
        {notice && <div className="pairing-result"><small>{notice}</small></div>}
      </section>

      <section className="panel">
        <h3>Step 1 — Add SMB sources</h3>
        <form className="source-card" onSubmit={saveSource}>
          <div className="inline-fields">
            <label>
              Source name
              <input
                required
                value={sourceEditor.name}
                onChange={event => setSourceEditor(current => ({ ...current, name: event.target.value }))}
              />
            </label>
            <label>
              Root SMB path
              <input
                required
                placeholder="\\\\SERVER\\Share"
                value={sourceEditor.rootPath}
                onChange={event => setSourceEditor(current => ({ ...current, rootPath: event.target.value }))}
              />
            </label>
          </div>
          <div className="inline-fields">
            <label>
              SMB username
              <input
                value={sourceEditor.smbUsername}
                onChange={event => setSourceEditor(current => ({ ...current, smbUsername: event.target.value }))}
              />
            </label>
            <label>
              SMB password
              <input
                type="password"
                placeholder={editingSourceKey ? 'Leave blank to keep existing password' : ''}
                value={sourceEditor.smbPassword}
                onChange={event => setSourceEditor(current => ({ ...current, smbPassword: event.target.value }))}
              />
            </label>
            <label>
              SMB domain/workgroup
              <input
                value={sourceEditor.smbDomain}
                onChange={event => setSourceEditor(current => ({ ...current, smbDomain: event.target.value }))}
              />
            </label>
            <label>
              TMDB API key (optional)
              <input
                value={sourceEditor.tmdbApiKey}
                onChange={event => setSourceEditor(current => ({ ...current, tmdbApiKey: event.target.value }))}
              />
            </label>
          </div>
          <div>
            <strong>Household access</strong>
            <div className="inline-fields">
              {households.map(household => (
                <label key={household.id}>
                  <input
                    type="checkbox"
                    checked={sourceEditor.selectedHouseholds.includes(household.id)}
                    onChange={event =>
                      setSourceEditor(current => ({
                        ...current,
                        selectedHouseholds: event.target.checked
                          ? [...current.selectedHouseholds, household.id]
                          : current.selectedHouseholds.filter(value => value !== household.id),
                      }))
                    }
                  />{' '}
                  {household.name}
                </label>
              ))}
            </div>
          </div>
          <div className="device-actions">
            <button disabled={savingSource}>
              {savingSource ? 'Saving…' : editingSourceKey ? 'Update source' : 'Save source'}
            </button>
            <button type="button" className="secondary" onClick={resetSourceEditor}>
              {editingSourceKey ? 'Cancel edit' : 'New source'}
            </button>
          </div>
        </form>

        <div className="page-stack">
          {sources.length === 0 ? (
            <p className="empty">No SMB sources added yet.</p>
          ) : (
            sources.map(source => (
              <article className="source-card" key={source.key}>
                <div className="device-heading">
                  <div>
                    <strong>{source.name}</strong>
                    <p>{source.rootPath}</p>
                    <small>
                      Auth: {source.smbUsername ? `${source.smbUsername}${source.smbDomain ? ` @ ${source.smbDomain}` : ''}` : 'guest'}
                    </small>
                    <small>{source.hasSmbPassword ? 'Password saved' : 'Password missing'}</small>
                    <small>{source.tmdbApiKey ? 'TMDB key configured' : 'No TMDB key on source'}</small>
                  </div>
                  <span className={`device-state ${source.enabled ? 'online' : 'revoked'}`}>
                    {source.enabled ? 'enabled' : 'disabled'}
                  </span>
                </div>
                <p>Households: {source.assignments.map(item => item.householdName).join(', ')}</p>
                <div className="device-actions">
                  <button className="secondary" type="button" onClick={() => editSource(source)}>
                    Edit source
                  </button>
                  <button className="secondary" type="button" onClick={() => browseSource(source.key)}>
                    {browsingSourceKey === source.key ? 'Browsing…' : 'Browse folders'}
                  </button>
                  <button className="secondary" type="button" onClick={() => removeSource(source)}>
                    Remove source
                  </button>
                </div>
              </article>
            ))
          )}
        </div>
      </section>

      <section className="panel">
        <h3>Step 2 — Build libraries from source folders</h3>
        <form className="source-card" onSubmit={saveLibrary}>
          <div className="inline-fields">
            <label>
              Library name
              <input
                required
                placeholder="Movies"
                value={libraryEditor.name}
                onChange={event => setLibraryEditor(current => ({ ...current, name: event.target.value }))}
              />
            </label>
            <label>
              Directory type
              <select
                value={libraryEditor.mediaKind}
                onChange={event => setLibraryEditor(current => ({ ...current, mediaKind: event.target.value }))}
              >
                <option value="movie">Movies</option>
                <option value="series">Series</option>
                <option value="home_video">Family videos</option>
                <option value="live_show">Live shows</option>
                <option value="other">Other</option>
                <option value="auto">Auto detect</option>
              </select>
            </label>
          </div>
          <div>
            <strong>Select source</strong>
            <div className="inline-fields">
              <label>
                Source
                <select
                  value={libraryEditor.selectedSourceKey}
                  onChange={event =>
                    setLibraryEditor(current => ({
                      ...current,
                      selectedSourceKey: event.target.value,
                      selectedDirectoryPath: '',
                    }))
                  }
                >
                  <option value="">Choose source…</option>
                  {sources.map(source => (
                    <option key={`source-picker-${source.key}`} value={source.key}>
                      {source.name} — {source.rootPath}
                    </option>
                  ))}
                </select>
              </label>
              <button
                type="button"
                className="secondary"
                disabled={!libraryEditor.selectedSourceKey || browsingSourceKey === libraryEditor.selectedSourceKey}
                onClick={() => browseSource(libraryEditor.selectedSourceKey)}
              >
                {browsingSourceKey === libraryEditor.selectedSourceKey ? 'Browsing…' : 'Browse folders'}
              </button>
            </div>
          </div>

          {selectedSources.map(source => (
            <div className="source-card" key={`browse-${source.key}`}>
              <strong>{source.name}</strong>
              <div className="inline-fields">
                <label>
                  Directory
                  <select
                    value={libraryEditor.selectedDirectoryPath}
                    onChange={event =>
                      setLibraryEditor(current => ({
                        ...current,
                        selectedDirectoryPath: event.target.value,
                      }))
                    }
                  >
                    <option value="">Choose folder…</option>
                    {(browseEntriesBySource[source.key] ?? []).map(entry => (
                      <option key={entry.path} value={entry.path}>
                        {entry.name} — {entry.path}
                      </option>
                    ))}
                  </select>
                </label>
                <button type="button" className="secondary" onClick={addSelectedDirectory}>
                  Add selected folder
                </button>
              </div>
            </div>
          ))}

          <div className="inline-fields">
            <label>
              Manual directory path (optional)
              <input
                placeholder="smb://server/share/Movies/Action"
                value={libraryEditor.manualPath}
                onChange={event => setLibraryEditor(current => ({ ...current, manualPath: event.target.value }))}
              />
            </label>
            <button type="button" className="secondary" onClick={addManualDirectory}>Add path</button>
          </div>

          {libraryEditor.selectedDirectories.length > 0 && (
            <div>
              <p>Selected directories: {libraryEditor.selectedDirectories.length}</p>
              <div className="page-stack">
                {libraryEditor.selectedDirectories.map(item => (
                  <div className="source-card" key={item.key}>
                    <small>{item.path}</small>
                    <button
                      type="button"
                      className="secondary"
                      onClick={() =>
                        setLibraryEditor(current => ({
                          ...current,
                          selectedDirectories: current.selectedDirectories.filter(value => value.key !== item.key),
                        }))
                      }
                    >
                      Remove
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}

          <div>
            <strong>Household access</strong>
            <div className="inline-fields">
              {households.map(household => (
                <label key={`library-household-${household.id}`}>
                  <input
                    type="checkbox"
                    checked={libraryEditor.selectedHouseholds.includes(household.id)}
                    onChange={event =>
                      setLibraryEditor(current => ({
                        ...current,
                        selectedHouseholds: event.target.checked
                          ? [...current.selectedHouseholds, household.id]
                          : current.selectedHouseholds.filter(value => value !== household.id),
                      }))
                    }
                  />{' '}
                  {household.name}
                </label>
              ))}
            </div>
          </div>
          <div className="device-actions">
            <button disabled={savingLibrary}>{savingLibrary ? 'Saving…' : 'Save library'}</button>
            <button type="button" className="secondary" onClick={resetLibraryEditor}>New library</button>
          </div>
        </form>
      </section>

      <section className="panel">
        <div className="sources-toolbar">
          <h3>Configured libraries</h3>
          <button className="secondary" onClick={load} disabled={loading}>
            {loading ? 'Refreshing…' : 'Refresh'}
          </button>
        </div>
        {libraries.length === 0 ? (
          <p className="empty">No libraries configured yet.</p>
        ) : (
          <div className="page-stack">
            {libraries.map(library => (
              <article className="source-card" key={library.key}>
                <strong>{library.name}</strong>
                <p>Type: {library.mediaKind || 'auto'}</p>
                <p>Directories: {library.directories.length}</p>
                <p>Households: {library.households.join(', ')}</p>
              </article>
            ))}
          </div>
        )}
      </section>
    </section>
  );
}
