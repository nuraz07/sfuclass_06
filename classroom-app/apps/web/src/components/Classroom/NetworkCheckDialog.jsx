// apps/web/src/components/Classroom/NetworkCheckDialog.jsx
//
// Pre-join network test (architecture doc, section 4.6 step 1). Shown from the waiting room / lesson lobby before
// the learner joins, and on demand from the "Test my connection" link. It answers two questions in plain language:
// "Will video work on this network?" and "If not, what should I tell my IT department?"
//
// What is measured (by core-client ConnectivityProbe — this component is UI only):
//   stun      UDP to the regional STUN endpoint → a server-reflexive candidate. Proxy for direct UDP media,
//             which the SFU uses whenever it can.
//   turnUdp   TURN relay over UDP 3478          ┐ each gathers a relay candidate with short-lived probe
//   turnTcp   TURN relay over TCP 3478          │ credentials (POST /rtc/ice-servers, purpose "probe")
//   turnTls   TURN relay over TLS 443           ┘ — the path that works through HTTPS-only firewalls
//   regions   srflx gathering time per region ≈ RTT → region hint for the join (server/src/rtc/RegionHint.js)
//
// Verdicts (from the probe): direct (all good) · relay (UDP to media blocked, relay works) · tls-only (only TURN over
// TLS 443 works — still usable) · blocked (nothing works: show the IT-department guidance and published ranges).
//
// Contract with packages/core-client (ConnectivityProbe.ts, exported from '@classroom/core-client'):
//   runConnectivityProbe({ signal, onProgress }) → Promise<ProbeReport>
//     onProgress(checkId, { status: 'running'|'pass'|'fail'|'skipped', rttMs?, detail? })
//     ProbeReport = { checks: { stun, turnUdp, turnTcp, turnTls }, regionHint: [{ region, rttMs }],
//                     bestRegion, verdict: 'direct'|'relay'|'tls-only'|'blocked', startedAt, durationMs }
//   The report never contains credentials, candidates or IP addresses, so "Copy report" is safe to share.
//
// Props:
//   open          boolean
//   onClose()     dialog dismissed (Escape, backdrop, Close)
//   onContinue(report)   user proceeds; the caller passes report.regionHint into room.join
//   helpUrl       link to the customer-firewall guide (ops/runbooks/customer-firewall.md, published version)
//   autoStart     start the test when the dialog opens (default true)
//
// Owner: F8 Real-Time Connectivity.

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { runConnectivityProbe } from '@classroom/core-client';

const CHECKS = [
  { id: 'stun', label: 'Direct connection (UDP)', hint: 'Best quality. Often blocked on corporate and school networks.' },
  { id: 'turnUdp', label: 'Relay over UDP (port 3478)', hint: 'Used when a direct connection is not possible.' },
  { id: 'turnTcp', label: 'Relay over TCP (port 3478)', hint: 'Used when UDP is blocked.' },
  { id: 'turnTls', label: 'Relay over HTTPS port (TLS 443)', hint: 'Works through most firewalls that allow websites.' },
];

const VERDICTS = {
  direct: {
    tone: 'success',
    title: 'Your connection is ready',
    body: 'Audio, video and screen sharing will use a direct connection.',
  },
  relay: {
    tone: 'success',
    title: 'Your connection is ready',
    body: 'Your network blocks direct media, so the class will run through a relay server. Quality is usually unaffected.',
  },
  'tls-only': {
    tone: 'warning',
    title: 'Your connection will work with limitations',
    body: 'Only the HTTPS port is open on this network. The class will work, but video may adapt to lower quality on busy networks.',
  },
  blocked: {
    tone: 'danger',
    title: 'Video cannot connect on this network',
    body: 'None of the connection methods got through. Try another network (for example a mobile hotspot) or ask your IT department to allow the addresses in our network guide.',
  },
};

const STATUS_TEXT = { pending: 'Waiting', running: 'Testing…', pass: 'Works', fail: 'Blocked', skipped: 'Not tested' };
const STATUS_ICON = { pending: '○', running: '◌', pass: '✓', fail: '✕', skipped: '–' };

const initialChecks = () => Object.fromEntries(CHECKS.map((c) => [c.id, { status: 'pending' }]));

