import { useState } from 'react';
import { Section } from './fields.jsx';
import ConfirmIdentity from './ConfirmIdentity.jsx';
import RecoveryCodes from './RecoveryCodes.jsx';
import { relativeTime } from './notificationsModel.js';
import { createPasskey, passkeysSupported, suggestedPasskeyName } from '../../lib/webauthn.js';
import { formatDate } from '../../lib/preferences.js';

/**
 * Password, two-step sign-in and passkeys  (Settings, Phase C)
 *
 * Shown at the top of Settings → Sign-in & devices. Every change that lowers
 * protection asks "confirm it's you" first; every change is recorded under
 * Recent changes and confirmed by email.
 */

const detail = (cause, fallback) => cause?.detail ?? cause?.message ?? fallback;

/* ------------------------------------------------------------------ *
 * Password
 * ------------------------------------------------------------------ */

export function PasswordSection({ security, overview, announce, reload }) {
  const [open, setOpen] = useState(false);
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [repeat, setRepeat] = useState('');
  const [signOutOthers, setSignOutOthers] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const mismatch = repeat.length > 0 && next !== repeat;
  const tooShort = next.length > 0 && next.length < 12;

  const reset = () => {
    setOpen(false);
    setCurrent('');
    setNext('');
    setRepeat('');
    setError(null);
  };

  const submit = async (event) => {
    event.preventDefault();
    if (mismatch || tooShort) return;
    setBusy(true);
    setError(null);
    try {
      const result = await security.changePassword({ currentPassword: current, newPassword: next, signOutOthers });
      reset();
      announce(
        result.signedOut > 0
          ? `Password changed. ${result.signedOut} other ${result.signedOut === 1 ? 'device was' : 'devices were'} signed out.`
          : 'Password changed.',
      );
      reload();
    } catch (cause) {
      setError(detail(cause, 'The password was not changed.'));
    } finally {
      setBusy(false);
    }
  };

  const changed = overview.password.changedAt;

  return (
    <Section
      id="password"
      title="Password"
      hint={changed ? `Last changed ${relativeTime(changed) || formatDate(changed)}.` : 'At least 12 characters. Length matters more than symbols.'}
    >
      {!open ? (
        <button type="button" className="btn" onClick={() => setOpen(true)}>
          Change password
        </button>
      ) : (
        <form className="st-form" onSubmit={submit}>
          <label className="st-label">
            Current password
            <input className="st-input__field" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} required autoFocus />
          </label>
          <label className="st-label">
            New password
            <input className="st-input__field" type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} required minLength={12} aria-invalid={tooShort} />
            {tooShort ? <span className="st-hint">At least 12 characters.</span> : null}
          </label>
          <label className="st-label">
            New password again
            <input className="st-input__field" type="password" autoComplete="new-password" value={repeat} onChange={(e) => setRepeat(e.target.value)} required aria-invalid={mismatch} />
            {mismatch ? <span className="st-error">The two new passwords are not the same.</span> : null}
          </label>
          <label className="st-check-row">
            <input type="checkbox" className="st-check" checked={signOutOthers} onChange={(e) => setSignOutOthers(e.target.checked)} />
            <span>Sign out every other device</span>
          </label>
          {error ? <p className="st-error">{error}</p> : null}
          <div className="st-inline">
            <button type="submit" className="btn" disabled={busy || mismatch || tooShort || !current || !next}>
              {busy ? 'Saving…' : 'Change password'}
            </button>
            <button type="button" className="btn btn--tiny" onClick={reset} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Section>
  );
}

/* ------------------------------------------------------------------ *
 * Authenticator app and recovery codes
 * ------------------------------------------------------------------ */

