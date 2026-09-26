import { useId, useState } from 'react';

/**
 * "Confirm it's you"  (Settings, Phase C)
 *
 * Asks for the password — or, with two-step sign-in on, lets someone use a
 * code instead — before a change that switches protection off or cannot be
 * undone. The server checks it again (security/confirmIdentity.js); this is
 * only the form.
 */
export default function ConfirmIdentity({ action, danger = false, codeAllowed = false, onConfirm, onCancel }) {
  const id = useId();
  const [mode, setMode] = useState('password');
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const submit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await onConfirm(mode === 'password' ? { password: value } : { code: value.trim() });
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'That did not work.');
      setValue('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="st-confirm" onSubmit={submit}>
      <label className="st-label" htmlFor={id}>
        {mode === 'password' ? 'Your password' : 'A code from your authenticator app, or a recovery code'}
      </label>
      <div className="st-inline">
        <input
          id={id}
          className="st-input__field"
          type={mode === 'password' ? 'password' : 'text'}
          autoComplete={mode === 'password' ? 'current-password' : 'one-time-code'}
          value={value}
          onChange={(event) => setValue(event.target.value)}
          autoFocus
          required
        />
        <button type="submit" className={danger ? 'btn btn--danger' : 'btn'} disabled={busy || !value}>
          {busy ? 'Checking…' : action}
        </button>
        <button type="button" className="btn btn--tiny" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
      </div>
      {codeAllowed ? (
        <button
          type="button"
          className="st-linkbutton"
          onClick={() => {
            setMode((current) => (current === 'password' ? 'code' : 'password'));
            setValue('');
            setError(null);
          }}
        >
          {mode === 'password' ? 'Use a code instead' : 'Use your password instead'}
        </button>
      ) : null}
      {error ? <p className="st-error">{error}</p> : null}
    </form>
  );
}
