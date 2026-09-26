import { useCallback, useEffect, useMemo, useState } from 'react';
import { createAccountSecurityApi, useCore } from '@classroom/core-client';
import { Section } from './fields.jsx';
import ConfirmIdentity from './ConfirmIdentity.jsx';
import { formatDate } from '../../lib/preferences.js';

/**
 * Your data  (Settings, Phase C)
 *
 *   export     everything the platform keeps about you, as one JSON file
 *   delete     the account, after 14 days in which signing in and pressing
 *              Cancel keeps it. Messages and posts stay in their chats and
 *              courses as "Deleted user"; everything personal goes.
 */

const saveJson = (data) => {
  const date = new Date().toISOString().slice(0, 10);
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = `classroom-export-${date}.json`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
};

export default function DataSettings({ announce, reloadKey }) {
  const { http, signOut } = useCore();
  const security = useMemo(() => createAccountSecurityApi(http), [http]);
  const [overview, setOverview] = useState(null);
  const [exporting, setExporting] = useState(false);
  const [confirming, setConfirming] = useState(false);

  const load = useCallback(async () => {
    try {
      setOverview(await security.overview());
    } catch {
      setOverview((current) => current ?? { deletion: null, twoStep: { required: false } });
    }
  }, [security]);

  useEffect(() => {
    load();
  }, [load, reloadKey]);

  const exportData = async () => {
    setExporting(true);
    try {
      saveJson(await security.exportData());
      announce('Your data was downloaded.');
    } catch (cause) {
      announce(cause?.detail ?? 'The download could not be prepared. Try again later.', null, true);
    } finally {
      setExporting(false);
    }
  };

  const cancelDeletion = async () => {
    try {
      await security.cancelDeletion();
      announce('Your account will not be deleted.');
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'The deletion could not be cancelled.', null, true);
    }
  };

  if (!overview) return <p className="st-hint">Loading…</p>;
  const scheduled = overview.deletion?.scheduledFor ?? null;

  return (
    <>
      <Section
        id="export"
        title="Download your data"
        hint="Your account, profile and settings, devices and history, messages and posts you wrote, courses, progress and notifications — as one JSON file. Passwords and keys are never included."
      >
        <button type="button" className="btn" onClick={exportData} disabled={exporting}>
          {exporting ? 'Preparing…' : 'Download my data'}
        </button>
      </Section>

      <Section id="delete-account" title="Delete your account">
        {scheduled ? (
          <div className="st-danger-zone">
            <p className="st-label">Your account will be deleted on {formatDate(scheduled)}.</p>
            <p className="st-hint">Until then it works as usual. After that date it cannot be restored.</p>
            <button type="button" className="btn" onClick={cancelDeletion}>
              Keep my account
            </button>
          </div>
        ) : (
          <div className="st-danger-zone">
            <p className="st-hint">
              Your name, email, profile, settings, notifications, passkeys and two-step sign-in are removed. Messages,
              posts and grades stay in their chats and courses, shown as “Deleted user”. You have 14 days to change your
              mind: sign in and press “Keep my account”. Every other device is signed out now.
            </p>
            {confirming ? (
              <ConfirmIdentity
                action="Delete my account"
                danger
                codeAllowed={overview.twoStep?.required}
                onCancel={() => setConfirming(false)}
                onConfirm={async (confirmation) => {
                  const result = await security.requestDeletion(confirmation);
                  setConfirming(false);
                  announce(`Your account will be deleted on ${formatDate(result.deletion.scheduledFor)}.`);
                  await load();
                }}
              />
            ) : (
              <div className="st-inline">
                <button type="button" className="btn btn--danger" onClick={() => setConfirming(true)}>
                  Delete my account…
                </button>
                <button type="button" className="btn btn--tiny" onClick={() => signOut().catch(() => undefined)}>
                  Just sign out
                </button>
              </div>
            )}
          </div>
        )}
      </Section>
    </>
  );
}
