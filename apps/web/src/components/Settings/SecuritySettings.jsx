import { useCallback, useEffect, useMemo, useState } from 'react';
import { createAccountSecurityApi, useCore } from '@classroom/core-client';
import { Section } from './fields.jsx';
import { PasskeySection, PasswordSection, TwoStepSection } from './AccountProtection.jsx';
import { describeHistoryEntry, relativeTime } from './notificationsModel.js';
import { formatDate, formatTime } from '../../lib/preferences.js';

/**
 * Sign-in & devices  (Settings, Phase B + C)
 *
 * Phase C puts password, two-step sign-in and passkeys at the top
 * (AccountProtection.jsx).
 *
 * Every device signed in to the account, this one marked, each with a way to
 * sign it out; "sign out everywhere else"; and the sign-ins and failed
 * attempts of the last weeks. A device that is signed out here stops at once:
 * its next request is refused and its open tabs return to the sign-in page.
 */

const when = (value) => (value ? `${formatDate(value)}, ${formatTime(value)}` : '');

export function HistoryList({ load, empty, reloadKey }) {
  const [items, setItems] = useState(null);
  const [cursor, setCursor] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);

  const fetchPage = useCallback(
    async (from = null) => {
      setBusy(true);
      setError(false);
      try {
        const page = await load({ cursor: from, limit: 20 });
        setItems((current) => (from ? [...(current ?? []), ...page.items] : page.items));
        setCursor(page.nextCursor);
      } catch {
        setError(true);
        setItems((current) => current ?? []);
      } finally {
        setBusy(false);
      }
    },
    [load],
  );

  useEffect(() => {
    fetchPage(null);
  }, [fetchPage, reloadKey]);

  if (items === null) return <p className="st-hint">Loading…</p>;

  return (
    <>
      {error ? <p className="st-error">The history could not be loaded.</p> : null}
      {items.length === 0 && !error ? <p className="st-hint">{empty}</p> : null}
      <ul className="st-history">
        {items.map((entry) => (
          <li key={entry.id} className={entry.action === 'auth.login.failed' ? 'st-history__item is-warning' : 'st-history__item'}>
            <span className="st-history__what">{describeHistoryEntry(entry)}</span>
            <span className="st-hint">
              {when(entry.at)}
              {entry.device ? ` · ${entry.device}` : ''}
              {entry.ip ? ` · ${entry.ip}` : ''}
            </span>
          </li>
        ))}
      </ul>
      {cursor ? (
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => fetchPage(cursor)}>
          {busy ? 'Loading…' : 'Show older'}
        </button>
      ) : null}
    </>
  );
}

/** Password, two-step sign-in and passkeys, loaded together. */
function Protection({ announce, reloadKey }) {
  const { http } = useCore();
  const security = useMemo(() => createAccountSecurityApi(http), [http]);
  const [overview, setOverview] = useState(null);
  const [failed, setFailed] = useState(false);

  const reload = useCallback(async () => {
    try {
      setOverview(await security.overview());
      setFailed(false);
    } catch {
      setFailed(true);
    }
  }, [security]);

  useEffect(() => {
    reload();
  }, [reload, reloadKey]);

  if (failed && !overview) {
    return (
      <Section id="password" title="Password and two-step sign-in">
        <p className="st-error">These settings could not be loaded.</p>
        <button type="button" className="btn" onClick={reload}>
          Try again
        </button>
      </Section>
    );
  }
  if (!overview) return <p className="st-hint">Loading…</p>;

  const props = { security, overview, announce, reload };
  return (
    <>
      <PasswordSection {...props} />
      <TwoStepSection {...props} />
      <PasskeySection {...props} />
    </>
  );
}

export default function SecuritySettings({ account, announce, reloadKey }) {
  const [sessions, setSessions] = useState(null);
  const [confirming, setConfirming] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setSessions((await account.listSessions()).items);
    } catch {
      setSessions([]);
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load, reloadKey]);

  const signOut = async (session) => {
    setBusy(true);
    try {
      await account.signOutSession(session.sessionId);
      announce(`${session.label} was signed out.`);
      setConfirming(null);
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'That device could not be signed out.', null, true);
    } finally {
      setBusy(false);
    }
  };

  const signOutOthers = async () => {
    setBusy(true);
    try {
      const { revoked } = await account.signOutOtherSessions();
      announce(revoked === 0 ? 'No other device was signed in.' : `Signed out ${revoked} ${revoked === 1 ? 'device' : 'devices'}.`);
      setConfirming(null);
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'The other devices could not be signed out.', null, true);
    } finally {
      setBusy(false);
    }
  };

  const others = (sessions ?? []).filter((session) => !session.current);
  const loadHistory = useCallback((query) => account.loginHistory(query), [account]);

  return (
    <>
      <Protection announce={announce} reloadKey={reloadKey} />

      <Section
        id="sessions"
        title="Where you are signed in"
        hint="Something you do not recognise? Sign it out, then change your password."
      >
        {sessions === null ? <p className="st-hint">Loading…</p> : null}
        {sessions?.map((session) => (
          <div key={session.sessionId} className="st-session">
            <div className="st-session__info">
              <span className="st-label">
                {session.label}
                {session.current ? <span className="st-badge">This device</span> : null}
              </span>
              <span className="st-hint">
                {session.current ? 'Active now' : `Last active ${relativeTime(session.lastActiveAt) || 'unknown'}`}
                {session.ip ? ` · ${session.ip}` : ''}
                {session.createdAt ? ` · signed in ${when(session.createdAt)}` : ''}
              </span>
            </div>
            {session.current ? null : confirming === session.sessionId ? (
              <span className="st-inline">
                <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => signOut(session)}>
                  Sign out
                </button>
                <button type="button" className="btn btn--tiny" onClick={() => setConfirming(null)}>
                  Cancel
                </button>
              </span>
            ) : (
              <button type="button" className="btn btn--tiny" onClick={() => setConfirming(session.sessionId)}>
                Sign out…
              </button>
            )}
          </div>
        ))}
      </Section>

      <Section id="sign-out-others" title="Sign out everywhere else" hint="Every device except this one has to sign in again.">
        {confirming === 'others' ? (
          <span className="st-inline">
            <span>Sign out {others.length} {others.length === 1 ? 'device' : 'devices'}?</span>
            <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={signOutOthers}>
              Sign them out
            </button>
            <button type="button" className="btn btn--tiny" onClick={() => setConfirming(null)}>
              Cancel
            </button>
          </span>
        ) : (
          <button type="button" className="btn" disabled={others.length === 0} onClick={() => setConfirming('others')}>
            Sign out all other devices
          </button>
        )}
      </Section>

      <Section id="login-history" title="Sign-in history" hint="Sign-ins and failed attempts on your account.">
        <HistoryList load={loadHistory} empty="No sign-ins recorded yet." reloadKey={reloadKey} />
      </Section>
    </>
  );
}
