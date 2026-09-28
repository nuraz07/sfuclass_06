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