export function TwoStepSection({ security, overview, announce, reload }) {
  // idle · confirm-setup · scanning · codes · confirm-disable · confirm-codes
  const [step, setStep] = useState('idle');
  const [setup, setSetup] = useState(null);
  const [code, setCode] = useState('');
  const [codes, setCodes] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const { twoStep } = overview;
  const appOn = twoStep.totp.enabled;
  const codeAllowed = twoStep.required;

  const done = () => {
    setStep('idle');
    setSetup(null);
    setCode('');
    setCodes(null);
    setError(null);
    reload();
  };

  const verify = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const result = await security.enableTotp(code);
      setCodes(result.recoveryCodes);
      setStep('codes');
      announce('Two-step sign-in is on.');
    } catch (cause) {
      setError(detail(cause, 'That code is not right.'));
      setCode('');
    } finally {
      setBusy(false);
    }
  };

  let body;
  if (step === 'confirm-setup') {
    body = (
      <ConfirmIdentity
        action="Continue"
        codeAllowed={codeAllowed}
        onCancel={done}
        onConfirm={async (confirmation) => {
          setSetup(await security.startTotpSetup(confirmation));
          setStep('scanning');
        }}
      />
    );
  } else if (step === 'scanning' && setup) {
    body = (
      <form className="st-totp" onSubmit={verify}>
        <ol className="st-steps">
          <li>Open an authenticator app on your phone (Google Authenticator, Microsoft Authenticator, 1Password, …).</li>
          <li>Scan this code, or enter the key by hand.</li>
          <li>Type the 6-digit code the app shows.</li>
        </ol>
        <div className="st-totp__pair">
          {setup.qr ? <img className="st-totp__qr" src={setup.qr} alt="QR code for your authenticator app" width={180} height={180} /> : null}
          <div className="st-totp__key">
            <span className="st-hint">Key</span>
            <code className="st-totp__secret">{setup.secret.replace(/(.{4})/g, '$1 ').trim()}</code>
            <a className="st-hint" href={setup.uri}>Open in an authenticator app on this device</a>
          </div>
        </div>
        <label className="st-label">
          Code from the app
          <input className="st-input__field st-code-input" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} placeholder="123456" autoFocus required />
        </label>
        {error ? <p className="st-error">{error}</p> : null}
        <div className="st-inline">
          <button type="submit" className="btn" disabled={busy || code.replace(/\s/g, '').length !== 6}>
            {busy ? 'Checking…' : 'Turn on'}
          </button>
          <button type="button" className="btn btn--tiny" onClick={done}>
            Cancel
          </button>
        </div>
      </form>
    );
  } else if (step === 'codes' && codes) {
    body = <RecoveryCodes codes={codes} onDone={done} />;
  } else if (step === 'confirm-disable') {
    body = (
      <ConfirmIdentity
        action="Remove the app"
        danger
        codeAllowed={codeAllowed}
        onCancel={done}
        onConfirm={async (confirmation) => {
          await security.disableTotp(confirmation);
          announce('The authenticator app was removed.');
          done();
        }}
      />
    );
  } else if (step === 'confirm-codes') {
    body = (
      <ConfirmIdentity
        action="Make new codes"
        codeAllowed={codeAllowed}
        onCancel={done}
        onConfirm={async (confirmation) => {
          const result = await security.regenerateRecoveryCodes(confirmation);
          setCodes(result.recoveryCodes);
          setStep('codes');
        }}
      />
    );
  } else {
    body = (
      <>
        <p>
          {appOn
            ? `On since ${formatDate(twoStep.totp.enabledAt)}. Signing in needs your password and a code from the app.`
            : 'Off. With it on, a stolen password alone cannot sign in to your account.'}
        </p>
        <div className="st-inline">
          {appOn ? (
            <button type="button" className="btn btn--tiny" onClick={() => setStep('confirm-disable')}>
              Remove the app
            </button>
          ) : (
            <button type="button" className="btn" onClick={() => setStep('confirm-setup')}>
              Set up an authenticator app
            </button>
          )}
        </div>
        {twoStep.required ? (
          <div className="st-inline">
            <span className={twoStep.recoveryCodesRemaining <= 2 ? 'st-error' : 'st-hint'}>
              {twoStep.recoveryCodesRemaining} recovery {twoStep.recoveryCodesRemaining === 1 ? 'code' : 'codes'} left.
            </span>
            <button type="button" className="btn btn--tiny" onClick={() => setStep('confirm-codes')}>
              Make new recovery codes
            </button>
          </div>
        ) : null}
      </>
    );
  }

  return (
    <Section id="two-step" title="Two-step sign-in" hint="A code from your phone in addition to your password.">
      {body}
    </Section>
  );
}

