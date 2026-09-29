import { useState } from 'react';
import { REPORT_REASONS } from './hubModel.js';

/**
 * "Report" — opens a small form in place. Reports go to the space's
 * moderators; the person reported is not told who reported them.
 */
export default function ReportButton({ hub, spaceId, targetType, targetId, label = 'Report' }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('harassment');
  const [note, setNote] = useState('');
  const [state, setState] = useState('idle');

  if (state === 'sent') return <span className="hb-muted">Reported. Thank you.</span>;
  if (!open) {
    return (
      <button type="button" className="hb-link hb-link--quiet" onClick={() => setOpen(true)}>
        {label}
      </button>
    );
  }
  const send = async () => {
    setState('sending');
    try {
      await hub.report(spaceId, { targetType, targetId, reason, note: note.trim() || null });
      setState('sent');
    } catch {
      setState('error');
    }
  };
  return (
    <div className="hb-report" role="group" aria-label="Report">
      <select className="hb-input" value={reason} onChange={(event) => setReason(event.target.value)} aria-label="Reason">
        {REPORT_REASONS.map((entry) => (
          <option key={entry.value} value={entry.value}>
            {entry.label}
          </option>
        ))}
      </select>
      <input className="hb-input" placeholder="Anything moderators should know (optional)" maxLength={500} value={note} onChange={(event) => setNote(event.target.value)} />
      <div className="hb-inline">
        <button type="button" className="btn btn--danger btn--tiny" disabled={state === 'sending'} onClick={send}>
          Send report
        </button>
        <button type="button" className="hb-link" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
      {state === 'error' ? <p className="hb-error">The report was not sent. Try again.</p> : null}
    </div>
  );
}
