import { useCallback, useEffect, useMemo, useState } from 'react';
import { createFilesApi, useCore } from '@classroom/core-client';
import FileDrop from '../Files/FileDrop.jsx';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { normalizeUrl } from './hubModel.js';

/**
 * Materials  (Community · Files)
 *
 * What a space keeps at hand: links to any website, and files — worksheets,
 * slides, pictures, recordings. Every member can add: paste a link, upload a
 * file, or pick one they uploaded before. Files open in a new tab (PDF,
 * pictures, video, audio, text) or download (Office documents). Moderators
 * pin; whoever added something, or a moderator, can remove it.
 */

function AddLink({ onAdd }) {
  const [title, setTitle] = useState('');
  const [url, setUrl] = useState('');
  const [error, setError] = useState(null);
  const normalized = normalizeUrl(url);
  return (
    <form
      className="hb-matadd__form"
      onSubmit={async (event) => {
        event.preventDefault();
        if (!title.trim() || !normalized) return;
        setError(null);
        try {
          await onAdd({ title: title.trim(), url: normalized });
          setTitle('');
          setUrl('');
        } catch (cause) {
          setError(cause?.detail ?? 'Not added.');
        }
      }}
    >
      <div className="hb-row2 hb-row2--even">
        <input className="hb-input" placeholder="Title, e.g. Fractions explained" maxLength={120} value={title} onChange={(event) => setTitle(event.target.value)} />
        <input className="hb-input" placeholder="Any web address, e.g. youtube.com/watch?v=…" maxLength={2000} value={url} onChange={(event) => setUrl(event.target.value)} aria-invalid={Boolean(url && !normalized)} />
      </div>
      {url && !normalized ? <p className="hb-error">That is not a web address.</p> : null}
      {error ? <p className="hb-error">{error}</p> : null}
      <div className="hb-inline">
        <button type="submit" className="btn btn--primary" disabled={!title.trim() || !normalized}>
          Add link
        </button>
      </div>
    </form>
  );
}

function FromLibrary({ onAdd }) {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const [items, setItems] = useState(null);
  const [q, setQ] = useState('');
  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      files
        .list({ q: q.trim() }, controller.signal)
        .then((result) => setItems(result.items))
        .catch(() => !controller.signal.aborted && setItems([]));
    }, 200);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [files, q]);
  return (
    <div className="hb-matadd__form">
      <input className="hb-input" type="search" placeholder="Search your uploads" value={q} onChange={(event) => setQ(event.target.value)} />
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? <p className="hb-muted">No uploads yet. Upload a file instead.</p> : null}
      <ul className="hb-pick">
        {(items ?? []).slice(0, 30).map((file) => (
          <li key={file.fileId}>
            <button type="button" onClick={() => onAdd({ fileId: file.fileId })}>
              <span aria-hidden="true">{iconFor(file.kind)}</span>
              <span className="hb-pick__name">{file.name}</span>
              <span className="hb-muted">{fileMeta(file)}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default function SpaceMaterials({ hub, space }) {
  const [data, setData] = useState(null);
  const [mode, setMode] = useState(null); // null · link · upload · library
  const [status, setStatus] = useState(null);

  const load = useCallback(async () => {
    try {
      setData(await hub.materials(space.spaceId));
    } catch {
      setData({ items: [], canCurate: false, canAdd: false });
    }
  }, [hub, space.spaceId]);

  useEffect(() => {
    load();
  }, [load]);

  const add = async (input) => {
    const added = await hub.addMaterial(space.spaceId, input);
    setStatus(`Added: ${added.title}`);
    setMode(null);
    await load();
  };

  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
  };

  return (
    <div>
      {data?.canAdd ? (
        <div className="hb-matadd">
          <div className="hb-segment" role="tablist" aria-label="Add a material">
            {[
              ['link', 'Link'],
              ['upload', 'Upload a file'],
              ['library', 'From my uploads'],
            ].map(([value, label]) => (
              <button key={value} type="button" role="tab" aria-selected={mode === value} className={mode === value ? 'is-on' : ''} onClick={() => setMode(mode === value ? null : value)}>
                {label}
              </button>
            ))}
          </div>
          {mode === 'link' ? <AddLink onAdd={add} /> : null}
          {mode === 'upload' ? (
            <FileDrop compact multiple={false} onUploaded={(file) => add({ fileId: file.fileId }).catch((cause) => setStatus(cause?.detail ?? 'Not added.'))} />
          ) : null}
          {mode === 'library' ? <FromLibrary onAdd={(input) => add(input).catch((cause) => setStatus(cause?.detail ?? 'Not added.'))} /> : null}
          {status ? <p className="hb-muted" role="status">{status}</p> : null}
        </div>
      ) : null}

      {data === null ? <p className="hb-muted">Loading…</p> : null}
      {data?.items.length === 0 ? <p className="hb-muted">No materials yet.{data.canAdd ? ' Add a link or a file above.' : ''}</p> : null}
      <ul className="hb-materials">
        {(data?.items ?? []).map((material) => {
          const isFile = material.type === 'file';
          const href = isFile ? fileHref(material.file?.openUrl) : material.url;
          const missing = isFile && !material.file?.available;
          return (
            <li key={material.materialId} className={material.pinned ? 'hb-material is-pinned' : 'hb-material'}>
              {missing ? (
                <span className="hb-material__link is-missing">
                  <span className="hb-material__icon" aria-hidden="true">🚫</span>
                  <span className="hb-material__text">
                    <span className="hb-material__title">{material.title}</span>
                    <span className="hb-muted">This file was deleted by its owner.</span>
                  </span>
                </span>
              ) : (
                <a className="hb-material__link" href={href} target="_blank" rel="noopener noreferrer">
                  <span className={`hb-material__icon hb-material__icon--${isFile ? material.file.kind : 'link'}`} aria-hidden="true">
                    {material.pinned ? '📌' : isFile ? iconFor(material.file.kind) : '🔗'}
                  </span>
                  <span className="hb-material__text">
                    <span className="hb-material__title">{material.title}</span>
                    <span className="hb-muted">
                      {isFile ? fileMeta(material.file) : material.host}
                      {material.addedBy ? `, added by ${material.addedBy}` : ''}
                      {material.note ? `: ${material.note}` : ''}
                    </span>
                  </span>
                  <span className="hb-material__open" aria-hidden="true">↗</span>
                </a>
              )}
              <span className="hb-inline">
                {data.canCurate ? (
                  <button type="button" className="hb-link" onClick={() => act(() => hub.pinMaterial(material.materialId, !material.pinned))}>
                    {material.pinned ? 'Unpin' : 'Pin'}
                  </button>
                ) : null}
                {material.canRemove ? (
                  <button type="button" className="hb-link hb-link--danger" onClick={() => window.confirm('Remove this material from the space?') && act(() => hub.removeMaterial(material.materialId))}>
                    Remove
                  </button>
                ) : null}
              </span>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
