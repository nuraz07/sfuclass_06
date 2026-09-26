import { useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import { passkeysSupported, signWithPasskey } from '../lib/webauthn.js';

/**
 * Sign in  (F5 · Settings Phase C)
 *
 * CoreProvider owns the session; this is the one screen that asks it to start
 * one. The access token never reaches this component.
 *
 * Phase C adds the second step. For an account with two-step sign-in the
 * password alone signs nobody in: signIn() throws SecondFactorRequired and
 * this page asks for a code from the authenticator app, a recovery code, or
 * a passkey. "Sign in with a passkey" on the first screen skips the password
 * entirely — the device checks fingerprint, face or PIN.
 */
export default function LoginPage() {
  const { signIn, completeSignIn, passkeyOptions, signInWithPasskey, status } = useCore();
  const navigate = useNavigate();
  const location = useLocation();

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [challenge, setChallenge] = useState(null);
  const [code, setCode] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  // Where they were headed before being bounced here, e.g. a room link from a
  // calendar invite. Landing on the dashboard instead would lose the lesson.
  const destination = location.state?.from ?? '/';
  const signedOutElsewhere = location.state?.reason === 'signed-out-remotely';

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
        await signIn({ email, password });
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

    return (
      <div className="join">
        <form className="card" onSubmit={handleCode}>
          <h1>Two-step sign-in</h1>

          {hasPasskey ? (
            <>
              <p>Confirm with the passkey on this device, or enter a code.</p>
              <button type="button" className="btn btn--primary" disabled={busy} onClick={() => handlePasskey(challenge.id)}>
                Use a passkey
              </button>
            </>
          ) : null}

          {hasApp || hasRecovery ? (
            <>
              <label htmlFor="code">
                {useRecovery || !hasApp ? 'Recovery code' : 'Code from your authenticator app'}
              </label>
              <input
                id="code"
                inputMode={useRecovery || !hasApp ? 'text' : 'numeric'}
                autoComplete="one-time-code"
                placeholder={useRecovery || !hasApp ? 'abcd-efgh' : '123 456'}
                value={code}
                onChange={(event) => setCode(event.target.value)}
                maxLength={20}
                required
                autoFocus={!hasPasskey}
              />
              <button type="submit" className="btn btn--primary" disabled={busy || code.trim().length < 6}>
                {busy ? 'Checking…' : 'Continue'}
              </button>
            </>
          ) : null}

          {error && (
            <p className="banner banner--warn" role="alert">
              {error}
            </p>
          )}

          {hasApp && hasRecovery ? (
            <button type="button" className="btn btn--link" onClick={() => { setUseRecovery((v) => !v); setCode(''); }}>
              {useRecovery ? 'Use the authenticator app instead' : 'Lost your phone? Use a recovery code'}
            </button>
          ) : null}
          <button type="button" className="btn btn--link" onClick={() => { setChallenge(null); setError(null); setCode(''); }}>
            Back
          </button>
        </form>
      </div>
    );
  }

  return (
    <div className="join">
      <form className="card" onSubmit={handlePassword}>
        <h1>Sign in</h1>

        {signedOutElsewhere ? (
          <p className="banner" role="status">
            This device was signed out from another device.
          </p>
        ) : null}

        <label htmlFor="email">Email</label>
        <input
          id="email"
          type="email"
          autoComplete="username webauthn"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          required
          autoFocus
        />

        <label htmlFor="password">Password</label>
        <input
          id="password"
          type="password"
          autoComplete="current-password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          required
        />

        {error && (
          <p className="banner banner--warn" role="alert">
            {error}
          </p>
        )}

        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>

        {canUsePasskeys ? (
          <button type="button" className="btn" disabled={busy} onClick={() => handlePasskey(null)}>
            Sign in with a passkey
          </button>
        ) : null}
      </form>
    </div>
  );
}
