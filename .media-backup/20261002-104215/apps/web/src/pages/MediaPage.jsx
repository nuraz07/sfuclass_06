import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { createFilesApi, useCore } from '@classroom/core-client';
import FileDrop from '../components/Files/FileDrop.jsx';
import { DEFAULT_ACCEPT, KIND_FILTERS, formatBytes, usagePercent } from '../components/Files/filesModel.js';
import LibraryItem from '../components/Library/LibraryItem.jsx';
import FilePreview from '../components/Library/FilePreview.jsx';
import { AddToSpaceDialog, DeleteFileDialog } from '../components/Library/LibraryDialogs.jsx';
import { SORTS, VIEWS, linksAreStale, neighbours, readQuery, sectionsOf, usageLevel, writeQuery } from '../components/Library/libraryModel.js';
import '../components/Library/library.css';

/**
 * Media — your own library  (Media)
 *
 * Everything you have uploaded, in one place: upload (same checks as in a
 * space's materials), find (search, type, sort, grid or list), look at it in
 * the preview panel, rename it, add it to one of your spaces, delete it.
 *
 * The state lives in the address bar (?q=&kind=&sort=&view=&file=), so a
 * reload, the back button or a bookmark brings back the same view. The data
 * comes from /files (files/FileService.js); every file link is signed and
 * lasts two hours, so the list reloads itself before links go stale.
 */
