import { useEffect, useMemo, useRef } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { createAccountApi, createProfileApi, useCore } from '@classroom/core-client';
import ErrorBoundary from '../components/system/ErrorBoundary.jsx';
import NotificationToasts from '../components/system/NotificationToasts.jsx';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';
import { onServiceWorkerMessage, resyncPush } from '../lib/pushClient.js';
import { onUserEvent } from '../lib/userEvents.js';

/**
 * The shell every page except the classroom renders inside.
 *
 * The boundary sits around <Outlet/> rather than around the whole layout, so a
 * page that throws loses the page and keeps the navigation — a user who can
 * still click away from a broken screen is not stuck.
 *
 * Phase B adds three invisible helpers: SessionWatch (a device signed out
 * from elsewhere goes back to the sign-in page), NotificationToasts (a new
 * notification shows on screen) and live preference sync.
 */
export default function AppLayout() {
  return (
    <div className="app">
      <PreferencesSync />
      <SessionWatch />
      <header className="app__bar">
        <span className="app__brand">Classroom</span>
        <nav className="app__nav">
          <NavLink to="/" end>
            Dashboard
          </NavLink>
          <NavLink to="/community">Community</NavLink>
          <NavLink to="/messages">Messages</NavLink>
          <NavLink to="/media">Media</NavLink>
          <NavLink to="/settings">Settings</NavLink>
        </nav>
      </header>

      <main className="app__content">
        <ErrorBoundary area="page">
          <Outlet />
        </ErrorBoundary>
      </main>

      <NotificationToasts />
    </div>
  );
}

/**
 * Brings this device's copy of the account preferences up to date once per
 * sign-in and whenever they change on another device, so a change made there
 * (font size, how lessons start) applies here too. Also keeps this browser's
 * push registration current. Renders nothing; a failure leaves the cached
 * copy in use.
 */
function PreferencesSync() {
  const core = useCore();
  const { http, status } = core;
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const account = useMemo(() => createAccountApi(http), [http]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    let cancelled = false;

    const sync = () =>
      Promise.all([profiles.getPreferences(), profiles.getOwn()])
        .then(([preferences, own]) => {
          if (cancelled) return;
          cachePreferences(preferences);
          cacheLocale(own.locale);
        })
        .catch(() => undefined);

    sync();
    resyncPush({ account }).catch(() => undefined);

    let timer = null;
    const offLive = onUserEvent(core, 'settings:changed', (payload) => {
      if (payload?.section && !['preferences', 'profile'].includes(payload.section)) return;
      window.clearTimeout(timer);
      timer = window.setTimeout(sync, 150);
    });
    const offWorker = onServiceWorkerMessage((message) => {
      if (message.type === 'push-subscription-changed') resyncPush({ account }).catch(() => undefined);
    });

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      offLive();
      offWorker();
    };
  }, [core, profiles, account, status]);

  return null;
}

/** Core states that mean nobody is signed in (a refresh in progress is not one of them). */
const SIGNED_OUT = new Set(['anonymous', 'unauthenticated', 'signed-out', 'signedOut', 'logged-out']);

/**
 * This device was signed out — from Settings on another device, or because
 * its session expired. The server tells open tabs (session:revoked); the core
 * learns it at the latest on its next request. Either way: back to sign-in.
 */
function SessionWatch() {
  const core = useCore();
  const { status } = core;
  const navigate = useNavigate();
  const previous = useRef(status);

  useEffect(() => {
    if (previous.current === 'authenticated' && SIGNED_OUT.has(status)) {
      navigate('/login', { replace: true, state: { reason: 'signed-out' } });
    }
    previous.current = status;
  }, [status, navigate]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    return onUserEvent(core, 'session:revoked', () => {
      const signOut = core.signOut ?? core.logout ?? core.auth?.signOut ?? core.auth?.logout;
      Promise.resolve(typeof signOut === 'function' ? signOut() : undefined)
        .catch(() => undefined)
        .finally(() => navigate('/login', { replace: true, state: { reason: 'signed-out-remotely' } }));
    });
  }, [core, status, navigate]);

  return null;
}
