import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { createAccountSecurityApi, useCore } from '@classroom/core-client';
import { onUserEvent } from '../../lib/userEvents.js';
import { formatDate } from '../../lib/preferences.js';
import './notifications.css';

/**
 * "Your account will be deleted on …"  (Settings, Phase C)
 *
 * Shown on every page while an account is in its grace period, with the one
 * button that matters. Reloads when security settings change on another
 * device, so cancelling on the phone clears it on the laptop.
 */
export default function DeletionBanner() {
  const core = useCore();
  const { http, status } = core;
  const security = useMemo(() => createAccountSecurityApi(http), [http]);
  const [scheduledFor, setScheduledFor] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setScheduledFor((await security.overview()).deletion?.scheduledFor ?? null);
    } catch {
      // No banner is better than a wrong one.
    }
  }, [security]);

  useEffect(() => {
    if (status !== 'authenticated') {
      setScheduledFor(null);
      return undefined;
    }
    load();
    return onUserEvent(core, 'settings:changed', (payload) => {
      if (!payload?.section || payload.section === 'security') load();
    });
  }, [core, status, load]);

  if (!scheduledFor) return null;

  const keep = async () => {
    setBusy(true);
    try {
      await security.cancelDeletion();
      setScheduledFor(null);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="nt-banner" role="alert">
      <span>
        Your account will be deleted on <strong>{formatDate(scheduledFor)}</strong>.{' '}
        <Link to="/settings/data">Details</Link>
      </span>
      <button type="button" className="nt-banner__action" onClick={keep} disabled={busy}>
        Keep my account
      </button>
    </div>
  );
}