export default function MediaPage() {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const [params, setParams] = useSearchParams();
  const state = readQuery(params);

  const [library, setLibrary] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState(state.q);
  const [dialog, setDialog] = useState(null); // { type: 'add' | 'delete', file }
  const [notice, setNotice] = useState(null);
  const [usageVersion, setUsageVersion] = useState(0);
  const loadedAt = useRef(0);
  const requestRef = useRef(null);
  const noticeTimer = useRef(null);

  const update = useCallback(
    (patch, { replace = true } = {}) => setParams(writeQuery(readQuery(params), patch), { replace }),
    [params, setParams],
  );

  const load = useCallback(async () => {
    requestRef.current?.abort();
    const controller = new AbortController();
    requestRef.current = controller;
    setLoading(true);
    try {
      const result = await files.list({ q: state.q || undefined, kind: state.kind || undefined, sort: state.sort }, controller.signal);
      setLibrary(result);
      setError(null);
      loadedAt.current = Date.now();
    } catch (cause) {
      if (!controller.signal.aborted) setError(cause?.detail ?? 'Your files could not be loaded.');
    } finally {
      if (requestRef.current === controller) setLoading(false);
    }
  }, [files, state.q, state.kind, state.sort]);

  useEffect(() => {
    load();
  }, [load]);
  useEffect(() => () => requestRef.current?.abort(), []);

  // The search box writes to the address bar after a short pause.
  useEffect(() => {
    if (search === state.q) return undefined;
    const timer = window.setTimeout(() => update({ q: search.trim() }), 250);
    return () => window.clearTimeout(timer);
  }, [search]); // eslint-disable-line react-hooks/exhaustive-deps

  // Back/forward changes the address bar under the search box.
  useEffect(() => {
    setSearch((current) => (current.trim() === state.q ? current : state.q));
  }, [state.q]);

  // Signed links last two hours: coming back to a tab later reloads them.
  useEffect(() => {
    const onVisible = () => document.visibilityState === 'visible' && linksAreStale(loadedAt.current) && load();
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('focus', onVisible);
    return () => {
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('focus', onVisible);
    };
  }, [load]);

  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);
  const announce = (text) => {
    window.clearTimeout(noticeTimer.current);
    setNotice(text);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 5000);
  };

  const items = library?.items ?? [];
  const selected = state.file ? items.find((item) => item.fileId === state.file) ?? null : null;
  const { prev, next } = neighbours(items, selected?.fileId);
  const sections = useMemo(() => sectionsOf(items, state.sort), [items, state.sort]);
  const usage = library?.usage;
  const accept = library?.accept?.length ? library.accept : DEFAULT_ACCEPT;
  const filtered = Boolean(state.q || state.kind);
  const level = usage ? usageLevel(usage) : 'ok';

  // A file in the address bar that is not in the list closes the panel — or,
  // right after a delete, moves on to the file next to it.
  const afterDelete = useRef(null);
  useEffect(() => {
    if (library && state.file && !selected) update({ file: afterDelete.current });
    afterDelete.current = null;
  }, [library, state.file, selected]); // eslint-disable-line react-hooks/exhaustive-deps

  const select = useCallback((fileId) => update({ file: fileId === state.file ? null : fileId }), [update, state.file]);

  const replaceItem = (file) =>
    setLibrary((current) => (current ? { ...current, items: current.items.map((item) => (item.fileId === file.fileId ? { ...item, ...file } : item)) } : current));

  const rename = async (name) => {
    const renamed = await files.rename(selected.fileId, name);
    replaceItem(renamed);
    announce(`Renamed to ${renamed.name}.`);
    if (state.sort === 'name') load();
  };

  const deleted = (file) => {
    setDialog(null);
    const after = neighbours(items, file.fileId);
    afterDelete.current = after.next ?? after.prev ?? null;
    setLibrary((current) =>
      current
        ? {
            ...current,
            items: current.items.filter((item) => item.fileId !== file.fileId),
            usage: { ...current.usage, usedBytes: Math.max(0, current.usage.usedBytes - file.sizeBytes) },
          }
        : current,
    );
    announce(`${file.name} was deleted.`);
  };

  const addedToSpace = (file, choice) => {
    // Counted on the current item: several spaces can be added in one dialog.
    setLibrary((current) =>
      current
        ? { ...current, items: current.items.map((item) => (item.fileId === file.fileId ? { ...item, usedIn: (item.usedIn ?? 0) + 1 } : item)) }
        : current,
    );
    setUsageVersion((value) => value + 1);
    announce(`${file.name} is now a material in ${choice.name}.`);
  };

  const uploadedTimer = useRef(null);
  const uploaded = () => {
    // Several uploads finishing together reload the list once.
    window.clearTimeout(uploadedTimer.current);
    uploadedTimer.current = window.setTimeout(load, 300);
  };
  useEffect(() => () => window.clearTimeout(uploadedTimer.current), []);

  return (
    <section className={`page lb-page${selected ? ' has-preview' : ''}`}>
      <header className="lb-head">
        <div>
          <h1>Media</h1>
          <p className="lb-muted">Everything you have uploaded. Only you see this library; a file reaches others when you add it to a space.</p>
        </div>
        {usage ? (
          <div className={`lb-storage is-${level}`} role="group" aria-label="Storage">
            <div className="lb-storage__numbers">
              <strong>{formatBytes(usage.usedBytes)}</strong>
              <span className="lb-muted"> of {formatBytes(usage.quotaBytes)} used</span>
            </div>
            <div className="lb-storage__bar" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={usagePercent(usage)} aria-label="Storage used">
              <i style={{ transform: `scaleX(${usagePercent(usage) / 100})` }} />
            </div>
            {level !== 'ok' ? (
              <p className="lb-storage__hint">{level === 'full' ? 'Your storage is full. Delete files you no longer need to upload new ones.' : 'Your storage is almost full.'}</p>
            ) : null}
          </div>
        ) : null}
      </header>

      <FileDrop accept={accept} maxBytes={usage?.maxFileBytes ?? 50 * 1024 * 1024} compact={items.length > 0 || filtered} onUploaded={uploaded} />

      <div className="lb-toolbar" role="toolbar" aria-label="Find files">
        <input
          className="lb-search"
          type="search"
          placeholder="Search by name"
          aria-label="Search by name"
          value={search}
          maxLength={80}
          onChange={(event) => setSearch(event.target.value)}
        />
        <div className="lb-chips" role="radiogroup" aria-label="Type">
          {KIND_FILTERS.map((option) => (
            <button
              key={option.value || 'all'}
              type="button"
              role="radio"
              aria-checked={state.kind === option.value}
              className={state.kind === option.value ? 'lb-chip is-on' : 'lb-chip'}
              onClick={() => update({ kind: option.value })}
            >
              {option.label}
            </button>
          ))}
        </div>
        <div className="lb-toolbar__end">
          <label className="lb-sr" htmlFor="lb-sort">
            Sort
          </label>
          <select id="lb-sort" className="lb-select" value={state.sort} onChange={(event) => update({ sort: event.target.value })}>
            {SORTS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
          <div className="lb-segment" role="radiogroup" aria-label="View">
            {VIEWS.map((option) => (
              <button
                key={option.value}
                type="button"
                role="radio"
                aria-checked={state.view === option.value}
                className={state.view === option.value ? 'is-on' : ''}
                onClick={() => update({ view: option.value })}
                title={option.label}
              >
                <span aria-hidden="true">{option.value === 'grid' ? '▦' : '☰'}</span>
                <span className="lb-sr">{option.label}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="lb-layout">
        <div className="lb-main" aria-busy={loading}>
          {error ? (
            <div className="lb-empty">
              <p className="lb-error">{error}</p>
              <button type="button" className="btn" onClick={load}>
                Try again
              </button>
            </div>
          ) : null}
          {!error && library === null ? <p className="lb-muted">Loading your files…</p> : null}
          {!error && library && items.length === 0 ? (
            <div className="lb-empty">
              {filtered ? (
                <>
                  <p>No file matches.</p>
                  <button
                    type="button"
                    className="btn"
                    onClick={() => {
                      setSearch('');
                      update({ q: '', kind: '' });
                    }}
                  >
                    Show all files
                  </button>
                </>
              ) : (
                <>
                  <p className="lb-empty__title">Your library is empty</p>
                  <p className="lb-muted">Upload worksheets, slides, pictures or recordings above. From here you can add them to any of your spaces.</p>
                </>
              )}
            </div>
          ) : null}

          {sections.map((section) =>
            section.items.length ? (
              <div key={section.label ?? 'all'} className="lb-section">
                {section.label ? <h2 className="lb-section__label">{section.label}</h2> : null}
                <ul className={`lb-items lb-items--${state.view}`}>
                  {section.items.map((file) => (
                    <LibraryItem key={file.fileId} file={file} view={state.view} selected={file.fileId === selected?.fileId} onSelect={select} />
                  ))}
                </ul>
              </div>
            ) : null,
          )}
          {items.length >= 500 ? <p className="lb-muted">Showing the first 500 files. Search or filter to find older ones.</p> : null}
        </div>

        {selected ? (
          <>
            <button type="button" className="lb-scrim" aria-label="Close preview" onClick={() => update({ file: null })} />
            <FilePreview
              file={selected}
              files={files}
              usageVersion={usageVersion}
              onClose={() => update({ file: null })}
              onPrev={prev ? () => update({ file: prev }) : null}
              onNext={next ? () => update({ file: next }) : null}
              onRename={rename}
              onAddToSpace={() => setDialog({ type: 'add', file: selected })}
              onDelete={() => setDialog({ type: 'delete', file: selected })}
            />
          </>
        ) : null}
      </div>

      {dialog?.type === 'add' ? (
        <AddToSpaceDialog file={dialog.file} files={files} onClose={() => setDialog(null)} onAdded={(choice) => addedToSpace(dialog.file, choice)} />
      ) : null}
      {dialog?.type === 'delete' ? <DeleteFileDialog file={dialog.file} files={files} onClose={() => setDialog(null)} onDeleted={deleted} /> : null}

      {notice ? (
        <div className="lb-notice" role="status">
          {notice}
        </div>
      ) : null}
    </section>
  );
}