export default function NetworkCheckDialog({ open, onClose, onContinue, helpUrl, autoStart = true }) {
  const dialogRef = useRef(null);
  const abortRef = useRef(null);
  const titleId = useId();
  const liveId = useId();
  const [phase, setPhase] = useState('idle'); // idle | running | done | error
  const [checks, setChecks] = useState(initialChecks);
  const [report, setReport] = useState(null);
  const [error, setError] = useState(null);
  const [copied, setCopied] = useState(false);

  const run = useCallback(async () => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setPhase('running');
    setChecks(initialChecks());
    setReport(null);
    setError(null);
    setCopied(false);
    try {
      const result = await runConnectivityProbe({
        signal: controller.signal,
        onProgress: (id, state) => {
          if (!controller.signal.aborted) setChecks((prev) => ({ ...prev, [id]: state }));
        },
      });
      if (controller.signal.aborted) return;
      setChecks((prev) => ({ ...prev, ...result.checks }));
      setReport(result);
      setPhase('done');
    } catch (err) {
      if (controller.signal.aborted) return;
      setError(err?.status === 401 ? 'Your session has expired. Please sign in again.' : 'The network test could not be completed.');
      setPhase('error');
    }
  }, []);

  // Open/close the native modal dialog (focus trap, Escape and inert background come from the platform).
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      if (typeof dialog.showModal === 'function') dialog.showModal();
      else dialog.setAttribute('open', '');
    } else if (!open && dialog.open) {
      if (typeof dialog.close === 'function') dialog.close();
      else dialog.removeAttribute('open');
    }
  }, [open]);

  // Run the probe while the dialog is open; abort it when the dialog closes or unmounts
  // (also correct under React StrictMode's mount → unmount → mount in development).
  useEffect(() => {
    if (!open || !autoStart) return undefined;
    run();
    return () => abortRef.current?.abort();
  }, [open, autoStart, run]);

  useEffect(() => () => abortRef.current?.abort(), []);

  const handleCancel = (event) => {
    event.preventDefault(); // Escape: let the parent own the open state
    onClose?.();
  };

  const verdict = report ? VERDICTS[report.verdict] ?? VERDICTS.blocked : null;
  const canContinue = phase === 'done' && report?.verdict !== 'blocked';

  const summary = useMemo(() => {
    if (phase === 'running') return 'Testing your connection';
    if (phase === 'done' && verdict) return verdict.title;
    if (phase === 'error') return error;
    return '';
  }, [phase, verdict, error]);

  const copyReport = async () => {
    if (!report) return;
    const text = JSON.stringify({
      verdict: report.verdict,
      checks: Object.fromEntries(Object.entries(report.checks).map(([k, v]) => [k, { status: v.status, rttMs: v.rttMs ?? null }])),
      regions: report.regionHint,
      startedAt: report.startedAt,
      userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : undefined,
    }, null, 2);
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  return (
    <dialog
      ref={dialogRef}
      aria-labelledby={titleId}
      aria-describedby={liveId}
      onCancel={handleCancel}
      onClick={(event) => {
        if (event.target === dialogRef.current) onClose?.(); // backdrop click
      }}
      style={styles.dialog}
    >
      <div style={styles.body}>
        <h2 id={titleId} style={styles.title}>Network check</h2>
        <p id={liveId} role="status" aria-live="polite" style={styles.summary}>{summary}</p>

        <ul style={styles.list} aria-label="Connection methods">
          {CHECKS.map((check) => {
            const state = checks[check.id] ?? { status: 'pending' };
            return (
              <li key={check.id} style={styles.row} data-check={check.id} data-status={state.status}>
                <span aria-hidden="true" style={{ ...styles.icon, color: toneColor(statusTone(state.status)) }}>
                  {STATUS_ICON[state.status] ?? STATUS_ICON.pending}
                </span>
                <span style={styles.label}>
                  <span style={styles.labelText}>{check.label}</span>
                  <span style={styles.hint}>{check.hint}</span>
                </span>
                <span style={styles.status}>
                  {STATUS_TEXT[state.status] ?? STATUS_TEXT.pending}
                  {state.status === 'pass' && Number.isFinite(state.rttMs) ? ` · ${Math.round(state.rttMs)} ms` : ''}
                </span>
              </li>
            );
          })}
        </ul>

        {phase === 'done' && verdict && (
          <div role="note" style={{ ...styles.verdict, borderColor: toneColor(verdict.tone) }} data-verdict={report.verdict}>
            <strong style={styles.verdictTitle}>{verdict.title}</strong>
            <p style={styles.verdictBody}>{verdict.body}</p>
            {report.bestRegion && (
              <p style={styles.meta}>
                Nearest media region: {report.bestRegion}
                {Number.isFinite(report.regionHint?.[0]?.rttMs) ? ` (${Math.round(report.regionHint[0].rttMs)} ms)` : ''}
              </p>
            )}
            {report.verdict !== 'direct' && helpUrl && (
              <p style={styles.meta}>
                <a href={helpUrl} target="_blank" rel="noopener noreferrer">Network guide for IT departments</a>
              </p>
            )}
          </div>
        )}

        {phase === 'error' && <p role="alert" style={{ ...styles.verdict, borderColor: toneColor('danger') }}>{error}</p>}

        <div style={styles.actions}>
          {phase === 'done' && (
            <button type="button" onClick={copyReport} style={styles.secondary}>
              {copied ? 'Report copied' : 'Copy report'}
            </button>
          )}
          {(phase === 'done' || phase === 'error' || phase === 'idle') && (
            <button type="button" onClick={run} style={styles.secondary}>
              {phase === 'idle' ? 'Start test' : 'Run again'}
            </button>
          )}
          <button type="button" onClick={() => onClose?.()} style={styles.secondary}>Close</button>
          <button
            type="button"
            onClick={() => onContinue?.(report)}
            disabled={!canContinue}
            aria-disabled={!canContinue}
            style={{ ...styles.primary, opacity: canContinue ? 1 : 0.5 }}
          >
            Continue to class
          </button>
        </div>
      </div>
    </dialog>
  );
}

