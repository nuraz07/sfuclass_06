import { useEffect, useRef, useState } from 'react';
import { REPORT_REASONS } from './messengerModel.js';

/**
 * Dialogs of the Messages page  (Messages)
 *
 * Native <dialog>: focus stays inside, Esc closes, the page behind is inert.
 */

export function useModal(onClose) {
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

/** "Are you sure?" with the consequence spelled out. */
export function ConfirmDialog({ title, body, confirmLabel, danger = false, onConfirm, onClose }) {
  const ref = useModal(onClose);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const confirm = async () => {
    setBusy(true);
    setError(null);
    try {
      await onConfirm();
      onClose();
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'That did not work. Try again.');
      setBusy(false);
    }
  };
  return (
    <dialog ref={ref} className="app-dialog mx-dialog" aria-labelledby="mx-confirm-title">
      <div className="app-dialog__body">
        <h2 id="mx-confirm-title">{title}</h2>
        {body ? <p>{body}</p> : null}
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button type="button" className={danger ? 'btn btn--danger' : 'btn btn--primary'} onClick={confirm} disabled={busy}>
            {busy ? 'One moment…' : confirmLabel}
          </button>
        </div>
      </div>
    </dialog>
  );
}

/** Report a person to the moderators of the organisation. */
export function ReportDialog({ person, profiles, onClose, onDone }) {
  const ref = useModal(onClose);
  const [reason, setReason] = useState('harassment');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const send = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await profiles.report({ userId: person.userId, reason, detail: note.trim() || undefined });
      onDone?.();
      onClose();
    } catch (cause) {
      setError(cause?.detail ?? 'The report was not sent. Try again.');
      setBusy(false);
    }
  };
  return (
    <dialog ref={ref} className="app-dialog mx-dialog" aria-labelledby="mx-report-title">
      <form className="app-dialog__body" onSubmit={send}>
        <h2 id="mx-report-title">Report {person.displayName}</h2>
        <p className="mx-muted">Moderators of your organisation see the report. {person.displayName} is not told who sent it.</p>
        <fieldset className="mx-radios">
          <legend className="mx-sr">Reason</legend>
          {REPORT_REASONS.map((option) => (
            <label key={option.value} className={reason === option.value ? 'is-on' : ''}>
              <input type="radio" name="reason" value={option.value} checked={reason === option.value} onChange={() => setReason(option.value)} />
              {option.label}
            </label>
          ))}
        </fieldset>
        <label className="app-dialog__field">
          What happened? (optional)
          <textarea value={note} maxLength={2000} rows={3} onChange={(event) => setNote(event.target.value)} />
        </label>
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button type="submit" className="btn btn--danger" disabled={busy}>
            {busy ? 'Sending…' : 'Send report'}
          </button>
        </div>
      </form>
    </dialog>
  );
}
