import { Suspense, lazy, useEffect, useState } from 'react';
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useCore } from '@classroom/core-client';

const LandingPage = lazy(() => import('../../pages/LandingPage.jsx'));

/**
 * The server did not answer while your session was being resumed (it may be
 * restarting). The session is kept; this retries by itself and signs you in
 * the moment the server is back.
 */
function ReconnectNotice({ restore }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, []);
  const seconds = restore.nextRetryAt ? Math.max(0, Math.ceil((restore.nextRetryAt - now) / 1000)) : 0;
  return (
    <div className="app app-empty" role="status" aria-live="polite" style={{ display: 'grid', placeItems: 'center', minHeight: '60vh', textAlign: 'center', gap: 12, padding: 24 }}>
      <div style={{ display: 'grid', gap: 10, maxWidth: 420 }}>
        <strong style={{ fontSize: 18 }}>Reconnecting to the server…</strong>
        <span>You are still signed in. As soon as the server answers, you are back where you were.</span>
        <span style={{ opacity: 0.7, fontSize: 14 }}>{seconds > 0 ? `Next try in ${seconds} s` : 'Trying now…'}</span>
        <span style={{ display: 'flex', gap: 10, justifyContent: 'center', flexWrap: 'wrap', marginTop: 4 }}>
          <button type="button" className="btn btn--primary" onClick={restore.retryNow}>
            Try now
          </button>
          <button type="button" className="btn" onClick={restore.signInInstead}>
            Go to sign-in
          </button>
        </span>
      </div>
    </div>
  );
}

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
  const { status, restore } = useCore();
  const location = useLocation();

  if (status === 'authenticated') return <Outlet />;
  if (status === 'restoring') return restore?.reconnecting ? <ReconnectNotice restore={restore} /> : <p className="app app-empty">Loading…</p>;

  if (location.pathname === '/') {
    return (
      <Suspense fallback={<p className="app app-empty">Loading…</p>}>
        <LandingPage />
      </Suspense>
    );
  }
  return <Navigate to="/login" replace state={{ from: `${location.pathname}${location.search}` }} />;
}
