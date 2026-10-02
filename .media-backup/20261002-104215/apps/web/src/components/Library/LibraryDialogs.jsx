import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { createHubApi, useCore } from '@classroom/core-client';
import { deleteConsequence, spaceChoices } from './libraryModel.js';

/**
 * The two dialogs of the Media library  (Media)
 *
 *   AddToSpaceDialog   the spaces I belong to; choosing one makes the file a
 *                      material there — the same call as "From my uploads" in
 *                      a space, so the same rules apply (posting paused, ended)
 *   DeleteFileDialog   says what a delete also removes before it happens
 *
 * Native <dialog>: focus stays inside, Esc closes, the page behind is inert.
 */

function useModal(onClose) {
  const ref = useRef(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog && !dialog.open) dialog.showModal?.();
    const onCancel = (event) => {
      event.preventDefault();
      onClose();
    };
    dialog?.addEventListener('cancel', onCancel);
    return () => dialog?.removeEventListener('cancel', onCancel);
  }, [onClose]);
  return ref;
}

export function AddToSpaceDialog({ file, files, onClose, onAdded }) {
  const { http } = useCore();
  const hub = useMemo(() => createHubApi(http), [http]);
  const ref = useModal(onClose);
  const [choices, setChoices] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(null);
  const [added, setAdded] = useState([]);

  useEffect(() => {
    const controller = new AbortController();
    Promise.all([hub.spaces({ scope: 'mine' }, controller.signal), files.usage(file.fileId, controller.signal)])
      .then(([spaces, usage]) => setChoices(spaceChoices(spaces.items, usage.items.map((entry) => entry.spaceId))))
      .catch(() => !controller.signal.aborted && setError('Your spaces could not be loaded. Try again.'));
    return () => controller.abort();
  }, [hub, files, file.fileId]);

  const add = async (choice) => {
    setBusy(choice.spaceId);
    setError(null);
    try {
      await hub.addMaterial(choice.spaceId, { fileId: file.fileId });
      setAdded((current) => [...current, choice.spaceId]);
      onAdded?.(choice);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not added.');
    } finally {
      setBusy(null);
    }
  };

  return (
    <dialog ref={ref} className="app-dialog lb-dialog" aria-labelledby="lb-add-title">
      <div className="app-dialog__body">
        <h2 id="lb-add-title">Add to a space</h2>
        <p className="lb-muted">
          <strong>{file.name}</strong> becomes a material there. Its members can open it; it stays yours, and deleting it here removes it there too.
        </p>
        {choices === null && !error ? <p className="lb-muted">Loading your spaces…</p> : null}
        {choices?.length === 0 ? (
          <p className="lb-muted">
            You are not in any space yet. <Link to="/community">Find or start one in Community.</Link>
          </p>
        ) : null}
        {choices?.length ? (
          <ul className="lb-spaces">
            {choices.map((choice) => {
              const done = added.includes(choice.spaceId);
              return (
                <li key={choice.spaceId}>
                  <span className="lb-spaces__emoji" aria-hidden="true">{choice.emoji ?? '◎'}</span>
                  <span className="lb-spaces__text">
                    <span className="lb-spaces__name">{choice.name}</span>
                    {done ? (
                      <span className="lb-ok">
                        Added · <Link to={`/community/spaces/${choice.spaceId}`}>open the space</Link>
                      </span>
                    ) : choice.unavailable ? (
                      <span className="lb-muted">{choice.unavailable}</span>
                    ) : null}
                  </span>
                  {!done && !choice.unavailable ? (
                    <button type="button" className="btn" disabled={busy !== null} onClick={() => add(choice)}>
                      {busy === choice.spaceId ? 'Adding…' : 'Add'}
                    </button>
                  ) : null}
                </li>
              );
            })}
          </ul>
        ) : null}
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn btn--primary" onClick={onClose}>
            Done
          </button>
        </div>
      </div>
    </dialog>
  );
}

export function DeleteFileDialog({ file, files, onClose, onDeleted }) {
  const ref = useModal(onClose);
  const [usage, setUsage] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    files
      .usage(file.fileId, controller.signal)
      .then((result) => setUsage(result.items))
      .catch(() => !controller.signal.aborted && setUsage([]));
    return () => controller.abort();
  }, [files, file.fileId]);

  const remove = async () => {
    setBusy(true);
    setError(null);
    try {
      await files.remove(file.fileId);
      onDeleted(file);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'The file was not deleted.');
      setBusy(false);
    }
  };

  return (
    <dialog ref={ref} className="app-dialog lb-dialog" aria-labelledby="lb-del-title">
      <div className="app-dialog__body">
        <h2 id="lb-del-title">Delete this file?</h2>
        <p>
          <strong>{file.name}</strong> is deleted for good.
        </p>
        <p className="lb-muted">{usage === null ? 'Checking where it is used…' : deleteConsequence(usage)}</p>
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button type="button" className="btn btn--danger" onClick={remove} disabled={busy || usage === null}>
            {busy ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>
    </dialog>
  );
}
