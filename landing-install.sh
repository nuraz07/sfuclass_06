#!/usr/bin/env bash
# landing-install.sh — Public homepage, sign-up, and a new sign-in page.
#
# Signed out:  "/" shows the homepage (what Classroom is, a room planner to
#              try, sign-in and sign-up); every other app page asks to sign in
#              and returns there afterwards.
# Signed in:   everything as before. The homepage stays reachable at /welcome.
#
# Run from the project folder:  bash landing-install.sh
# Writes 14 files, patches 3 more, backup in .landing-backup/<timestamp>/.
# Undo:                         bash landing-install.sh --restore
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/identity/signup.js
  apps/web/src/components/system/AuthGate.jsx
  apps/web/src/pages/LandingPage.jsx
  apps/web/src/pages/LoginPage.jsx
  apps/web/src/pages/SignupPage.jsx
  apps/web/src/components/Landing/landingModel.js
  apps/web/src/components/Landing/HeroDemo.jsx
  apps/web/src/components/Landing/RoomPlanner.jsx
  apps/web/src/components/Landing/landing.css
  apps/web/src/components/Landing/__checks__/landingModel.check.mjs
  apps/web/src/components/Auth/authModel.js
  apps/web/src/components/Auth/AuthShell.jsx
  apps/web/src/components/Auth/auth.css
  apps/web/src/components/Auth/__checks__/authModel.check.mjs
  server/src/routes/auth.routes.js
  packages/core-client/src/CoreProvider.tsx
  apps/web/src/main.jsx
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .landing-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  echo "Restored from $FIRST."
  exit 0
fi

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need packages/core-client/src/CoreProvider.tsx "completeSignIn" "Settings Phase C"
need packages/core-client/src/CoreProvider.tsx "const adopt = useCallback" "Settings Phase C"
need server/src/routes/auth.routes.js "function respondWithSession" "Settings Phase C"
need server/src/routes/auth.routes.js "const deviceSchema" "sign-in routes"
need apps/web/src/pages/LoginPage.jsx "completeSignIn" "Settings Phase C"
need apps/web/src/lib/webauthn.js "signWithPasskey" "Settings Phase C"
need apps/web/src/main.jsx "RoomLobbyPage" "the rooms feature"
need server/src/identity/AuthService.js "export const register" "sign-in"
need server/src/routes/_helpers.js "conflict" "routes"
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what the homepage update expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".landing-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/identity
cat > server/src/identity/signup.js <<'__LP_EOF__'
// classroom-app/server/src/identity/signup.js
/**
 * Creating an account from the homepage  (Landing)
 *
 * AuthService.register has always been able to create an account; nothing
 * exposed it. This decides the two things register() needs from outside:
 *
 *   may people sign up?   SIGNUP_MODE=open (default) or closed
 *   which organisation?   SIGNUP_TENANT_ID when set; otherwise the
 *                         organisation most people already belong to, so a
 *                         new account can join "anyone with the link" rooms
 *                         and find its classmates. With no users yet, the
 *                         first organisation there is.
 *
 * New accounts are always learners: a role is never chosen at sign-up.
 * Signing in looks accounts up by email across organisations, so an address
 * that exists anywhere is refused here — it could not be signed in to.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Users from './User.js';

const log = logger.child({ component: 'signup' });

const fail = (code, message) => {
  throw Object.assign(new Error(message), { code });
};

export const signupMode = () => (String(process.env.SIGNUP_MODE ?? 'open').trim().toLowerCase() === 'closed' ? 'closed' : 'open');

export const resolveSignupTenant = async () => {
  const pinned = process.env.SIGNUP_TENANT_ID?.trim();
  if (pinned) {
    const { rows } = await pool.query(`SELECT id FROM tenants WHERE id = $1`, [pinned]).catch(() => ({ rows: [] }));
    if (rows[0]) return rows[0].id;
    log.error({ tenantId: pinned }, 'SIGNUP_TENANT_ID does not name an organisation; falling back');
  }
  const { rows } = await pool.query(
    `SELECT tenant_id FROM users WHERE deleted_at IS NULL
      GROUP BY tenant_id ORDER BY count(*) DESC, tenant_id LIMIT 1`,
  );
  if (rows[0]) return rows[0].tenant_id;
  const first = await pool.query(`SELECT id FROM tenants LIMIT 1`);
  return first.rows[0]?.id ?? null;
};

const TIME_ZONES = new Set(Intl.supportedValuesOf('timeZone'));

/**
 * @returns the same as AuthService.login: { user, accessToken, refreshToken, sessionId, … }
 */
export const registerOpen = async ({ displayName, email, password, timeZone = null, locale = null, device }) => {
  if (signupMode() === 'closed') {
    fail('forbidden', 'New accounts cannot be created here. Ask your school or organisation for an invitation.');
  }

  const address = String(email).trim();
  if (await Users.findCredentials(address)) {
    fail('conflict', 'An account with this email already exists.');
  }

  const tenantId = await resolveSignupTenant();
  if (!tenantId) fail('validation_failed', 'Sign-up is not set up yet: there is no organisation to join.');

  const AuthService = await import('./AuthService.js');
  const result = await AuthService.register({
    tenantId,
    email: address,
    password,
    displayName: String(displayName).trim(),
    role: 'learner',
    locale: locale && /^[a-z]{2}(-[A-Z]{2})?$/.test(locale) ? locale : 'en',
    timeZone: timeZone && TIME_ZONES.has(timeZone) ? timeZone : 'UTC',
    device,
  });
  log.info({ userId: result.user?.userId, tenantId }, 'account created from the homepage');
  return result;
};

export default { registerOpen, resolveSignupTenant, signupMode };
__LP_EOF__
echo "wrote server/src/identity/signup.js"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/AuthGate.jsx <<'__LP_EOF__'
import { Suspense, lazy } from 'react';
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useCore } from '@classroom/core-client';

const LandingPage = lazy(() => import('../../pages/LandingPage.jsx'));

/**
 * The line between the homepage and the product  (Landing)
 *
 *   signed in       the app, exactly as before (everything under AppLayout)
 *   not signed in   "/"           the public homepage
 *                   anything else the sign-in page, which returns here after
 *   restoring       a short loading state, so nobody sees the homepage flash
 *                   while a session is being resumed
 *
 * The classroom, room lobbies and the sign-in pages sit outside this gate and
 * keep their own handling.
 */
export default function AuthGate() {
  const { status } = useCore();
  const location = useLocation();

  if (status === 'authenticated') return <Outlet />;
  if (status === 'restoring') return <p className="app app-empty">Loading…</p>;

  if (location.pathname === '/') {
    return (
      <Suspense fallback={<p className="app app-empty">Loading…</p>}>
        <LandingPage />
      </Suspense>
    );
  }
  return <Navigate to="/login" replace state={{ from: `${location.pathname}${location.search}` }} />;
}
__LP_EOF__
echo "wrote apps/web/src/components/system/AuthGate.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/LandingPage.jsx <<'__LP_EOF__'
import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import HeroDemo from '../components/Landing/HeroDemo.jsx';
import RoomPlanner from '../components/Landing/RoomPlanner.jsx';
import '../components/Landing/landing.css';

/**
 * The public homepage  (Landing)
 *
 * What someone sees before they have an account: what the product is, what
 * is inside, a room planner to try, and the way in. Nothing here needs the
 * API — it renders instantly and works while the server is starting.
 *
 * Shown at "/" to anyone who is not signed in (AuthGate), and at /welcome to
 * everyone. Signed-in visitors get "Open Classroom" instead of the sign-up
 * buttons.
 */

function Brand() {
  return (
    <span className="lp-brand">
      <svg className="lp-brand__mark" viewBox="0 0 32 32" aria-hidden="true">
        <rect x="3" y="6" width="26" height="18" rx="4" />
        <path d="M11 29h10M16 24v5" />
        <circle cx="23" cy="11" r="2.4" />
      </svg>
      Classroom
    </span>
  );
}

function Scene({ id, title, text, points, children, flip = false }) {
  return (
    <section className={flip ? 'lp-scene is-flipped' : 'lp-scene'} aria-labelledby={`lp-${id}`}>
      <div className="lp-scene__text">
        <h3 id={`lp-${id}`} className="lp-scene__title">
          {title}
        </h3>
        <p className="lp-scene__lead">{text}</p>
        <ul className="lp-scene__points">
          {points.map((point) => (
            <li key={point}>{point}</li>
          ))}
        </ul>
      </div>
      <div className="lp-scene__art" aria-hidden="true">
        {children}
      </div>
    </section>
  );
}