function statusTone(status) {
  if (status === 'pass') return 'success';
  if (status === 'fail') return 'danger';
  return 'muted';
}

// Colours come from packages/ui-tokens (exposed as CSS custom properties by the app shell); the fallbacks keep the
// component readable when rendered in isolation (tests, Storybook).
function toneColor(tone) {
  return {
    success: 'var(--color-success, #1a7f37)',
    warning: 'var(--color-warning, #9a6700)',
    danger: 'var(--color-danger, #cf222e)',
    muted: 'var(--color-text-muted, #656d76)',
  }[tone];
}

const styles = {
  dialog: {
    border: 'none',
    borderRadius: 'var(--radius-lg, 12px)',
    padding: 0,
    width: 'min(560px, calc(100vw - 32px))',
    color: 'var(--color-text, #1f2328)',
    background: 'var(--color-surface, #ffffff)',
    boxShadow: '0 12px 40px rgba(0,0,0,0.25)',
  },
  body: { padding: 'var(--space-6, 24px)', display: 'grid', gap: 'var(--space-4, 16px)' },
  title: { margin: 0, fontSize: 'var(--font-size-lg, 1.25rem)' },
  summary: { margin: 0, color: 'var(--color-text-muted, #656d76)', minHeight: '1.25em' },
  list: { listStyle: 'none', margin: 0, padding: 0, display: 'grid', gap: 'var(--space-3, 12px)' },
  row: { display: 'grid', gridTemplateColumns: '1.5rem 1fr auto', alignItems: 'start', gap: 'var(--space-3, 12px)' },
  icon: { fontSize: '1.1rem', lineHeight: 1.4, textAlign: 'center' },
  label: { display: 'grid', gap: 2 },
  labelText: { fontWeight: 600 },
  hint: { fontSize: 'var(--font-size-sm, 0.875rem)', color: 'var(--color-text-muted, #656d76)' },
  status: { fontSize: 'var(--font-size-sm, 0.875rem)', whiteSpace: 'nowrap', lineHeight: 1.6 },
  verdict: { margin: 0, padding: 'var(--space-4, 16px)', borderLeft: '4px solid', borderRadius: 'var(--radius-md, 8px)', background: 'var(--color-surface-muted, #f6f8fa)' },
  verdictTitle: { display: 'block', marginBottom: 4 },
  verdictBody: { margin: 0 },
  meta: { margin: '8px 0 0', fontSize: 'var(--font-size-sm, 0.875rem)' },
  actions: { display: 'flex', flexWrap: 'wrap', justifyContent: 'flex-end', gap: 'var(--space-2, 8px)' },
  secondary: { padding: '8px 14px', borderRadius: 'var(--radius-md, 8px)', border: '1px solid var(--color-border, #d0d7de)', background: 'transparent', color: 'inherit', cursor: 'pointer' },
  primary: { padding: '8px 14px', borderRadius: 'var(--radius-md, 8px)', border: 'none', background: 'var(--color-primary, #0969da)', color: 'var(--color-on-primary, #ffffff)', cursor: 'pointer' },
};