import { useCallback } from 'react';
import { Section } from './fields.jsx';
import { HistoryList } from './SecuritySettings.jsx';

/**
 * Recent changes  (Settings, Phase B)
 *
 * Every settings change on the account, with the device it was made on — so a
 * change nobody here made stands out. The names of the settings are shown,
 * never their values.
 */
export default function ActivitySettings({ account, onJump, reloadKey }) {
  const load = useCallback((query) => account.activity(query), [account]);
  return (
    <Section
      id="changes"
      title="Recent changes"
      hint="Changes to your settings and devices you signed out, newest first."
    >
      <HistoryList load={load} empty="Nothing has been changed yet." reloadKey={reloadKey} />
      <p className="st-hint">
        A change you did not make?{' '}
        <button type="button" className="st-linkbutton" onClick={() => onJump('security', 'sessions')}>
          Check where you are signed in
        </button>
        .
      </p>
    </Section>
  );
}
