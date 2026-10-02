import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { fileMeta, formatBytes, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDate, formatTime } from '../../lib/preferences.js';
import { nameWithoutExt, openLabel, previewModeOf, renameProblem, usedInLabel } from './libraryModel.js';

/**
 * The preview panel  (Media)
 *
 * The selected file, as large as it fits: pictures, video, audio and plain
 * text right here; PDFs in their own tab; Office files and CSV as a download.
 * Below: its details, the spaces it is a material in, and what you can do —
 * open, add to a space, rename, delete. ← and → move through the visible
 * files, Esc closes.
 */

const TEXT_PREVIEW_BYTES = 64 * 1024;

function TextPreview({ href }) {
  const [text, setText] = useState(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    setText(null);
    setFailed(false);
    fetch(href, { headers: { Range: `bytes=0-${TEXT_PREVIEW_BYTES - 1}` }, signal: controller.signal })
      .then((response) => (response.ok ? response.text() : Promise.reject(new Error(String(response.status)))))
      .then(setText)
      .catch(() => !controller.signal.aborted && setFailed(true));
    return () => controller.abort();
  }, [href]);
  if (failed) return <p className="lb-preview__note">The text could not be loaded. Open the file instead.</p>;
  if (text === null) return <p className="lb-preview__note">Loading…</p>;
  return <pre className="lb-preview__text">{text}</pre>;
}

function Stage({ file }) {
  const href = file.openUrl ? fileHref(file.openUrl) : null;
  const mode = previewModeOf(file);
  if (!href) return <div className="lb-preview__stage"><p className="lb-preview__note">This file is not available.</p></div>;
  return (
    <div className={`lb-preview__stage lb-preview__stage--${mode}`}>
      {mode === 'image' ? <img src={href} alt={file.name} /> : null}
      {mode === 'video' ? <video src={href} controls preload="metadata" playsInline /> : null}
      {mode === 'audio' ? (
        <div className="lb-preview__audio">
          <span className="lb-preview__bigicon" aria-hidden="true">{iconFor('audio')}</span>
          <audio src={href} controls preload="metadata" />
        </div>
      ) : null}
      {mode === 'text' ? <TextPreview href={href} /> : null}
      {mode === 'pdf' || mode === 'download' ? (
        <div className="lb-preview__doc">
          <span className="lb-preview__bigicon" aria-hidden="true">{iconFor(file.kind)}</span>
          <span className="lb-preview__docext">{file.ext.toUpperCase()}</span>
          <a className="btn btn--primary" href={href} target="_blank" rel="noopener noreferrer">
            {openLabel(file)}
          </a>
        </div>
      ) : null}
    </div>
  );
}

function RenameField({ file, onRename }) {
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(nameWithoutExt(file));
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef(null);

  useEffect(() => {
    setEditing(false);
    setError(null);
    setValue(nameWithoutExt(file));
  }, [file.fileId, file.name]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (editing) inputRef.current?.select();
  }, [editing]);

  const save = async () => {
    const problem = renameProblem(value);
    if (problem) return setError(problem);
    if (value.trim() === nameWithoutExt(file)) return setEditing(false);
    setBusy(true);
    setError(null);
    try {
      await onRename(value.trim());
      setEditing(false);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not renamed.');
    } finally {
      setBusy(false);
    }
    return undefined;
  };

  if (!editing) {
    return (
      <div className="lb-preview__title">
        <h2 title={file.name}>{file.name}</h2>
        <button type="button" className="lb-textbtn" onClick={() => setEditing(true)}>
          Rename
        </button>
      </div>
    );
  }
  return (
    <form
      className="lb-rename"
      onSubmit={(event) => {
        event.preventDefault();
        save();
      }}
    >
      <label className="lb-sr" htmlFor={`rename-${file.fileId}`}>
        New name
      </label>
      <div className="lb-rename__field">
        <input
          id={`rename-${file.fileId}`}
          ref={inputRef}
          value={value}
          maxLength={180}
          disabled={busy}
          aria-invalid={Boolean(error)}
          onChange={(event) => setValue(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.stopPropagation();
              setEditing(false);
              setValue(nameWithoutExt(file));
              setError(null);
            }
          }}
        />
        <span className="lb-rename__ext">.{file.ext}</span>
      </div>
      <div className="lb-inline">
        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Saving…' : 'Save'}
        </button>
        <button type="button" className="btn" disabled={busy} onClick={() => setEditing(false)}>
          Cancel
        </button>
      </div>
      {error ? <p className="lb-error">{error}</p> : null}
    </form>
  );
}

