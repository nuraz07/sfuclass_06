import { useEffect, useMemo } from 'react';
import { NavLink, Outlet } from 'react-router-dom';
import { createProfileApi, useCore } from '@classroom/core-client';
import ErrorBoundary from '../components/system/ErrorBoundary.jsx';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';

/**
 * The shell every page except the classroom renders inside.
 *
 * The boundary sits around <Outlet/> rather than around the whole layout, so a
 * page that throws loses the page and keeps the navigation — a user who can
 * still click away from a broken screen is not stuck.
 */
export default function AppLayout() {
  return (
    <div className="app">
      <PreferencesSync />
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
    </div>
  );
}

/**
 * Brings this device's copy of the account preferences up to date once per
 * sign-in, so a change made on another device (font size, how lessons start)
 * applies here too. Renders nothing; a failure leaves the cached copy in use.
 */
function PreferencesSync() {
  const { http, status } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    let cancelled = false;
    Promise.all([profiles.getPreferences(), profiles.getOwn()])
      .then(([preferences, own]) => {
        if (cancelled) return;
        cachePreferences(preferences);
        cacheLocale(own.locale);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [profiles, status]);

  return null;
}
