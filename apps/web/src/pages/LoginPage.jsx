import { useState } from 'react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import AuthShell from '../components/Auth/AuthShell.jsx';
import { destinationOf, withNext } from '../components/Auth/authModel.js';
import { passkeysSupported, signWithPasskey } from '../lib/webauthn.js';

/**
 * Sign in  (F5 · Settings Phase C · Landing)
 *
 * CoreProvider owns the session; this is one of the two screens that asks it
 * to start one (the other is sign-up). The access token never reaches this
 * component.
 *
 * The second step (Phase C) is unchanged: for an account with two-step
 * sign-in, signIn() throws SecondFactorRequired and this page asks for a code
 * from the authenticator app, a recovery code, or a passkey. "Sign in with a
 * passkey" skips the password entirely.
 *
 * Afterwards it returns to ?next=, to where the visitor was sent from, or to
 * the dashboard — only ever to a path inside the app.
 */
export default function LoginPage() {
  const { signIn, completeSignIn, passkeyOptions, signInWithPasskey, status } = useCore();
  const navigate = useNavigate();
  const location = useLocation();

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [reveal, setReveal] = useState(false);
  const [challenge, setChallenge] = useState(null);
  const [code, setCode] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  const destination = destinationOf({ search: location.search, state: location.state });
  const reason = location.state?.reason;

  if (status === 'authenticated') {
    return <Navigate to={destination} replace />;
  }

  const finish = () => navigate(destination, { replace: true });

  const run = async (action) => {
    setBusy(true);
    setError(null);
    try {
      await action();
    } finally {
      setBusy(false);
    }
  };

  const handlePassword = (event) => {
    event.preventDefault();
    run(async () => {
      try {
        await signIn({ email: email.trim(), password });
        finish();
      } catch (cause) {
        if (cause?.secondFactorRequired) {
          setChallenge({ id: cause.challengeId, methods: cause.methods });
          setUseRecovery(!cause.methods.includes('totp') && !cause.methods.includes('passkey'));
          setPassword('');
          return;
        }
        // The server deliberately does not say which half was wrong.
        setError(cause?.detail ?? 'Email or password is incorrect.');
      }
    });
  };

  const handleCode = (event) => {
    event.preventDefault();
    run(async () => {
      try {
        await completeSignIn({ challengeId: challenge.id, code });
        finish();
      } catch (cause) {
        setCode('');
        const detail = cause?.detail ?? 'That code is not right.';
        setError(detail);
        // Too many wrong codes or too slow: the password has to be entered again.
        if (/password again|took too long/i.test(detail)) setChallenge(null);
      }
    });
  };

  const handlePasskey = (challengeId = null) =>
    run(async () => {
      try {
        const { optionsId, options } = await passkeyOptions({ challengeId });
        const response = await signWithPasskey(options);
        await signInWithPasskey({ challengeId, optionsId, response });
        finish();
      } catch (cause) {
        setError(cause?.detail ?? cause?.message ?? 'The passkey was not accepted.');
      }
    });

  const canUsePasskeys = passkeysSupported();

  if (challenge) {
    const hasApp = challenge.methods.includes('totp');
    const hasRecovery = challenge.methods.includes('recovery');
    const hasPasskey = challenge.methods.includes('passkey') && canUsePasskeys;
    const recoveryMode = useRecovery || !hasApp;

    return (
      <AuthShell
        title="Two-step sign-in"
        lead={hasPasskey ? 'Confirm with the passkey on this device, or enter a code.' : 'Enter the code from your authenticator app.'}
        footer={
          <button type="button" className="au-textbutton" onClick={() => { setChallenge(null); setError(null); setCode(''); }}>
            Use a different account
          </button>
        }
      >
        <form className="au-form" onSubmit={handleCode}>
          {hasPasskey ? (
            <>
              <button type="button" className="au-button au-button--primary" disabled={busy} onClick={() => handlePasskey(challenge.id)}>
                Use a passkey
              </button>
              {hasApp || hasRecovery ? <p className="au-or">or</p> : null}
            </>
          ) : null}

          {hasApp || hasRecovery ? (
            <>
              <label className="au-field">
                <span className="au-label">{recoveryMode ? 'Recovery code' : 'Code from your authenticator app'}</span>
                <input
                  className="au-input au-input--code"
                  inputMode={recoveryMode ? 'text' : 'numeric'}
                  autoComplete="one-time-code"
                  placeholder={recoveryMode ? 'abcd-efgh' : '123456'}
                  value={code}
                  onChange={(event) => setCode(event.target.value)}
                  maxLength={20}
                  required
                  autoFocus={!hasPasskey}
                />
              </label>
              <button type="submit" className={hasPasskey ? 'au-button au-button--ghost' : 'au-button au-button--primary'} disabled={busy || code.trim().length < 6}>
                {busy ? 'Checking…' : 'Continue'}
              </button>
            </>
          ) : null}

          {error ? (
            <p className="au-alert au-alert--error" role="alert">
              {error}
            </p>
          ) : null}

          {hasApp && hasRecovery ? (
            <button type="button" className="au-textbutton" onClick={() => { setUseRecovery((v) => !v); setCode(''); }}>
              {useRecovery ? 'Use the authenticator app instead' : 'Lost your phone? Use a recovery code'}
            </button>
          ) : null}
        </form>
      </AuthShell>
    );
  }

  return (
    <AuthShell
      title="Welcome back"
      lead="Sign in to your lessons, rooms and messages."
      footer={
        <>
          <p>
            New here? <Link to={withNext('/signup', destination)}>Create an account</Link>
          </p>
          <p>
            <Link to="/">Back to the homepage</Link>
          </p>
        </>
      }
    >
      <form className="au-form" onSubmit={handlePassword}>
        {reason === 'signed-out-remotely' ? (
          <p className="au-alert au-alert--info" role="status">
            This device was signed out from another device.
          </p>
        ) : null}

        <label className="au-field">
          <span className="au-label">Email</span>
          <input
            className="au-input"
            type="email"
            autoComplete="username webauthn"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            required
            autoFocus
          />
        </label>

        <label className="au-field">
          <span className="au-label">Password</span>
          <span className="au-input-wrap">
            <input
              className="au-input"
              type={reveal ? 'text' : 'password'}
              autoComplete="current-password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              required
            />
            <button type="button" className="au-reveal" onClick={() => setReveal((v) => !v)} aria-pressed={reveal}>
              {reveal ? 'Hide' : 'Show'}
            </button>
          </span>
        </label>

        {error ? (
          <p className="au-alert au-alert--error" role="alert">
            {error}
          </p>
        ) : null}

        <button type="submit" className="au-button au-button--primary" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>

        {canUsePasskeys ? (
          <>
            <p className="au-or">or</p>
            <button type="button" className="au-button au-button--ghost" disabled={busy} onClick={() => handlePasskey(null)}>
              Sign in with a passkey
            </button>
          </>
        ) : null}
      </form>
    </AuthShell>
  );
}