export default function LandingPage() {
  const { status } = useCore();
  const signedIn = status === 'authenticated';

  useEffect(() => {
    const previous = document.title;
    document.title = 'Classroom: live lessons, courses and community';
    return () => {
      document.title = previous;
    };
  }, []);

  return (
    <div className="lp">
      <a className="lp-skip" href="#lp-main">
        Skip to content
      </a>
      <header className="lp-nav">
        <Link to={signedIn ? '/' : '/welcome'} className="lp-nav__home" aria-label="Classroom home">
          <Brand />
        </Link>
        <nav className="lp-nav__links" aria-label="On this page">
          <a href="#inside">What’s inside</a>
          <a href="#plan">Plan a room</a>
          <a href="#privacy">Privacy</a>
        </nav>
        <div className="lp-nav__actions">
          {signedIn ? (
            <Link className="lp-button lp-button--primary lp-button--small" to="/">
              Open Classroom
            </Link>
          ) : (
            <>
              <Link className="lp-link" to="/login">
                Sign in
              </Link>
              <Link className="lp-button lp-button--primary lp-button--small" to="/signup">
                Create account
              </Link>
            </>
          )}
        </div>
      </header>

      <main id="lp-main">
        <section className="lp-hero" aria-labelledby="lp-hero-title">
          <div className="lp-hero__text">
            <h1 id="lp-hero-title" className="lp-hero__title">
              Live lessons that start the moment you do.
            </h1>
            <p className="lp-hero__lead">
              Plan a room, share one link, and the doors open a few minutes before you begin. Video, chat, courses and
              your community come with it.
            </p>
            <div className="lp-hero__actions">
              {signedIn ? (
                <Link className="lp-button lp-button--primary" to="/">
                  Open Classroom
                </Link>
              ) : (
                <>
                  <Link className="lp-button lp-button--primary" to="/signup">
                    Create account
                  </Link>
                  <Link className="lp-button lp-button--ghost" to="/login">
                    Sign in
                  </Link>
                </>
              )}
            </div>
            <p className="lp-hero__note">Runs in the browser. Nothing to install for you or your class.</p>
          </div>
          <HeroDemo />
        </section>

        <section id="inside" className="lp-section" aria-labelledby="lp-inside-title">
          <h2 id="lp-inside-title" className="lp-section__title">
            Everything a class needs, in one place
          </h2>

          <Scene
            id="live"
            title="A room that feels like a room"
            text="Video and sound tuned for teaching, with the controls a teacher actually reaches for."
            points={[
              'Share your screen, mute the room, let people react without interrupting',
              'Your microphone, camera and noise settings follow you to every lesson',
              'A lesson chat on the side, with private messages when someone needs one',
            ]}
          >
            <div className="lp-art lp-art--live">
              <span className="lp-art__tile lp-art__tile--sky is-speaking" />
              <span className="lp-art__tile lp-art__tile--mint" />
              <span className="lp-art__tile lp-art__tile--sun" />
              <span className="lp-art__tile lp-art__tile--rose" />
              <span className="lp-art__bar">
                <i />
                <i />
                <i />
                <i className="is-red" />
              </span>
            </div>
          </Scene>

          <Scene
            flip
            id="rooms"
            title="Doors that open on time"
            text="Rooms have a start, an end and doors. People wait in a lobby with a countdown and a camera check, not in an empty call."
            points={[
              'Doors open 3 to 10 minutes early; you can prepare 30 minutes before',
              'Seats with a waiting list: a freed seat is held for the next person',
              'Let people in yourself, one by one or all at once',
            ]}
          >
            <div className="lp-art lp-art--lobby">
              <p className="lp-art__big">4:59</p>
              <p className="lp-art__small">Doors open in</p>
              <p className="lp-art__knock">
                <span>Jonas wants to join</span>
                <b>Admit</b>
              </p>
            </div>
          </Scene>

          <Scene
            id="courses"
            title="Courses between the lessons"
            text="Lessons, materials and progress in one course, so the live hour builds on what came before."
            points={['Lessons in order, with progress you can see', 'Media library for slides, videos and documents', 'Reminders a day and ten minutes before']}
          >
            <div className="lp-art lp-art--course">
              {['Fractions', 'Decimals', 'Percentages', 'Revision'].map((name, index) => (
                <p key={name} className={index < 2 ? 'lp-art__lesson is-done' : index === 2 ? 'lp-art__lesson is-now' : 'lp-art__lesson'}>
                  <span>{name}</span>
                </p>
              ))}
              <span className="lp-art__progress">
                <i style={{ width: '55%' }} />
              </span>
            </div>
          </Scene>

          <Scene
            flip
            id="community"
            title="A community that keeps going"
            text="Spaces and threads for everything that does not fit into a lesson, and messages for the rest."
            points={['Spaces for each class, course or group', 'Private and group messages with read receipts you can switch off', 'Quiet hours and focus during lessons: nothing pings mid-sentence']}
          >
            <div className="lp-art lp-art--chat">
              <p className="lp-art__msg">Does anyone have the notes from Tuesday?</p>
              <p className="lp-art__msg is-mine">Uploaded them to the space 📎</p>
              <p className="lp-art__seen">Seen</p>
            </div>
          </Scene>
        </section>

        <section id="plan" className="lp-section lp-section--board" aria-labelledby="lp-plan-title">
          <div className="lp-section__head">
            <h2 id="lp-plan-title" className="lp-section__title">
              Try planning a room
            </h2>
            <p className="lp-section__lead">
              Move the controls. This is how it works inside, down to the minute the doors open for your guests.
            </p>
          </div>
          <RoomPlanner signedIn={signedIn} />
        </section>

        <section id="privacy" className="lp-section" aria-labelledby="lp-privacy-title">
          <div className="lp-section__head">
            <h2 id="lp-privacy-title" className="lp-section__title">
              You decide who reaches you
            </h2>
            <p className="lp-section__lead">Settings in plain language, with a check-up that tells you where you stand.</p>
          </div>
          <dl className="lp-facts">
            <div>
              <dt>Private messages</dt>
              <dd>Choose who may write to you. A block works everywhere, for everyone.</dd>
            </div>
            <div>
              <dt>Two-step sign-in</dt>
              <dd>An authenticator app or a passkey on your phone or laptop.</dd>
            </div>
            <div>
              <dt>Every device in view</dt>
              <dd>See where you are signed in and sign any device out at once.</dd>
            </div>
            <div>
              <dt>Your data, your copy</dt>
              <dd>Download everything as one file, or delete your account with 14 days to change your mind.</dd>
            </div>
          </dl>
        </section>

        <section className="lp-final" aria-labelledby="lp-final-title">
          <h2 id="lp-final-title" className="lp-final__title">
            Your next lesson could start in ten minutes.
          </h2>
          {signedIn ? (
            <Link className="lp-button lp-button--primary" to="/rooms/new">
              Plan a room
            </Link>
          ) : (
            <div className="lp-hero__actions">
              <Link className="lp-button lp-button--primary" to="/signup">
                Create account
              </Link>
              <Link className="lp-button lp-button--ghost" to="/login">
                Sign in
              </Link>
            </div>
          )}
        </section>
      </main>

      <footer className="lp-footer">
        <Brand />
        <nav aria-label="Footer">
          <a href="#inside">What’s inside</a>
          <a href="#plan">Plan a room</a>
          <a href="#privacy">Privacy</a>
          {signedIn ? <Link to="/">Open Classroom</Link> : <Link to="/login">Sign in</Link>}
        </nav>
        <p className="lp-footer__small">© {new Date().getFullYear()} Classroom</p>
      </footer>
    </div>
  );
}
__LP_EOF__
echo "wrote apps/web/src/pages/LandingPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/LoginPage.jsx <<'__LP_EOF__'
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
__LP_EOF__
echo "wrote apps/web/src/pages/LoginPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/SignupPage.jsx <<'__LP_EOF__'
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
__LP_EOF__
echo "wrote apps/web/src/pages/SignupPage.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/landingModel.js <<'__LP_EOF__'
/**
 * Pure helpers for the public homepage  (Landing)
 *
 * The room planner on the homepage uses the same rules as the real room
 * editor — doors 3 to 10 minutes before the start, hosts 30 minutes early —
 * so what a visitor tries here is what they get after signing up.
 * No React, no network: tested in __checks__/landingModel.check.mjs.
 */

export const DOORS = Object.freeze({ min: 3, max: 10, default: 5 });
export const HOST_EARLY_MIN = 30;
export const LENGTHS = Object.freeze([30, 45, 60, 90]);

const MINUTE = 60_000;

/** The next full half hour at least 20 minutes from now: a believable example start. */
export const exampleStart = (now = new Date()) => {
  const start = new Date(now.getTime() + 20 * MINUTE);
  start.setSeconds(0, 0);
  start.setMinutes(start.getMinutes() < 30 ? 30 : 60);
  return start;
};

export const clampDoors = (value) =>
  Math.min(DOORS.max, Math.max(DOORS.min, Math.round(Number(value) || DOORS.default)));

/**
 * The moments of one room, and where each sits on a bar from the host's
 * early entry to the end (0–100 %), for the timeline drawing.
 */
export const timelineFor = ({ start, lengthMinutes, doorsMinutes }) => {
  const startsAt = new Date(start).getTime();
  const doors = clampDoors(doorsMinutes);
  const hostAt = startsAt - HOST_EARLY_MIN * MINUTE;
  const doorsAt = startsAt - doors * MINUTE;
  const endsAt = startsAt + lengthMinutes * MINUTE;
  const span = endsAt - hostAt;
  const at = (t) => Math.round(((t - hostAt) / span) * 1000) / 10;
  return {
    hostAt,
    doorsAt,
    startsAt,
    endsAt,
    marks: [
      { id: 'host', label: 'You can open the room', time: hostAt, position: 0 },
      { id: 'doors', label: 'Doors open', time: doorsAt, position: at(doorsAt) },
      { id: 'start', label: 'Lesson starts', time: startsAt, position: at(startsAt) },
      { id: 'end', label: 'Room closes', time: endsAt, position: 100 },
    ],
  };
};

/**
 * A language tag the date formatter accepts, or undefined (the browser's
 * default). Browsers can report tags Intl rejects (e.g. "en-US@posix"), and
 * a throwing formatter would blank the whole homepage.
 */
export const safeLocale = (locale) => {
  try {
    return locale && Intl.DateTimeFormat.supportedLocalesOf([locale]).length ? locale : undefined;
  } catch {
    return undefined;
  }
};

/** A time zone Intl knows, or UTC. */
export const safeZone = (zone) => {
  try {
    new Intl.DateTimeFormat('en', { timeZone: zone });
    return zone || 'UTC';
  } catch {
    return 'UTC';
  }
};

/** "14:30" in a time zone, in the visitor's language. */
export const clock = (time, timeZone, locale) =>
  new Intl.DateTimeFormat(safeLocale(locale), { timeZone: safeZone(timeZone), hour: '2-digit', minute: '2-digit' }).format(
    new Date(time),
  );