export default function FilePreview({ file, files, usageVersion, onClose, onPrev, onNext, onRename, onAddToSpace, onDelete }) {
  const panelRef = useRef(null);
  const [usage, setUsage] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    setUsage(null);
    files
      .usage(file.fileId, controller.signal)
      .then((result) => setUsage(result.items))
      .catch(() => !controller.signal.aborted && setUsage([]));
    return () => controller.abort();
  }, [files, file.fileId, usageVersion]);

  // Keyboard: Esc closes, ← → move, unless someone is typing.
  useEffect(() => {
    const onKey = (event) => {
      const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName ?? '') || event.target?.isContentEditable;
      if (typing || event.defaultPrevented || document.querySelector('dialog[open]')) return;
      if (event.key === 'Escape') onClose();
      else if (event.key === 'ArrowLeft' && onPrev) onPrev();
      else if (event.key === 'ArrowRight' && onNext) onNext();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose, onPrev, onNext]);

  useEffect(() => {
    panelRef.current?.focus({ preventScroll: true });
  }, [file.fileId]);

  const href = file.openUrl ? fileHref(file.openUrl) : null;

  return (
    <aside className="lb-preview" aria-label={`Preview of ${file.name}`} tabIndex={-1} ref={panelRef}>
      <div className="lb-preview__bar">
        <div className="lb-inline">
          <button type="button" className="lb-iconbtn" onClick={onPrev} disabled={!onPrev} aria-label="Previous file" title="Previous (←)">
            ‹
          </button>
          <button type="button" className="lb-iconbtn" onClick={onNext} disabled={!onNext} aria-label="Next file" title="Next (→)">
            ›
          </button>
        </div>
        <button type="button" className="lb-iconbtn" onClick={onClose} aria-label="Close preview" title="Close (Esc)">
          ×
        </button>
      </div>

      <Stage file={file} />

      <div className="lb-preview__body">
        <RenameField file={file} onRename={onRename} />
        <p className="lb-muted">
          {fileMeta(file)}
          {file.createdAt ? ` · uploaded ${formatDate(file.createdAt)}, ${formatTime(file.createdAt)}` : ''}
        </p>

        <div className="lb-actions">
          {href ? (
            <a className="btn" href={href} target="_blank" rel="noopener noreferrer">
              {openLabel(file)}
            </a>
          ) : null}
          <button type="button" className="btn btn--primary" onClick={onAddToSpace}>
            Add to a space
          </button>
          <button type="button" className="btn lb-danger" onClick={onDelete}>
            Delete
          </button>
        </div>

        <section className="lb-usage" aria-live="polite">
          <h3>Used in</h3>
          {usage === null ? <p className="lb-muted">Loading…</p> : null}
          {usage?.length === 0 ? <p className="lb-muted">{usedInLabel(0)}. Add it to a space so its members can open it.</p> : null}
          {usage?.length ? (
            <ul>
              {usage.map((entry) => (
                <li key={entry.materialId}>
                  <Link to={`/community/spaces/${entry.spaceId}`}>
                    <span aria-hidden="true">{entry.emoji ?? '◎'}</span> {entry.spaceName}
                  </Link>
                  {entry.addedAt ? <span className="lb-muted"> · since {formatDate(entry.addedAt)}</span> : null}
                </li>
              ))}
            </ul>
          ) : null}
        </section>

        <dl className="lb-details">
          <dt>Type</dt>
          <dd>{file.ext.toUpperCase()}</dd>
          <dt>Size</dt>
          <dd>{formatBytes(file.sizeBytes)}</dd>
          <dt>Who can open it</dt>
          <dd>{usage?.length ? 'You, and the members of the spaces above' : 'Only you'}</dd>
        </dl>
      </div>
    </aside>
  );
}
