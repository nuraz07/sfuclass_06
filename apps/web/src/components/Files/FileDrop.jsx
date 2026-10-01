import { useMemo, useRef, useState } from 'react';
import { createFilesApi, useCore } from '@classroom/core-client';
import { uploadFile } from '../../lib/files.js';
import { DEFAULT_ACCEPT, acceptAttribute, fileProblem, formatBytes } from './filesModel.js';
import './files.css';

/**
 * Drop files here, or choose them  (Files and Media)
 *
 * Several at once, each with its own progress: uploading → checking → ready,
 * or the reason it was refused (wrong format, too large, not really a PDF,
 * flagged by the virus scan). Used by Media and by a space's materials.
 */
export default function FileDrop({ onUploaded, accept = DEFAULT_ACCEPT, maxBytes = 50 * 1024 * 1024, compact = false, multiple = true }) {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const inputRef = useRef(null);
  const [over, setOver] = useState(false);
  const [queue, setQueue] = useState([]);

  const update = (id, patch) => setQueue((current) => current.map((item) => (item.id === id ? { ...item, ...patch } : item)));

  const start = (list) => {
    const chosen = [...list].slice(0, multiple ? 20 : 1);
    for (const file of chosen) {
      const id = `${file.name}-${file.size}-${Math.random().toString(36).slice(2)}`;
      const problem = fileProblem(file, { accept, maxBytes });
      setQueue((current) => [...current, { id, name: file.name, size: file.size, phase: problem ? 'refused' : 'starting', progress: 0, error: problem }]);
      if (problem) continue;
      uploadFile({
        files,
        file,
        onPhase: (phase) => update(id, { phase }),
        onProgress: (progress) => update(id, { progress }),
      })
        .then((ready) => {
          update(id, { phase: 'ready', progress: 1 });
          onUploaded?.(ready);
          window.setTimeout(() => setQueue((current) => current.filter((item) => item.id !== id)), 2500);
        })
        .catch((cause) => update(id, { phase: 'refused', error: cause.message }));
    }
  };

  const label = { starting: 'Preparing…', uploading: 'Uploading…', checking: 'Checking…', ready: 'Ready', refused: 'Not uploaded' };

  return (
    <div className={compact ? 'fl-drop is-compact' : 'fl-drop'}>
      <div
        className={over ? 'fl-drop__zone is-over' : 'fl-drop__zone'}
        role="button"
        tabIndex={0}
        aria-label="Upload files"
        onClick={() => inputRef.current?.click()}
        onKeyDown={(event) => (event.key === 'Enter' || event.key === ' ') && (event.preventDefault(), inputRef.current?.click())}
        onDragOver={(event) => {
          event.preventDefault();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={(event) => {
          event.preventDefault();
          setOver(false);
          start(event.dataTransfer.files);
        }}
      >
        <span className="fl-drop__icon" aria-hidden="true">⬆</span>
        <span className="fl-drop__text">
          <strong>{compact ? 'Upload a file' : 'Drop files here, or choose files'}</strong>
          <span>
            {accept.filter((ext) => ext !== 'jpeg').map((ext) => ext.toUpperCase()).join(', ')}, up to {formatBytes(maxBytes)} each
          </span>
        </span>
        <input
          ref={inputRef}
          type="file"
          hidden
          multiple={multiple}
          accept={acceptAttribute(accept)}
          onChange={(event) => {
            start(event.target.files);
            event.target.value = '';
          }}
        />
      </div>
      {queue.length ? (
        <ul className="fl-queue" aria-live="polite">
          {queue.map((item) => (
            <li key={item.id} className={`fl-queue__item is-${item.phase}`}>
              <span className="fl-queue__name">{item.name}</span>
              <span className="fl-queue__state">{item.phase === 'refused' ? item.error : label[item.phase]}</span>
              {item.phase !== 'refused' ? (
                <span className="fl-queue__bar" aria-hidden="true">
                  <i style={{ transform: `scaleX(${item.phase === 'checking' || item.phase === 'ready' ? 1 : item.progress})` }} />
                </span>
              ) : (
                <button type="button" className="fl-queue__dismiss" aria-label="Dismiss" onClick={() => setQueue((current) => current.filter((entry) => entry.id !== item.id))}>
                  ×
                </button>
              )}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