/** The weekday offset between two zones at a moment: -1, 0 or +1 ("next day"). */
export const dayShift = (time, fromZone, toZone) => {
  const day = (zone) =>
    new Intl.DateTimeFormat('en-CA', { timeZone: safeZone(zone), year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(time));
  const a = day(fromZone);
  const b = day(toZone);
  return a === b ? 0 : b > a ? 1 : -1;
};

/** Cities shown next to the visitor's own time; the visitor's zone first, no duplicates. */
export const GUEST_ZONES = Object.freeze([
  { zone: 'Europe/London', city: 'London' },
  { zone: 'Europe/Berlin', city: 'Berlin' },
  { zone: 'America/New_York', city: 'New York' },
  { zone: 'Asia/Singapore', city: 'Singapore' },
  { zone: 'Australia/Sydney', city: 'Sydney' },
]);

export const cityOf = (zone) => String(zone || 'UTC').split('/').pop().replace(/_/g, ' ');

export const guestTimes = ({ time, ownZone, locale, count = 3 }) => {
  const seen = new Set();
  const list = [];
  for (const entry of [{ zone: ownZone, city: cityOf(ownZone), own: true }, ...GUEST_ZONES]) {
    const shown = clock(time, entry.zone, locale);
    const key = `${shown}|${dayShift(time, ownZone, entry.zone)}`;
    if (seen.has(entry.zone) || (!entry.own && seen.has(key))) continue;
    seen.add(entry.zone);
    seen.add(key);
    list.push({ ...entry, time: shown, shift: dayShift(time, ownZone, entry.zone) });
    if (list.length === count + 1) break;
  }
  return list;
};

/** "4:59" — minutes and seconds, for the countdown in the demo. */
export const mmss = (ms) => {
  const total = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
};

/** Where the "Create this room" button leads: sign-up first, then the real editor. */
export const plannerNext = '/rooms/new';
__LP_EOF__
echo "wrote apps/web/src/components/Landing/landingModel.js"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/HeroDemo.jsx <<'__LP_EOF__'
import { useEffect, useRef, useState } from 'react';
import { mmss } from './landingModel.js';

/**
 * The homepage's one moving picture  (Landing)
 *
 * A miniature of a real room, playing through what the product does in
 * twelve seconds: the lobby counts down, the doors open, people come in,
 * someone speaks, a question arrives in the chat, a reaction floats up, and
 * the host gets the "5 minutes left" notice. It is drawn with HTML and CSS
 * (no video, no images) so it is sharp at every size and costs nothing to load.
 *
 * It plays only while it is on screen, stops when the tab is hidden, and
 * shows a still of the full room to anyone who prefers reduced motion.
 */

const PEOPLE = [
  { name: 'Ms Okafor', initial: 'O', hue: 'sky', host: true },
  { name: 'Jonas', initial: 'J', hue: 'mint' },
  { name: 'Amira', initial: 'A', hue: 'sun' },
  { name: 'Lea', initial: 'L', hue: 'rose' },
];

// Scene timings in ms from the start of one loop.
const SCRIPT = [
  { at: 0, scene: 'lobby' },
  { at: 3600, scene: 'doors' },
  { at: 4600, scene: 'room', joined: 1 },
  { at: 5200, scene: 'room', joined: 2 },
  { at: 5800, scene: 'room', joined: 3 },
  { at: 6400, scene: 'room', joined: 4, speaking: 0 },
  { at: 7800, scene: 'room', joined: 4, speaking: 2, chat: true },
  { at: 9000, scene: 'room', joined: 4, speaking: 2, chat: true, reaction: true },
  { at: 10400, scene: 'room', joined: 4, speaking: 0, chat: true, ending: true },
];
const LOOP_MS = 12600;
const LOBBY_COUNTDOWN_MS = 3600;

const STILL = { scene: 'room', joined: 4, speaking: 0, chat: true, ending: false };

const prefersReducedMotion = () =>
  typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

function Tile({ person, speaking, index }) {
  return (
    <div className={`lp-tile lp-tile--${person.hue}${speaking ? ' is-speaking' : ''}`} style={{ '--i': index }}>
      <div className="lp-tile__figure" aria-hidden="true">
        <span className="lp-tile__head" />
        <span className="lp-tile__body" />
      </div>
      <span className="lp-tile__name">
        {person.name}
        {person.host ? <span className="lp-tile__role">host</span> : null}
      </span>
    </div>
  );
}

export default function HeroDemo() {
  const [state, setState] = useState(() => (prefersReducedMotion() ? STILL : SCRIPT[0]));
  const [countdown, setCountdown] = useState(LOBBY_COUNTDOWN_MS);
  const rootRef = useRef(null);
  const reduced = useRef(prefersReducedMotion());

  useEffect(() => {
    if (reduced.current) return undefined;
    let timers = [];
    let tick = 0;
    let visible = true;
    let running = false;

    const clear = () => {
      timers.forEach((timer) => window.clearTimeout(timer));
      timers = [];
      window.clearInterval(tick);
      running = false;
    };

    const play = () => {
      if (running || !visible || document.hidden) return;
      running = true;
      const loopStart = performance.now();
      SCRIPT.forEach((step) => {
        timers.push(window.setTimeout(() => setState(step), step.at));
      });
      tick = window.setInterval(() => {
        setCountdown(Math.max(0, LOBBY_COUNTDOWN_MS - (performance.now() - loopStart)));
      }, 250);
      timers.push(
        window.setTimeout(() => {
          clear();
          setCountdown(LOBBY_COUNTDOWN_MS);
          play();
        }, LOOP_MS),
      );
    };

    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        if (visible) play();
        else clear();
      },
      { threshold: 0.25 },
    );
    if (rootRef.current) observer.observe(rootRef.current);
    const onVisibility = () => (document.hidden ? clear() : play());
    document.addEventListener('visibilitychange', onVisibility);

    return () => {
      clear();
      observer.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, []);

  const inRoom = state.scene === 'room';
  const joined = state.joined ?? 0;

  return (
    <figure className="lp-demo" ref={rootRef} aria-label="A lesson room: the doors open, four people join, a question arrives in the chat.">
      <div className="lp-demo__window">
        <div className="lp-demo__bar">
          <span className="lp-demo__dots" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <span className="lp-demo__title">Maths revision</span>
          {inRoom ? (
            <span className={state.ending ? 'lp-demo__clock is-warn' : 'lp-demo__clock'}>
              {state.ending ? 'Closes in 5 min' : 'Live'}
            </span>
          ) : null}
        </div>

        <div className={`lp-demo__stage lp-demo__stage--${state.scene}`}>
          {!inRoom ? (
            <div className="lp-lobby">
              <p className="lp-lobby__label">{state.scene === 'doors' ? 'Doors are open' : 'Doors open in'}</p>
              <p className="lp-lobby__count" aria-live="off">
                {state.scene === 'doors' ? 'Come in' : mmss(countdown)}
              </p>
              <div className="lp-lobby__waiting" aria-hidden="true">
                {PEOPLE.slice(1).map((person) => (
                  <span key={person.name} className={`lp-dot lp-dot--${person.hue}`}>
                    {person.initial}
                  </span>
                ))}
                <span className="lp-lobby__hint">3 waiting</span>
              </div>
              <span className={state.scene === 'doors' ? 'lp-lobby__button is-ready' : 'lp-lobby__button'}>Enter room</span>
            </div>
          ) : (
            <div className="lp-grid">
              {PEOPLE.slice(0, joined).map((person, index) => (
                <Tile key={person.name} person={person} index={index} speaking={state.speaking === index} />
              ))}
              {state.reaction ? (
                <span className="lp-reaction" aria-hidden="true">
                  👏
                </span>
              ) : null}
            </div>
          )}
        </div>

        <div className="lp-demo__foot">
          <div className={state.chat ? 'lp-chat is-shown' : 'lp-chat'} aria-hidden={!state.chat}>
            <span className="lp-dot lp-dot--sun">A</span>
            <span className="lp-chat__bubble">Could you go over question 3 again?</span>
          </div>
          <div className="lp-controls" aria-hidden="true">
            <span className="lp-control">Mic</span>
            <span className="lp-control">Camera</span>
            <span className="lp-control">Share</span>
            <span className="lp-control lp-control--end">Leave</span>
          </div>
        </div>
      </div>
      {state.ending ? (
        <p className="lp-demo__toast" role="presentation">
          5 minutes left <span className="lp-demo__toast-action">+10 min</span>
        </p>
      ) : null}
    </figure>
  );
}
__LP_EOF__
echo "wrote apps/web/src/components/Landing/HeroDemo.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/RoomPlanner.jsx <<'__LP_EOF__'
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { DOORS, LENGTHS, clock, exampleStart, guestTimes, plannerNext, timelineFor } from './landingModel.js';

/**
 * "Plan a room" — try it before signing up  (Landing)
 *
 * The same choices as the real room editor, answered instantly: when the
 * doors open, how long it runs, how many seats, who can come in. The
 * timeline, the invitation card and the times for guests elsewhere update as
 * you move the controls. Nothing is sent anywhere; "Create this room" takes
 * you through sign-up to the editor.
 */

const viewerZone = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
};

export default function RoomPlanner({ signedIn }) {
  const zone = useMemo(viewerZone, []);
  const locale = typeof navigator !== 'undefined' ? navigator.language : undefined;
  const start = useMemo(() => exampleStart(), []);

  const [title, setTitle] = useState('Maths revision');
  const [length, setLength] = useState(60);
  const [doors, setDoors] = useState(DOORS.default);
  const [seats, setSeats] = useState(12);
  const [access, setAccess] = useState('invited');
  const [approval, setApproval] = useState(false);

  const timeline = timelineFor({ start, lengthMinutes: length, doorsMinutes: doors });
  const guests = guestTimes({ time: timeline.startsAt, ownZone: zone, locale, count: 3 });
  const createHref = signedIn ? plannerNext : `/signup?next=${encodeURIComponent(plannerNext)}`;

  return (
    <div className="lp-planner">
      <form className="lp-planner__controls" onSubmit={(event) => event.preventDefault()} aria-label="Plan an example room">
        <label className="lp-field">
          <span className="lp-field__label">Name</span>
          <input className="lp-input" value={title} maxLength={60} onChange={(event) => setTitle(event.target.value)} />
        </label>

        <fieldset className="lp-field">
          <legend className="lp-field__label">Length</legend>
          <div className="lp-pills">
            {LENGTHS.map((minutes) => (
              <button
                key={minutes}
                type="button"
                className={length === minutes ? 'lp-pill is-on' : 'lp-pill'}
                aria-pressed={length === minutes}
                onClick={() => setLength(minutes)}
              >
                {minutes} min
              </button>
            ))}
          </div>
        </fieldset>

        <label className="lp-field">
          <span className="lp-field__label">
            Doors open <strong>{doors} minutes</strong> before the start
          </span>
          <input
            className="lp-range"
            type="range"
            min={DOORS.min}
            max={DOORS.max}
            value={doors}
            onChange={(event) => setDoors(Number(event.target.value))}
            aria-valuetext={`${doors} minutes`}
          />
          <span className="lp-range__scale" aria-hidden="true">
            <span>{DOORS.min}</span>
            <span>{DOORS.max} min</span>
          </span>
        </label>

        <div className="lp-field">
          <span className="lp-field__label" id="lp-seats">
            Seats
          </span>
          <div className="lp-stepper" role="group" aria-labelledby="lp-seats">
            <button type="button" onClick={() => setSeats((n) => Math.max(2, n - 1))} aria-label="One seat fewer">
              −
            </button>
            <output aria-live="polite">{seats}</output>
            <button type="button" onClick={() => setSeats((n) => Math.min(300, n + 1))} aria-label="One seat more">
              +
            </button>
          </div>
        </div>

        <fieldset className="lp-field">
          <legend className="lp-field__label">Who can come in</legend>
          <div className="lp-segment">
            <button type="button" className={access === 'invited' ? 'is-on' : ''} aria-pressed={access === 'invited'} onClick={() => setAccess('invited')}>
              People I invite
            </button>
            <button type="button" className={access === 'link' ? 'is-on' : ''} aria-pressed={access === 'link'} onClick={() => setAccess('link')}>
              Anyone with the link
            </button>
          </div>
          <label className="lp-check">
            <input type="checkbox" checked={approval} onChange={(event) => setApproval(event.target.checked)} />
            <span>I let people in myself</span>
          </label>
        </fieldset>
      </form>

      <div className="lp-planner__result" aria-live="polite">
        <div className="lp-timeline" role="img" aria-label={`Timeline: doors open at ${clock(timeline.doorsAt, zone, locale)}, starts at ${clock(timeline.startsAt, zone, locale)}, closes at ${clock(timeline.endsAt, zone, locale)}.`}>
          <div className="lp-timeline__track">
            <span
              className="lp-timeline__early"
              style={{ left: `${timeline.marks[1].position}%`, width: `${timeline.marks[2].position - timeline.marks[1].position}%` }}
            />
            <span className="lp-timeline__live" style={{ left: `${timeline.marks[2].position}%`, right: 0 }} />
            {timeline.marks.map((mark) => (
              <span key={mark.id} className={`lp-timeline__mark lp-timeline__mark--${mark.id}`} style={{ left: `${mark.position}%` }} />
            ))}
          </div>
          <ol className="lp-timeline__legend">
            {timeline.marks.map((mark) => (
              <li key={mark.id} className={`lp-legend lp-legend--${mark.id}`}>
                <span className="lp-legend__time">{clock(mark.time, zone, locale)}</span>
                <span className="lp-legend__label">{mark.label}</span>
              </li>
            ))}
          </ol>
        </div>

        <article className="lp-invite">
          <p className="lp-invite__from">You are invited</p>
          <h3 className="lp-invite__title">{title.trim() || 'Your room'}</h3>
          <p className="lp-invite__when">
            Today, {clock(timeline.startsAt, zone, locale)}–{clock(timeline.endsAt, zone, locale)}
          </p>
          <ul className="lp-invite__facts">
            <li>Doors open at {clock(timeline.doorsAt, zone, locale)}</li>
            <li>{seats} seats{seats <= 4 ? ', with a waiting list when full' : ''}</li>
            <li>{access === 'link' ? 'Anyone in your organisation with the link' : 'Only invited people'}</li>
            {approval ? <li>The host lets people in</li> : null}
          </ul>
          <div className="lp-invite__zones">
            {guests.map((guest) => (
              <span key={guest.zone} className={guest.own ? 'lp-zone is-own' : 'lp-zone'}>
                <strong>{guest.time}</strong>
                {guest.shift > 0 ? <sup>+1</sup> : guest.shift < 0 ? <sup>−1</sup> : null} {guest.own ? 'your time' : guest.city}
              </span>
            ))}
          </div>
        </article>

        <Link className="lp-button lp-button--primary" to={createHref}>
          Create this room
        </Link>
      </div>
    </div>
  );
}
__LP_EOF__
echo "wrote apps/web/src/components/Landing/RoomPlanner.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/landing.css <<'__LP_EOF__'
/* Public homepage — see pages/LandingPage.jsx.
 *
 * Palette from the classroom itself: a slate board, chalk, a highlighter.
 *   board   #15262B  the page        chalk  #EEF2EE  text
 *   board-2 #1D353B  raised areas    sun    #FFD54A  the one accent: doors, calls to action
 *   board-3 #26444B  lines, inputs   sky    #8CC8FF  secondary: live, links
 * Type: Bricolage Grotesque for headlines, Atkinson Hyperlegible for reading.
 * Everything is scoped under .lp so the app behind sign-in is untouched.
 */

