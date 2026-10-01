import { useState } from 'react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import AuthShell from '../components/Auth/AuthShell.jsx';
import { STRENGTH_WORDS, destinationOf, passwordStrength, validateSignup, withNext } from '../components/Auth/authModel.js';

/**
 * Create an account  (Landing)
 *
 * Three fields, and you are in: the account starts signed in (a verification
 * email is sent alongside), with your time zone and language taken from this
 * browser — both can be changed in Settings. After that it continues to
 * ?next= (for example the room editor from "Create this room" on the
 * homepage), or to the dashboard.
 */
export default function SignupPage() {
  const { signUp, status } = useCore();
  const navigate = useNavigate();
  const location = useLocation();

  const [form, setForm] = useState({ displayName: '', email: '', password: '' });
  const [reveal, setReveal] = useState(false);
  const [touched, setTouched] = useState(false);
  const [error, setError] = useState(null);
  const [exists, setExists] = useState(false);
  const [busy, setBusy] = useState(false);

  const destination = destinationOf({ search: location.search, state: location.state });

  if (status === 'authenticated') {
    return <Navigate to={destination} replace />;
  }

  const errors = validateSignup(form);
  const shown = touched ? errors : {};
  const strength = passwordStrength(form.password);
  const set = (field) => (event) => setForm((current) => ({ ...current, [field]: event.target.value }));

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length > 0) return;
    setBusy(true);
    setError(null);
    setExists(false);
    try {
      await signUp({
        displayName: form.displayName.trim(),
        email: form.email.trim(),
        password: form.password,
      });
      navigate(destination, { replace: true });
    } catch (cause) {
      if (cause?.status === 409 || cause?.code === 'conflict') setExists(true);
      setError(cause?.detail ?? cause?.message ?? 'The account could not be created. Try again.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthShell
      title="Create your account"
      lead="Plan rooms, join lessons and meet your class. It takes a minute."
      footer={
        <>
          <p>
            Already have an account? <Link to={withNext('/login', destination)}>Sign in</Link>
          </p>
          <p>
            <Link to="/">Back to the homepage</Link>
          </p>
        </>
      }
    >
      <form className="au-form" onSubmit={submit} noValidate>
        <label className="au-field">
          <span className="au-label">Your name</span>
          <input
            className="au-input"
            autoComplete="name"
            value={form.displayName}
            onChange={set('displayName')}
            maxLength={80}
            aria-invalid={Boolean(shown.displayName)}
            autoFocus
          />
          {shown.displayName ? <span className="au-hint">{shown.displayName}</span> : <span className="au-hint">How others see you in lessons and chats.</span>}
        </label>

        <label className="au-field">
          <span className="au-label">Email</span>
          <input
            className="au-input"
            type="email"
            autoComplete="email"
            value={form.email}
            onChange={set('email')}
            aria-invalid={Boolean(shown.email)}
          />
          {shown.email ? <span className="au-hint">{shown.email}</span> : null}
        </label>

        <label className="au-field">
          <span className="au-label">Password</span>
          <span className="au-input-wrap">
            <input
              className="au-input"
              type={reveal ? 'text' : 'password'}
              autoComplete="new-password"
              value={form.password}
              onChange={set('password')}
              aria-invalid={Boolean(shown.password)}
              aria-describedby="au-strength"
            />
            <button type="button" className="au-reveal" onClick={() => setReveal((v) => !v)} aria-pressed={reveal}>
              {reveal ? 'Hide' : 'Show'}
            </button>
          </span>
          <span className="au-meter" data-level={strength} aria-hidden="true">
            <i />
            <i />
            <i />
            <i />
          </span>
          <span className="au-hint" id="au-strength">
            {shown.password ?? (form.password ? STRENGTH_WORDS[strength] : 'At least 12 characters. A short sentence works well.')}
          </span>
        </label>

        {error ? (
          <p className="au-alert au-alert--error" role="alert">
            {error} {exists ? <Link to={withNext('/login', destination)}>Sign in instead</Link> : null}
          </p>
        ) : null}

        <button type="submit" className="au-button au-button--primary" disabled={busy}>
          {busy ? 'Creating your account…' : 'Create account'}
        </button>
      </form>
    </AuthShell>
  );
}