/* ------------------------------------------------------------------ *
 * Passkeys
 * ------------------------------------------------------------------ */

export function PasskeySection({ security, overview, announce, reload }) {
  const [step, setStep] = useState('idle'); // idle · confirm-add · codes · remove:<id>
  const [codes, setCodes] = useState(null);
  const [renaming, setRenaming] = useState(null);
  const [error, setError] = useState(null);

  const { passkeys, twoStep } = overview;
  const supported = passkeysSupported();

  const done = () => {
    setStep('idle');
    setCodes(null);
    setError(null);
    reload();
  };

  const add = async (confirmation) => {
    const { optionsId, options } = await security.passkeyRegistrationOptions(confirmation);
    const response = await createPasskey(options);
    const result = await security.addPasskey({ optionsId, response, name: suggestedPasskeyName() });
    announce(`Passkey "${result.passkey.name}" added.`);
    if (result.recoveryCodes?.length) {
      setCodes(result.recoveryCodes);
      setStep('codes');
    } else {
      done();
    }
  };

  const rename = async (passkey, name) => {
    setRenaming(null);
    if (!name.trim() || name.trim() === passkey.name) return;
    try {
      await security.renamePasskey(passkey.id, name.trim());
      reload();
    } catch (cause) {
      setError(detail(cause, 'The passkey was not renamed.'));
    }
  };

  let hint = 'Sign in with your fingerprint, face or device PIN — no password, nothing to phish.';
  if (!passkeys.available) hint = 'Passkeys are not set up on the server yet.';
  else if (!supported) hint = 'This browser cannot create passkeys.';

  const removing = step.startsWith('remove:') ? step.slice(7) : null;

  return (
    <Section id="passkeys" title="Passkeys" hint={hint}>
      {step === 'codes' && codes ? <RecoveryCodes codes={codes} onDone={done} /> : null}

      {passkeys.items.map((passkey) => (
        <div key={passkey.id} className="st-session">
          <div className="st-session__info">
            {renaming === passkey.id ? (
              <input
                className="st-input__field"
                defaultValue={passkey.name}
                maxLength={60}
                autoFocus
                aria-label="Passkey name"
                onBlur={(event) => rename(passkey, event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') event.currentTarget.blur();
                  if (event.key === 'Escape') setRenaming(null);
                }}
              />
            ) : (
              <span className="st-label">
                {passkey.name}
                {passkey.backedUp ? <span className="st-badge">Synced</span> : null}
              </span>
            )}
            <span className="st-hint">
              Added {formatDate(passkey.createdAt)}
              {passkey.lastUsedAt ? ` · last used ${relativeTime(passkey.lastUsedAt)}` : ' · not used yet'}
            </span>
          </div>
          {removing === passkey.id ? null : (
            <span className="st-inline">
              <button type="button" className="btn btn--tiny" onClick={() => setRenaming(passkey.id)}>
                Rename
              </button>
              <button type="button" className="btn btn--tiny" onClick={() => setStep(`remove:${passkey.id}`)}>
                Remove…
              </button>
            </span>
          )}
          {removing === passkey.id ? (
            <ConfirmIdentity
              action="Remove passkey"
              danger
              codeAllowed={twoStep.required}
              onCancel={done}
              onConfirm={async (confirmation) => {
                await security.removePasskey(passkey.id, confirmation);
                announce(`Passkey "${passkey.name}" removed.`);
                done();
              }}
            />
          ) : null}
        </div>
      ))}

      {step === 'confirm-add' ? (
        <ConfirmIdentity action="Continue" codeAllowed={twoStep.required} onCancel={done} onConfirm={add} />
      ) : passkeys.available && supported && step === 'idle' ? (
        <button type="button" className="btn" onClick={() => setStep('confirm-add')}>
          Add a passkey
        </button>
      ) : null}
      {error ? <p className="st-error">{error}</p> : null}
    </Section>
  );
}