@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400&family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500..800&display=swap');

.lp {
  --lp-board: #15262b;
  --lp-board-2: #1d353b;
  --lp-board-3: #26444b;
  --lp-line: rgba(238, 242, 238, 0.12);
  --lp-chalk: #eef2ee;
  --lp-chalk-2: rgba(238, 242, 238, 0.72);
  --lp-chalk-3: rgba(238, 242, 238, 0.5);
  --lp-sun: #ffd54a;
  --lp-sun-ink: #2a2206;
  --lp-sky: #8cc8ff;
  --lp-mint: #7fd6b4;
  --lp-rose: #ff9fb2;
  --lp-live: #ff6b5e;
  --lp-display: 'Bricolage Grotesque', 'Segoe UI', system-ui, sans-serif;
  --lp-body: 'Atkinson Hyperlegible', system-ui, -apple-system, 'Segoe UI', sans-serif;
  --lp-radius-lg: 22px;
  --lp-radius: 12px;
  --lp-max: 1180px;

  min-height: 100vh;
  color: var(--lp-chalk);
  font-family: var(--lp-body);
  font-size: 17px;
  line-height: 1.6;
  background:
    radial-gradient(1200px 600px at 85% -10%, rgba(140, 200, 255, 0.1), transparent 60%),
    radial-gradient(900px 500px at -10% 30%, rgba(255, 213, 74, 0.06), transparent 60%),
    var(--lp-board);
  overflow-x: hidden;
}

/* Chalk dust: a faint, fixed texture that makes the slate read as a board. */
.lp::before {
  content: '';
  position: fixed;
  inset: 0;
  pointer-events: none;
  opacity: 0.35;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 .05 0'/%3E%3C/filter%3E%3Crect width='180' height='180' filter='url(%23n)'/%3E%3C/svg%3E");
  z-index: 0;
}

.lp > * { position: relative; z-index: 1; }
.lp a { color: inherit; }
.lp :focus-visible { outline: 3px solid var(--lp-sun); outline-offset: 3px; border-radius: 6px; }

.lp-skip { position: absolute; left: -999px; top: 8px; z-index: 50; padding: 8px 14px; border-radius: 8px; background: var(--lp-sun); color: var(--lp-sun-ink); font-weight: 700; }
.lp-skip:focus { left: 12px; }

html:has(.lp) { scroll-behavior: smooth; }
@media (prefers-reduced-motion: reduce) { html:has(.lp) { scroll-behavior: auto; } }

/* ---------- buttons and links ---------- */

.lp-button {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  min-height: 48px; padding: 0 24px; border-radius: 999px;
  font: 700 16px/1 var(--lp-body); text-decoration: none; cursor: pointer; white-space: nowrap;
  border: 2px solid transparent;
  transition: transform 0.15s ease, background-color 0.15s ease, border-color 0.15s ease;
}
.lp-button--primary { background: var(--lp-sun); color: var(--lp-sun-ink); }
.lp-button--primary:hover { background: #ffe07a; }
.lp-button--primary:active { transform: translateY(1px); }
.lp-button--ghost { border-color: var(--lp-line); color: var(--lp-chalk); }
.lp-button--ghost:hover { border-color: var(--lp-chalk-3); }
.lp-button--small { min-height: 40px; padding: 0 18px; font-size: 15px; }
.lp-link { text-decoration: none; font-weight: 700; color: var(--lp-chalk-2) !important; }
.lp-link:hover { color: var(--lp-chalk) !important; }

/* ---------- navigation ---------- */

.lp-nav {
  position: sticky; top: 0; z-index: 20;
  display: flex; align-items: center; gap: 24px;
  /* Full width, so the blurred bar has no edges; content lines up with the page. */
  padding: 14px max(24px, calc((100% - var(--lp-max)) / 2));
  backdrop-filter: blur(14px) saturate(1.3);
  -webkit-backdrop-filter: blur(14px) saturate(1.3);
  background: color-mix(in srgb, var(--lp-board) 72%, transparent);
  border-bottom: 1px solid transparent;
}
.lp-nav__home { text-decoration: none; }
.lp-brand { display: inline-flex; align-items: center; gap: 10px; font: 750 20px/1 var(--lp-display); letter-spacing: -0.01em; }
.lp-brand__mark { width: 28px; height: 28px; fill: none; stroke: var(--lp-chalk); stroke-width: 2.2; stroke-linecap: round; }
.lp-brand__mark circle { fill: var(--lp-sun); stroke: none; }
.lp-nav__links { display: flex; gap: 22px; margin-left: 12px; }
.lp-nav__links a { text-decoration: none; color: var(--lp-chalk-2); font-size: 15px; }
.lp-nav__links a:hover { color: var(--lp-chalk); }
.lp-nav__actions { margin-left: auto; display: flex; align-items: center; gap: 18px; }
@media (max-width: 820px) { .lp-nav__links { display: none; } }
@media (max-width: 520px) {
  .lp-nav { gap: 10px; padding: 12px 16px; }
  .lp-nav__actions { gap: 12px; }
  /* The hero has both buttons right below; the bar keeps only the main one. */
  .lp-nav__actions .lp-link { display: none; }
  .lp-brand { font-size: 18px; }
}

/* ---------- hero ---------- */

.lp-hero {
  display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.05fr); gap: 56px; align-items: center;
  max-width: var(--lp-max); margin: 0 auto; padding: 56px 24px 96px;
}
.lp-hero__title {
  margin: 0;
  font: 800 clamp(42px, 6.2vw, 78px) / 0.98 var(--lp-display);
  font-variation-settings: 'wdth' 82, 'opsz' 96;
  letter-spacing: -0.035em;
  max-width: 11ch;
  text-wrap: balance;
}
.lp-hero__lead { margin: 24px 0 0; max-width: 34em; font-size: 19px; color: var(--lp-chalk-2); }
.lp-hero__actions { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 32px; }
.lp-hero__note { margin: 18px 0 0; font-size: 14px; color: var(--lp-chalk-3); }
@media (max-width: 960px) {
  .lp-hero { grid-template-columns: 1fr; gap: 48px; padding-top: 32px; }
  .lp-hero__title { max-width: 14ch; }
}

/* ---------- the live demo ---------- */

