import { useEffect, useMemo, useRef, useState } from 'react';
import { createUsernameApi, useCore } from '@classroom/core-client';
import { usernameProblem } from '../Auth/authModel.js';

/**
 * Choose or change your username  (Sign in with a username)
 *
 * Opened from the profile menu. Checks while typing whether the name is free;
 * once saved, the name works on the sign-in page instead of the email.
 */
export default function UsernameDialog({ current, onClose, onSaved }) {
  const { http } = useCore();
  const api = useMemo(() => createUsernameApi(http), [http]);
  const [value, setValue] = useState(current ?? '');
  const [check, setCheck] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const dialogRef = useRef(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    dialog?.showModal?.();
    return () => dialog?.close?.();
  }, []);

  const name = value.trim().toLowerCase();
  const local = name ? usernameProblem(name) : null;

  useEffect(() => {
    if (!name || local || name === current) {
      setCheck(null);
      return undefined;
    }
    setCheck('checking');
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      api
        .available(name, controller.signal)
        .then(setCheck)
        .catch(() => !controller.signal.aborted && setCheck(null));
    }, 300);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [api, name, local, current]);

  const save = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const result = await api.set(name || null);
      onSaved(result.username);
    } catch (cause) {
      setError(cause?.detail ?? 'Not saved.');
      setBusy(false);
    }
  };

  const blocked = Boolean(local) || check === 'checking' || (check && !check.available) || name === (current ?? '');

  return (
    <dialog ref={dialogRef} className="app-dialog" onCancel={onClose} aria-labelledby="app-username-title">
      <form onSubmit={save} className="app-dialog__body">
        <h2 id="app-username-title">{current ? 'Change your username' : 'Choose a username'}</h2>
        <p className="muted">Sign in with it instead of your email. Letters a–z, digits, dot, hyphen and underscore; 3 to 30 characters.</p>
        <label className="app-dialog__field">
          <span>Username</span>
          <input
            value={value}
            onChange={(event) => setValue(event.target.value)}
            maxLength={30}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            autoFocus
            placeholder="e.g. anna.b"
            aria-invalid={Boolean(local || (check && check !== 'checking' && !check.available))}
          />
        </label>
        <p className="app-dialog__hint" aria-live="polite">
          {!name
            ? current
              ? 'Leave it empty and save to remove your username.'
              : ' '
            : local ??
              (check === 'checking' ? 'Checking…' : check ? (check.available ? `✓ ${name} is free` : check.problem) : name === current ? 'This is your current username.' : ' ')}
        </p>
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className="btn btn--primary" disabled={busy || (name ? blocked : !current)}>
            {busy ? 'Saving…' : name ? 'Save' : 'Remove username'}
          </button>
        </div>
      </form>
    </dialog>
  );
}