.lp-demo { position: relative; margin: 0; perspective: 1600px; }
.lp-demo__window {
  border-radius: var(--lp-radius-lg);
  background: linear-gradient(180deg, #1f3a41, #182f35);
  border: 1px solid rgba(238, 242, 238, 0.14);
  box-shadow: 0 40px 80px -30px rgba(0, 0, 0, 0.55), 0 0 0 10px rgba(238, 242, 238, 0.03);
  transform: rotateY(-7deg) rotateX(3deg);
  transform-origin: 30% 50%;
  overflow: hidden;
}
@media (max-width: 960px) { .lp-demo__window { transform: none; } }

.lp-demo__bar { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid var(--lp-line); font-size: 14px; }
.lp-demo__dots { display: inline-flex; gap: 6px; }
.lp-demo__dots i { width: 10px; height: 10px; border-radius: 50%; background: rgba(238, 242, 238, 0.18); }
.lp-demo__title { font-weight: 700; }
.lp-demo__clock { margin-left: auto; padding: 3px 10px; border-radius: 999px; font-size: 12.5px; font-weight: 700; background: rgba(255, 107, 94, 0.16); color: #ffb3ab; }
.lp-demo__clock::before { content: ''; display: inline-block; width: 7px; height: 7px; margin-right: 6px; border-radius: 50%; background: var(--lp-live); vertical-align: 1px; }
.lp-demo__clock.is-warn { background: rgba(255, 213, 74, 0.16); color: var(--lp-sun); }
.lp-demo__clock.is-warn::before { background: var(--lp-sun); }

.lp-demo__stage { position: relative; aspect-ratio: 16 / 10; padding: 14px; }

.lp-lobby {
  height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px;
  border-radius: 14px; background: radial-gradient(circle at 50% 35%, rgba(255, 213, 74, 0.09), transparent 60%);
  text-align: center;
}
.lp-lobby__label { margin: 0; color: var(--lp-chalk-2); font-size: 15px; }
.lp-lobby__count { margin: 0; font: 800 clamp(44px, 7vw, 72px) / 1 var(--lp-display); font-variant-numeric: tabular-nums; letter-spacing: -0.02em; }
.lp-lobby__waiting { display: flex; align-items: center; gap: 6px; }
.lp-lobby__hint { margin-left: 6px; font-size: 13px; color: var(--lp-chalk-3); }
.lp-lobby__button {
  margin-top: 6px; padding: 10px 22px; border-radius: 999px; font-weight: 700; font-size: 15px;
  background: rgba(238, 242, 238, 0.08); color: var(--lp-chalk-3);
  transition: background-color 0.3s ease, color 0.3s ease, box-shadow 0.3s ease;
}
.lp-lobby__button.is-ready { background: var(--lp-sun); color: var(--lp-sun-ink); box-shadow: 0 0 0 8px rgba(255, 213, 74, 0.18); }

.lp-dot {
  display: inline-grid; place-items: center; width: 30px; height: 30px; border-radius: 50%;
  font-size: 13px; font-weight: 700; color: #10232a;
}
.lp-dot--sky { background: var(--lp-sky); }
.lp-dot--mint { background: var(--lp-mint); }
.lp-dot--sun { background: var(--lp-sun); }
.lp-dot--rose { background: var(--lp-rose); }

.lp-grid { position: relative; height: 100%; display: grid; grid-template-columns: repeat(2, 1fr); grid-auto-rows: 1fr; gap: 10px; }
.lp-tile {
  position: relative; border-radius: 12px; overflow: hidden;
  animation: lp-join 0.5s cubic-bezier(0.2, 0.9, 0.3, 1.2) both;
  box-shadow: inset 0 0 0 2px transparent;
  transition: box-shadow 0.25s ease;
}
.lp-tile--sky { background: linear-gradient(160deg, #2f5f7a, #20465a); }
.lp-tile--mint { background: linear-gradient(160deg, #2e6655, #1f4a3f); }
.lp-tile--sun { background: linear-gradient(160deg, #6f5a23, #4b3d17); }
.lp-tile--rose { background: linear-gradient(160deg, #6b3a49, #4a2833); }
.lp-tile.is-speaking { box-shadow: inset 0 0 0 3px var(--lp-sun); }
.lp-tile__figure { position: absolute; inset: 0; display: grid; place-items: end center; }
.lp-tile__head { position: absolute; top: 26%; width: 26%; aspect-ratio: 1; border-radius: 50%; background: rgba(238, 242, 238, 0.28); }
.lp-tile__body { width: 56%; height: 34%; border-radius: 50% 50% 0 0 / 70% 70% 0 0; background: rgba(238, 242, 238, 0.2); }
.lp-tile__name { position: absolute; left: 8px; bottom: 8px; display: inline-flex; gap: 6px; align-items: center; padding: 3px 8px; border-radius: 6px; background: rgba(10, 20, 23, 0.55); font-size: 12px; font-weight: 700; }
.lp-tile__role { font-weight: 400; color: var(--lp-sun); }
@keyframes lp-join { from { opacity: 0; transform: scale(0.86); } to { opacity: 1; transform: none; } }

.lp-reaction { position: absolute; right: 18%; bottom: 10%; font-size: 34px; animation: lp-float 1.6s ease-out both; pointer-events: none; }
@keyframes lp-float { 0% { opacity: 0; transform: translateY(20px) scale(0.6); } 20% { opacity: 1; transform: translateY(0) scale(1.1); } 100% { opacity: 0; transform: translateY(-120px) scale(1); } }

.lp-demo__foot { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 0 14px 14px; min-height: 46px; }
.lp-chat { display: flex; align-items: center; gap: 8px; opacity: 0; transform: translateY(8px); transition: opacity 0.35s ease, transform 0.35s ease; min-width: 0; }
.lp-chat.is-shown { opacity: 1; transform: none; }
.lp-chat .lp-dot { width: 26px; height: 26px; flex: 0 0 auto; font-size: 12px; }
.lp-chat__bubble { padding: 7px 12px; border-radius: 14px 14px 14px 4px; background: rgba(238, 242, 238, 0.1); font-size: 13.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.lp-controls { display: flex; gap: 6px; flex: 0 0 auto; }
.lp-control { padding: 6px 10px; border-radius: 999px; background: rgba(238, 242, 238, 0.08); font-size: 12px; color: var(--lp-chalk-2); }
.lp-control--end { background: rgba(255, 107, 94, 0.2); color: #ffb3ab; }
@media (max-width: 560px) { .lp-controls { display: none; } }

.lp-demo__toast {
  position: absolute; right: -8px; bottom: -18px; margin: 0;
  display: inline-flex; align-items: center; gap: 12px; padding: 10px 14px; border-radius: 14px;
  background: var(--lp-chalk); color: #10232a; font-weight: 700; font-size: 14px;
  box-shadow: 0 16px 40px -12px rgba(0, 0, 0, 0.5);
  animation: lp-toast 0.4s cubic-bezier(0.2, 0.9, 0.3, 1.2) both;
}
.lp-demo__toast-action { padding: 4px 10px; border-radius: 999px; background: var(--lp-sun); color: var(--lp-sun-ink); }
@keyframes lp-toast { from { opacity: 0; transform: translateY(12px); } to { opacity: 1; transform: none; } }
@media (max-width: 560px) { .lp-demo__toast { right: 8px; } }

/* ---------- sections ---------- */

.lp-section { max-width: var(--lp-max); margin: 0 auto; padding: 96px 24px; }
.lp-section__head { max-width: 40em; margin-bottom: 48px; }
.lp-section__title {
  margin: 0; font: 780 clamp(32px, 4.2vw, 52px) / 1.02 var(--lp-display);
  font-variation-settings: 'wdth' 85; letter-spacing: -0.03em; max-width: 18ch; text-wrap: balance;
}
.lp-section__lead { margin: 16px 0 0; font-size: 19px; color: var(--lp-chalk-2); }
#inside > .lp-section__title { margin-bottom: 56px; }

.lp-section--board {
  max-width: none; margin: 0;
  background: linear-gradient(180deg, transparent, rgba(29, 53, 59, 0.75) 12%, rgba(29, 53, 59, 0.75) 88%, transparent);
}
.lp-section--board > * { max-width: var(--lp-max); margin-left: auto; margin-right: auto; }

/* Scenes: text and a small drawing of the real screen, alternating sides. */
.lp-scene { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 64px; align-items: center; padding: 40px 0; }
.lp-scene + .lp-scene { border-top: 1px solid var(--lp-line); }
.lp-scene.is-flipped .lp-scene__text { order: 2; }
.lp-scene__title { margin: 0; font: 750 clamp(26px, 2.8vw, 34px) / 1.1 var(--lp-display); letter-spacing: -0.02em; }
.lp-scene__lead { margin: 12px 0 0; font-size: 18px; color: var(--lp-chalk-2); max-width: 32em; }
.lp-scene__points { margin: 20px 0 0; padding: 0; list-style: none; display: grid; gap: 10px; }
.lp-scene__points li { position: relative; padding-left: 26px; }
.lp-scene__points li::before { content: ''; position: absolute; left: 2px; top: 0.62em; width: 12px; height: 3px; border-radius: 2px; background: var(--lp-sun); }
@media (max-width: 860px) {
  .lp-scene { grid-template-columns: 1fr; gap: 28px; }
  .lp-scene.is-flipped .lp-scene__text { order: 0; }
}

.lp-art { position: relative; aspect-ratio: 4 / 3; border-radius: var(--lp-radius-lg); background: var(--lp-board-2); border: 1px solid var(--lp-line); padding: 22px; overflow: hidden; }
.lp-art--live { display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr auto; gap: 10px; }
.lp-art__tile { border-radius: 12px; }
.lp-art__tile--sky { background: linear-gradient(160deg, #2f5f7a, #20465a); }
.lp-art__tile--mint { background: linear-gradient(160deg, #2e6655, #1f4a3f); }
.lp-art__tile--sun { background: linear-gradient(160deg, #6f5a23, #4b3d17); }
.lp-art__tile--rose { background: linear-gradient(160deg, #6b3a49, #4a2833); }
.lp-art__tile.is-speaking { box-shadow: inset 0 0 0 3px var(--lp-sun); }
.lp-art__bar { grid-column: 1 / -1; justify-self: center; display: flex; gap: 8px; padding: 8px; border-radius: 999px; background: rgba(0, 0, 0, 0.2); }
.lp-art__bar i { width: 34px; height: 34px; border-radius: 50%; background: rgba(238, 242, 238, 0.14); }
.lp-art__bar i.is-red { background: rgba(255, 107, 94, 0.5); }

.lp-art--lobby { display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; }
.lp-art__big { margin: 0; font: 800 76px/1 var(--lp-display); font-variant-numeric: tabular-nums; }
.lp-art__small { margin: 6px 0 0; color: var(--lp-chalk-2); }
.lp-art__knock { position: absolute; left: 22px; right: 22px; bottom: 22px; margin: 0; display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 10px 12px 10px 16px; border-radius: 12px; background: rgba(238, 242, 238, 0.08); font-size: 15px; }
.lp-art__knock b { padding: 6px 14px; border-radius: 999px; background: var(--lp-sun); color: var(--lp-sun-ink); font-size: 14px; }

.lp-art--course { display: flex; flex-direction: column; gap: 10px; justify-content: center; }
.lp-art__lesson { margin: 0; display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 12px; background: rgba(238, 242, 238, 0.05); }
.lp-art__lesson::before { content: ''; width: 18px; height: 18px; border-radius: 50%; border: 2px solid var(--lp-chalk-3); flex: 0 0 auto; }
.lp-art__lesson.is-done::before { border-color: var(--lp-mint); background: var(--lp-mint); }
.lp-art__lesson.is-now { background: rgba(255, 213, 74, 0.1); box-shadow: inset 3px 0 0 var(--lp-sun); }
.lp-art__lesson.is-now::before { border-color: var(--lp-sun); }
.lp-art__progress { height: 8px; border-radius: 4px; background: rgba(238, 242, 238, 0.1); overflow: hidden; margin-top: 6px; }
.lp-art__progress i { display: block; height: 100%; background: var(--lp-mint); border-radius: 4px; }

.lp-art--chat { display: flex; flex-direction: column; justify-content: center; gap: 12px; }
.lp-art__msg { margin: 0; align-self: flex-start; max-width: 78%; padding: 10px 14px; border-radius: 16px 16px 16px 4px; background: rgba(238, 242, 238, 0.1); }
.lp-art__msg.is-mine { align-self: flex-end; border-radius: 16px 16px 4px 16px; background: var(--lp-sky); color: #0d2233; }
.lp-art__seen { margin: -4px 0 0; align-self: flex-end; font-size: 13px; color: var(--lp-chalk-3); }

/* ---------- planner ---------- */

.lp-planner { display: grid; grid-template-columns: minmax(0, 0.9fr) minmax(0, 1.1fr); gap: 40px; align-items: start; }
@media (max-width: 900px) { .lp-planner { grid-template-columns: 1fr; } }
.lp-planner__controls { display: grid; gap: 22px; padding: 28px; border-radius: var(--lp-radius-lg); background: var(--lp-board); border: 1px solid var(--lp-line); }
.lp-field { display: grid; gap: 8px; margin: 0; padding: 0; border: 0; min-width: 0; }
.lp-field__label { font-weight: 700; font-size: 15px; padding: 0; }
.lp-field__label strong { color: var(--lp-sun); }
.lp-input { width: 100%; box-sizing: border-box; padding: 12px 14px; border-radius: var(--lp-radius); border: 1px solid var(--lp-board-3); background: var(--lp-board-2); color: var(--lp-chalk); font: inherit; }
.lp-pills { display: flex; flex-wrap: wrap; gap: 8px; }
.lp-pill { padding: 9px 16px; border-radius: 999px; border: 1px solid var(--lp-board-3); background: transparent; color: var(--lp-chalk); font: inherit; font-size: 15px; cursor: pointer; }
.lp-pill.is-on { background: var(--lp-chalk); color: #10232a; border-color: var(--lp-chalk); font-weight: 700; }
.lp-range { width: 100%; accent-color: var(--lp-sun); height: 28px; }
.lp-range__scale { display: flex; justify-content: space-between; font-size: 13px; color: var(--lp-chalk-3); margin-top: -4px; }
.lp-stepper { display: inline-flex; align-items: center; justify-self: start; border-radius: 999px; border: 1px solid var(--lp-board-3); }
.lp-stepper button { width: 44px; height: 44px; border: 0; background: transparent; color: var(--lp-chalk); font-size: 22px; cursor: pointer; border-radius: 50%; }
.lp-stepper output { min-width: 3ch; text-align: center; font: 700 18px/1 var(--lp-body); font-variant-numeric: tabular-nums; }
.lp-segment { display: grid; grid-template-columns: 1fr 1fr; padding: 4px; border-radius: 999px; background: var(--lp-board-2); }
.lp-segment button { padding: 10px 12px; border: 0; border-radius: 999px; background: transparent; color: var(--lp-chalk-2); font: inherit; font-size: 14.5px; cursor: pointer; }
.lp-segment button.is-on { background: var(--lp-chalk); color: #10232a; font-weight: 700; }
.lp-check { display: flex; align-items: center; gap: 10px; font-size: 15px; cursor: pointer; }
.lp-check input { width: 20px; height: 20px; accent-color: var(--lp-sun); }

.lp-planner__result { display: grid; gap: 24px; justify-items: start; }

.lp-timeline { width: 100%; }
.lp-timeline__track { position: relative; height: 14px; border-radius: 7px; background: rgba(238, 242, 238, 0.1); margin: 12px 0 18px; }
.lp-timeline__early, .lp-timeline__live { position: absolute; top: 0; bottom: 0; transition: left 0.3s ease, width 0.3s ease, right 0.3s ease; }
.lp-timeline__early { background: repeating-linear-gradient(45deg, rgba(255, 213, 74, 0.55) 0 6px, rgba(255, 213, 74, 0.3) 6px 12px); }
.lp-timeline__live { background: var(--lp-sky); border-radius: 0 7px 7px 0; }
.lp-timeline__mark { position: absolute; top: -6px; width: 4px; height: 26px; margin-left: -2px; border-radius: 2px; background: var(--lp-chalk); transition: left 0.3s ease; }
.lp-timeline__mark--doors { background: var(--lp-sun); }
.lp-timeline__mark--host, .lp-timeline__mark--end { background: var(--lp-chalk-3); }
.lp-timeline__legend { margin: 0; padding: 0; list-style: none; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
.lp-legend { display: grid; gap: 2px; font-size: 13.5px; color: var(--lp-chalk-2); }
.lp-legend__time { font: 750 20px/1.1 var(--lp-display); color: var(--lp-chalk); font-variant-numeric: tabular-nums; }
.lp-legend--doors .lp-legend__time { color: var(--lp-sun); }
@media (max-width: 560px) { .lp-timeline__legend { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (prefers-reduced-motion: reduce) { .lp-timeline__early, .lp-timeline__live, .lp-timeline__mark { transition: none; } }

.lp-invite {
  width: 100%; box-sizing: border-box; padding: 26px; border-radius: var(--lp-radius-lg);
  background: var(--lp-chalk); color: #12262c;
  box-shadow: 0 30px 60px -30px rgba(0, 0, 0, 0.6);
}
.lp-invite__from { margin: 0; font-size: 14px; color: #4b6166; }
.lp-invite__title { margin: 4px 0 0; font: 780 30px/1.1 var(--lp-display); letter-spacing: -0.02em; overflow-wrap: anywhere; }
.lp-invite__when { margin: 6px 0 0; font-weight: 700; }
.lp-invite__facts { margin: 14px 0 0; padding-left: 18px; display: grid; gap: 4px; color: #2e4449; }
.lp-invite__zones { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 18px; }
.lp-zone { padding: 6px 12px; border-radius: 999px; background: #dfe7e4; font-size: 14px; }
.lp-zone.is-own { background: #12262c; color: var(--lp-chalk); }
.lp-zone sup { font-size: 10px; }

/* ---------- privacy facts ---------- */

.lp-facts { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 56px; margin: 0; }
.lp-facts > div { padding: 22px 0; border-top: 1px solid var(--lp-line); }
.lp-facts dt { font: 750 21px/1.2 var(--lp-display); }
.lp-facts dd { margin: 6px 0 0; color: var(--lp-chalk-2); max-width: 30em; }
@media (max-width: 720px) { .lp-facts { grid-template-columns: 1fr; } }

/* ---------- closing ---------- */

.lp-final { max-width: var(--lp-max); margin: 0 auto; padding: 72px 24px 110px; text-align: center; display: grid; justify-items: center; gap: 28px; }
.lp-final__title { margin: 0; font: 800 clamp(34px, 5vw, 64px) / 1 var(--lp-display); font-variation-settings: 'wdth' 82; letter-spacing: -0.035em; max-width: 16ch; text-wrap: balance; }
.lp-final .lp-hero__actions { margin-top: 0; justify-content: center; }

.lp-footer { max-width: var(--lp-max); margin: 0 auto; padding: 28px 24px 40px; display: flex; flex-wrap: wrap; align-items: center; gap: 20px 32px; border-top: 1px solid var(--lp-line); color: var(--lp-chalk-2); }
.lp-footer nav { display: flex; flex-wrap: wrap; gap: 20px; }
.lp-footer nav a { text-decoration: none; font-size: 15px; }
.lp-footer nav a:hover { color: var(--lp-chalk); }
.lp-footer__small { margin: 0 0 0 auto; font-size: 14px; color: var(--lp-chalk-3); }

/* ---------- motion preferences ---------- */

@media (prefers-reduced-motion: reduce) {
  .lp-tile, .lp-reaction, .lp-demo__toast { animation: none; }
  .lp-chat, .lp-lobby__button, .lp-button { transition: none; }
}
__LP_EOF__
echo "wrote apps/web/src/components/Landing/landing.css"

mkdir -p apps/web/src/components/Landing/__checks__
cat > apps/web/src/components/Landing/__checks__/landingModel.check.mjs <<'__LP_EOF__'
// Landing — the homepage's room planner and redirects.
// Run: node --test apps/web/src/components/Landing/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { clampDoors, clock, dayShift, exampleStart, guestTimes, mmss, safeLocale, timelineFor } from '../landingModel.js';

test('doors stay between 3 and 10 minutes, like the real room editor', () => {
  assert.equal(clampDoors(1), 3);
  assert.equal(clampDoors(12), 10);
  assert.equal(clampDoors('7'), 7);
  assert.equal(clampDoors(undefined), 5);
});

test('the example start is the next half hour at least 20 minutes away', () => {
  assert.equal(exampleStart(new Date('2026-03-10T10:05:00Z')).toISOString(), '2026-03-10T10:30:00.000Z');
  assert.equal(exampleStart(new Date('2026-03-10T10:20:00Z')).toISOString(), '2026-03-10T11:00:00.000Z');
});

test('the timeline puts every moment on the bar', () => {
  const t = timelineFor({ start: '2026-03-10T10:00:00Z', lengthMinutes: 60, doorsMinutes: 5 });
  assert.deepEqual(t.marks.map((m) => m.id), ['host', 'doors', 'start', 'end']);
  assert.equal(t.marks[0].position, 0);
  assert.equal(t.marks[3].position, 100);
  // 25 of 90 minutes, 30 of 90 minutes
  assert.equal(t.marks[1].position, 27.8);
  assert.equal(t.marks[2].position, 33.3);
  assert.equal(t.doorsAt, Date.parse('2026-03-10T09:55:00Z'));
});

test('guest times: own zone first, other cities, next-day marked', () => {
  const list = guestTimes({ time: '2026-03-10T22:00:00Z', ownZone: 'Europe/Berlin', locale: 'en-GB', count: 3 });
  assert.equal(list[0].own, true);
  assert.equal(list[0].time, '23:00');
  assert.equal(list.length, 4);
  assert.ok(list.every((entry, i) => i === 0 || !entry.own));
  const sydney = guestTimes({ time: '2026-03-10T22:00:00Z', ownZone: 'Europe/Berlin', locale: 'en-GB', count: 5 }).find((e) => e.city === 'Sydney');
  assert.equal(sydney.shift, 1);
  assert.equal(dayShift('2026-03-10T22:00:00Z', 'Europe/Berlin', 'America/New_York'), 0);
});

test('countdown', () => {
  assert.equal(mmss(299_001), '5:00');
  assert.equal(mmss(61_000), '1:01');
  assert.equal(mmss(-5), '0:00');
});

test('odd browser languages and zones never break the page', () => {
  assert.equal(safeLocale('en-US@posix'), undefined);
  assert.equal(safeLocale('de-DE'), 'de-DE');
  assert.equal(safeLocale(undefined), undefined);
  assert.match(clock('2026-03-10T10:00:00Z', 'Not/AZone', 'en-US@posix'), /\d{1,2}[:.]\d{2}/);
  assert.equal(guestTimes({ time: '2026-03-10T10:00:00Z', ownZone: 'UTC', locale: 'en-US@posix', count: 3 }).length, 4);
});
__LP_EOF__
echo "wrote apps/web/src/components/Landing/__checks__/landingModel.check.mjs"

mkdir -p apps/web/src/components/Auth
cat > apps/web/src/components/Auth/authModel.js <<'__LP_EOF__'
/**
 * Pure helpers for sign-in and sign-up  (Landing)
 * Tested in __checks__/authModel.check.mjs.
 */

export const MIN_PASSWORD = 12;

/**
 * 0–4, for the bar under the password field. Length counts most; mixing
 * kinds of characters adds a little. The server decides what is accepted.
 */
export const passwordStrength = (password) => {
  const value = String(password ?? '');
  if (!value) return 0;
  if (value.length < MIN_PASSWORD) return 1;
  const kinds = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((re) => re.test(value)).length;
  if (value.length >= 20 || (value.length >= 16 && kinds >= 3)) return 4;
  if (kinds >= 3 || value.length >= 16) return 3;
  return 2;
};

export const STRENGTH_WORDS = ['', 'Too short', 'Good', 'Strong', 'Very strong'];

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Problems with the sign-up form, keyed by field; empty when it can be sent. */
export const validateSignup = ({ displayName, email, password }) => {
  const errors = {};
  if (!String(displayName ?? '').trim()) errors.displayName = 'Tell us what to call you.';
  else if (String(displayName).trim().length > 80) errors.displayName = 'At most 80 characters.';
  if (!EMAIL.test(String(email ?? '').trim())) errors.email = 'Enter an email address like name@example.com.';
  if (String(password ?? '').length < MIN_PASSWORD) errors.password = `At least ${MIN_PASSWORD} characters.`;
  return errors;
};

/** Only in-app paths may be a destination after signing in: no open redirects. */
export const safeNext = (value, fallback = '/') => {
  const text = String(value ?? '');
  return text.startsWith('/') && !text.startsWith('//') && !text.startsWith('/\\') ? text : fallback;
};

/** Where to go after signing in: ?next=, then where the visitor came from, then home. */
export const destinationOf = ({ search = '', state = null } = {}) => {
  const next = new URLSearchParams(search).get('next');
  if (next) return safeNext(next);
  return safeNext(state?.from, '/');
};

/** Keep ?next= when switching between sign-in and sign-up. */
export const withNext = (path, destination) =>
  destination && destination !== '/' ? `${path}?next=${encodeURIComponent(destination)}` : path;
__LP_EOF__
echo "wrote apps/web/src/components/Auth/authModel.js"

mkdir -p apps/web/src/components/Auth
cat > apps/web/src/components/Auth/AuthShell.jsx <<'__LP_EOF__'
import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import './auth.css';

/**
 * The frame around sign-in and sign-up  (Landing)
 *
 * The homepage's slate board on one side — so going from "Create account" to
 * the form feels like the same place — and the form on a calm surface on the
 * other. On a phone the board shrinks to a header.
 */
export default function AuthShell({ title, lead, children, footer }) {
  useEffect(() => {
    const previous = document.title;
    document.title = `${title} | Classroom`;
    return () => {
      document.title = previous;
    };
  }, [title]);

  return (
    <div className="au">
      <aside className="au-board">
        <Link to="/" className="au-brand" aria-label="Classroom homepage">
          <svg className="au-brand__mark" viewBox="0 0 32 32" aria-hidden="true">
            <rect x="3" y="6" width="26" height="18" rx="4" />
            <path d="M11 29h10M16 24v5" />
            <circle cx="23" cy="11" r="2.4" />
          </svg>
          Classroom
        </Link>
        <div className="au-board__art" aria-hidden="true">
          <p className="au-board__big">Doors open in</p>
          <p className="au-board__count">4:59</p>
          <span className="au-board__track">
            <i />
          </span>
        </div>
        <p className="au-board__line">Live lessons, courses and your community. One sign-in for all of it.</p>
      </aside>

      <main className="au-main">
        <div className="au-card">
          <h1 className="au-title">{title}</h1>
          {lead ? <p className="au-lead">{lead}</p> : null}
          {children}
        </div>
        {footer ? <div className="au-footer">{footer}</div> : null}
      </main>
    </div>
  );
}
__LP_EOF__
echo "wrote apps/web/src/components/Auth/AuthShell.jsx"

mkdir -p apps/web/src/components/Auth
cat > apps/web/src/components/Auth/auth.css <<'__LP_EOF__'
/* Sign-in and sign-up — see components/Auth/AuthShell.jsx.
   Same palette and type as the homepage (components/Landing/landing.css). */

@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500..800&display=swap');

.au {
  --au-board: #15262b;
  --au-board-2: #1d353b;
  --au-board-3: #26444b;
  --au-chalk: #eef2ee;
  --au-chalk-2: rgba(238, 242, 238, 0.72);
  --au-chalk-3: rgba(238, 242, 238, 0.5);
  --au-sun: #ffd54a;
  --au-sun-ink: #2a2206;
  --au-sky: #8cc8ff;
  --au-danger: #ff9b91;
  --au-display: 'Bricolage Grotesque', 'Segoe UI', system-ui, sans-serif;
  --au-body: 'Atkinson Hyperlegible', system-ui, -apple-system, 'Segoe UI', sans-serif;

  min-height: 100vh;
  display: grid;
  grid-template-columns: minmax(320px, 0.9fr) minmax(0, 1.1fr);
  background: var(--au-board);
  color: var(--au-chalk);
  font-family: var(--au-body);
  font-size: 16.5px;
  line-height: 1.55;
}
.au :focus-visible { outline: 3px solid var(--au-sun); outline-offset: 2px; border-radius: 6px; }
.au a { color: var(--au-sky); }

.au-board {
  position: relative; display: flex; flex-direction: column; justify-content: space-between; gap: 32px;
  padding: 32px 40px 40px;
  background:
    radial-gradient(700px 400px at 20% 110%, rgba(255, 213, 74, 0.12), transparent 60%),
    radial-gradient(600px 400px at 110% -10%, rgba(140, 200, 255, 0.12), transparent 60%),
    var(--au-board-2);
  border-right: 1px solid rgba(238, 242, 238, 0.08);
  overflow: hidden;
}
.au-brand { display: inline-flex; align-items: center; gap: 10px; color: var(--au-chalk) !important; text-decoration: none; font: 750 20px/1 var(--au-display); }
.au-brand__mark { width: 28px; height: 28px; fill: none; stroke: var(--au-chalk); stroke-width: 2.2; stroke-linecap: round; }
.au-brand__mark circle { fill: var(--au-sun); stroke: none; }
.au-board__art { align-self: center; text-align: center; }
.au-board__big { margin: 0; color: var(--au-chalk-2); }
.au-board__count { margin: 0; font: 800 clamp(64px, 9vw, 120px) / 1 var(--au-display); font-variation-settings: 'wdth' 80; letter-spacing: -0.03em; font-variant-numeric: tabular-nums; }
.au-board__track { display: block; width: min(280px, 70%); height: 10px; margin: 18px auto 0; border-radius: 5px; background: rgba(238, 242, 238, 0.12); overflow: hidden; }
.au-board__track i { display: block; width: 72%; height: 100%; border-radius: 5px; background: repeating-linear-gradient(45deg, rgba(255, 213, 74, 0.8) 0 6px, rgba(255, 213, 74, 0.5) 6px 12px); }
.au-board__line { margin: 0; max-width: 24em; font: 700 22px/1.3 var(--au-display); letter-spacing: -0.01em; }

.au-main { display: flex; flex-direction: column; justify-content: center; align-items: center; gap: 20px; padding: 48px 24px; }
.au-card { width: 100%; max-width: 420px; }
.au-title { margin: 0; font: 800 clamp(32px, 4vw, 44px) / 1.05 var(--au-display); letter-spacing: -0.03em; }
.au-lead { margin: 10px 0 0; color: var(--au-chalk-2); }
.au-footer { width: 100%; max-width: 420px; color: var(--au-chalk-2); font-size: 15px; }
.au-footer p { margin: 6px 0; }

.au-form { display: grid; gap: 16px; margin-top: 28px; }
.au-field { display: grid; gap: 6px; }
.au-label { font-weight: 700; font-size: 15px; }
.au-hint { font-size: 13.5px; color: var(--au-chalk-3); }
.au-input-wrap { position: relative; }
.au-input {
  width: 100%; box-sizing: border-box; min-height: 48px; padding: 12px 14px; border-radius: 12px;
  border: 1px solid var(--au-board-3); background: var(--au-board-2); color: var(--au-chalk); font: inherit;
}
.au-input:focus { border-color: var(--au-sun); outline: none; box-shadow: 0 0 0 3px rgba(255, 213, 74, 0.25); }
.au-input[aria-invalid='true'] { border-color: var(--au-danger); }
.au-input--code { font-size: 22px; letter-spacing: 0.25em; text-align: center; }
.au-reveal { position: absolute; right: 8px; top: 50%; transform: translateY(-50%); padding: 6px 10px; border: 0; border-radius: 8px; background: transparent; color: var(--au-chalk-2); font: inherit; font-size: 14px; cursor: pointer; }
.au-reveal:hover { color: var(--au-chalk); }

.au-meter { display: flex; gap: 4px; margin-top: 2px; }
.au-meter i { flex: 1; height: 4px; border-radius: 2px; background: rgba(238, 242, 238, 0.12); transition: background-color 0.2s ease; }
.au-meter[data-level='1'] i:nth-child(-n + 1) { background: var(--au-danger); }
.au-meter[data-level='2'] i:nth-child(-n + 2) { background: var(--au-sun); }
.au-meter[data-level='3'] i:nth-child(-n + 3) { background: #b8e27a; }
.au-meter[data-level='4'] i { background: #7fd6b4; }

.au-button {
  display: inline-flex; align-items: center; justify-content: center; min-height: 50px; padding: 0 22px;
  border: 2px solid transparent; border-radius: 999px; font: 700 16px/1 var(--au-body); cursor: pointer; text-decoration: none;
}
.au-button--primary { background: var(--au-sun); color: var(--au-sun-ink); }
.au-button--primary:hover { background: #ffe07a; }
.au-button--primary:disabled { opacity: 0.6; cursor: default; }
.au-button--ghost { background: transparent; color: var(--au-chalk); border-color: rgba(238, 242, 238, 0.18); }
.au-button--ghost:hover { border-color: rgba(238, 242, 238, 0.4); }
.au-textbutton { justify-self: start; padding: 0; border: 0; background: none; color: var(--au-sky); font: inherit; font-size: 15px; cursor: pointer; text-decoration: underline; text-underline-offset: 3px; }

.au-or { display: flex; align-items: center; gap: 12px; color: var(--au-chalk-3); font-size: 14px; }
.au-or::before, .au-or::after { content: ''; flex: 1; height: 1px; background: rgba(238, 242, 238, 0.12); }

.au-alert { margin: 0; padding: 12px 14px; border-radius: 12px; font-size: 15px; }
.au-alert--error { background: rgba(255, 107, 94, 0.14); color: #ffc3bc; }
.au-alert--info { background: rgba(140, 200, 255, 0.12); color: #cfe6ff; }

@media (max-width: 860px) {
  .au { grid-template-columns: 1fr; }
  .au-board { flex-direction: row; align-items: center; padding: 18px 20px; border-right: 0; border-bottom: 1px solid rgba(238, 242, 238, 0.08); }
  .au-board__art { display: none; }
  .au-board__line { display: none; }
  .au-main { justify-content: flex-start; padding-top: 36px; }
}
@media (prefers-reduced-motion: reduce) { .au-meter i { transition: none; } }
__LP_EOF__
echo "wrote apps/web/src/components/Auth/auth.css"

mkdir -p apps/web/src/components/Auth/__checks__
cat > apps/web/src/components/Auth/__checks__/authModel.check.mjs <<'__LP_EOF__'
// Landing — sign-in and sign-up helpers.
// Run: node --test apps/web/src/components/Auth/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { destinationOf, passwordStrength, safeNext, validateSignup, withNext } from '../authModel.js';

test('password strength grows with length first', () => {
  assert.equal(passwordStrength(''), 0);
  assert.equal(passwordStrength('short'), 1);
  assert.equal(passwordStrength('abcdefghijkl'), 2);
  assert.equal(passwordStrength('Abcdefghijk1'), 3);
  assert.equal(passwordStrength('correct horse battery staple'), 4);
});

test('sign-up validation', () => {
  assert.deepEqual(validateSignup({ displayName: 'Anna', email: 'anna@example.com', password: 'twelve chars!' }), {});
  const errors = validateSignup({ displayName: ' ', email: 'anna@', password: 'short' });
  assert.ok(errors.displayName && errors.email && errors.password);
});

test('destinations after signing in never leave the app', () => {
  assert.equal(destinationOf({ search: '?next=%2Frooms%2Fnew' }), '/rooms/new');
  assert.equal(destinationOf({ search: '?next=https%3A%2F%2Fevil.example' }), '/');
  assert.equal(destinationOf({ search: '?next=%2F%2Fevil.example' }), '/');
  assert.equal(destinationOf({ state: { from: '/rooms/abc-defg-hjk/lobby' } }), '/rooms/abc-defg-hjk/lobby');
  assert.equal(destinationOf({}), '/');
  assert.equal(safeNext('/\\evil'), '/');
  assert.equal(withNext('/signup', '/rooms/new'), '/signup?next=%2Frooms%2Fnew');
  assert.equal(withNext('/signup', '/'), '/signup');
});
__LP_EOF__
echo "wrote apps/web/src/components/Auth/__checks__/authModel.check.mjs"

cat > .landing-patch.mjs <<'__LP_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Landing — edits to files that stay otherwise untouched.
 * Every anchor must be found as often as expected (once unless noted); if one
 * is not, nothing is written to any of these files and the installer stops.
 */

const REGISTER_ROUTE = `/**
 * Create an account (Landing). Answers like /login: the new account is signed
 * in at once. Refused when SIGNUP_MODE=closed; new accounts are learners.
 * Organisation and rules: identity/signup.js.
 */
router.post(
  '/register',
  rateLimit({ key: 'auth:register', points: 5, durationSec: 3600, by: ['ip'] }),
  validate({
    body: z.object({
      displayName: z.string().trim().min(1).max(80),
      email: z.string().trim().email().max(254),
      password: z.string().min(1).max(512),
      timeZone: z.string().max(64).optional(),
      locale: z.string().max(12).optional(),
      device: deviceSchema.optional(),
      wantsRefreshToken: z.boolean().default(false),
    }),
  }),
  route(async (req, res) => {
    const { registerOpen } = await import('../identity/signup.js');
    const helpers = await import('./_helpers.js');
    let tokens;
    try {
      tokens = await registerOpen({
        displayName: req.body.displayName,
        email: req.body.email,
        password: req.body.password,
        timeZone: req.body.timeZone ?? null,
        locale: req.body.locale ?? null,
        device: req.body.device ?? { platform: 'web' },
      });
    } catch (error) {
      if (error?.code === 'conflict') throw helpers.conflict(error.message);
      if (error?.code === 'forbidden') throw helpers.forbidden(error.message);
      if (error?.code === 'validation_failed') throw helpers.badRequest(error.message);
      throw error;
    }
    res.status(201);
    return respondWithSession(req, res, tokens);
  }),
);

/** Who am I`;

const plan = [
  {
    file: 'server/src/routes/auth.routes.js',
    marker: "'/register'",
    edits: [
      {
        name: 'create an account from the homepage',
        find: '/** Who am I',
        replace: REGISTER_ROUTE,
      },
    ],
  },
  {
    file: 'packages/core-client/src/CoreProvider.tsx',
    marker: 'signUp',
    edits: [
      {
        name: 'signUp() in the context type',
        find: '  completeSignIn(input: { challengeId: string; code: string }): Promise<Session>;\n',
        replace:
          '  /** Creates an account and signs it in (Landing). */\n' +
          '  signUp(input: { displayName: string; email: string; password: string }): Promise<Session>;\n' +
          '  completeSignIn(input: { challengeId: string; code: string }): Promise<Session>;\n',
      },
      {
        name: 'signUp() itself',
        find: "  const completeSignIn = useCallback<CoreContextValue['completeSignIn']>(\n",
        replace:
          "  const signUp = useCallback<CoreContextValue['signUp']>(\n" +
          '    async ({ displayName, email, password }) => {\n' +
          '      const headers = await csrfHeaders();\n' +
          '      let timeZone: string | undefined;\n' +
          '      try {\n' +
          '        timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;\n' +
          '      } catch {\n' +
          '        timeZone = undefined;\n' +
          '      }\n' +
          '      const language = (globalThis as { navigator?: { language?: string } }).navigator?.language;\n' +
          '      const result = (await http.post(\n' +
          "        '/auth/register',\n" +
          '        {\n' +
          '          displayName,\n' +
          '          email,\n' +
          '          password,\n' +
          '          timeZone,\n' +
          '          locale: language ? language.slice(0, 2).toLowerCase() : undefined,\n' +
          "          device: { platform: 'web' },\n" +
          '          wantsRefreshToken: true,\n' +
          '        },\n' +
          '        // Not retried: a second attempt would only meet "already exists".\n' +
          '        { anonymous: true, headers, retry: { attempts: 1 } },\n' +
          '      )) as TokenResponse;\n' +
          '      return adopt(result);\n' +
          '    },\n' +
          '    [http, csrfHeaders, adopt],\n' +
          '  );\n' +
          '\n' +
          "  const completeSignIn = useCallback<CoreContextValue['completeSignIn']>(\n",
      },
      {
        name: 'offered to the app',
        find: '      completeSignIn,\n',
        count: 2,
        replace: '      signUp,\n      completeSignIn,\n',
      },
    ],
  },
  {
    file: 'apps/web/src/main.jsx',
    marker: 'AuthGate',
    edits: [
      {
        name: 'the gate between homepage and app',
        find: "import AppLayout from './pages/AppLayout.jsx';\n",
        replace: "import AppLayout from './pages/AppLayout.jsx';\nimport AuthGate from './components/system/AuthGate.jsx';\n",
      },
      {
        name: 'the new pages, loaded on demand',
        find: "const RoomLobbyPage = lazy(() => import('./pages/RoomLobbyPage.jsx'));\n",
        replace:
          "const RoomLobbyPage = lazy(() => import('./pages/RoomLobbyPage.jsx'));\n" +
          "const SignupPage = lazy(() => import('./pages/SignupPage.jsx'));\n" +
          "const LandingPage = lazy(() => import('./pages/LandingPage.jsx'));\n",
      },
      {
        name: 'sign-up and the homepage for everyone',
        find: '              <Route path="/login" element={<LoginPage />} />\n',
        replace:
          '              <Route path="/login" element={<LoginPage />} />\n' +
          '              <Route path="/signup" element={<SignupPage />} />\n' +
          '              <Route path="/register" element={<Navigate to="/signup" replace />} />\n' +
          '              {/* The homepage, also for signed-in people who want to see or share it. */}\n' +
          '              <Route path="/welcome" element={<LandingPage />} />\n',
      },
      {
        name: 'signed out: "/" is the homepage, the rest asks to sign in',
        find: '              <Route element={<AppLayout />}>\n',
        replace: '              <Route element={<AuthGate />}>\n              <Route element={<AppLayout />}>\n',
      },
      {
        name: 'close the gate',
        find: '                <Route path="rooms/:code/edit" element={<RoomEditorPage />} />\n              </Route>\n',
        replace:
          '                <Route path="rooms/:code/edit" element={<RoomEditorPage />} />\n' +
          '              </Route>\n' +
          '              </Route>\n',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed in any patched file.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = src.split(edit.find).length - 1;
    const expected = edit.count ?? 1;
    if (n !== expected) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor ${expected}×, found ${n}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.split(edit.find).join(edit.replace);
  results.push({ ...entry, src });
}

for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__LP_EOF__
node .landing-patch.mjs
rm -f .landing-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.tsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.tsx=tsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error --define:__RELEASE_SHA__=0 >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo "A file did not pass its check (see above). Undo with: bash landing-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs \
  apps/web/src/components/Landing/__checks__/*.check.mjs apps/web/src/components/Auth/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .landing-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .landing-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .landing-test.log
else
  cat .landing-test.log
  rm -f .landing-test.log
  echo "The rule checks failed (see above). Undo with: bash landing-install.sh --restore" >&2
  exit 1
fi

touch server/src/server.js
echo
echo "Homepage installed. The API restarts on its own; Vite picks up the new pages."
echo "Open the app signed out (a private window) to see the homepage at /,"
echo "and /welcome to see it while signed in."
if grep -qE '^SIGNUP_MODE=closed' .env 2>/dev/null; then
  echo "Note: SIGNUP_MODE=closed in .env — the sign-up form will refuse new accounts."
fi