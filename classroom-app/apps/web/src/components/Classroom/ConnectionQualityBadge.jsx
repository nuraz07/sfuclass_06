// apps/web/src/components/Classroom/ConnectionQualityBadge.jsx
//
// Small badge in the corner of every video tile (TeacherStage, StudentGrid, ScreenShareStage):
//   - signal bars for the connection quality of that participant,
//   - a "Relayed" chip when that participant's media goes through a TURN relay,
//   - "Reconnecting" while ICE is being restarted (core-client IceRecovery).
// Hover or keyboard focus shows the numbers behind the bars, so a teacher can tell a learner "your connection is
// losing packets" instead of guessing.
//
// Data (contract with packages/core-client/src/state/useConnectionQuality.ts, exported from '@classroom/core-client'):
//   useConnectionQuality({ peerId, isLocal }) → {
//     level:   'good' | 'degraded' | 'poor' | 'reconnecting' | 'unknown',
//     relayed: boolean | null,    local tile: selected ICE candidate pair is a relay candidate (rtcStats.ts);
//                                 remote tile: the participant's own report, relayed over signalling; null = unknown
//     rttMs, lossPct, jitterMs, kbps: number | null
//   }
//   Local tile = this device's send/receive transports. Remote tile = the inbound streams of that participant.
//   The hook samples getStats() every 2 s and applies hysteresis, so the badge does not flicker.
//
// Props:
//   peerId, isLocal      which participant the tile shows
//   quality              optional override of the hook result (tests, Storybook, the self-view preview)
//   size                 'sm' | 'md' (default 'sm')
//
// A relayed connection is normal and usually of full quality; the chip explains why the path differs, it is not a
// warning. Owner: F8 Real-Time Connectivity.

import { memo, useId, useState } from 'react';
import { useConnectionQuality } from '@classroom/core-client';

const LEVELS = {
  good: { bars: 4, label: 'Good connection', tone: 'success' },
  degraded: { bars: 2, label: 'Unstable connection', tone: 'warning' },
  poor: { bars: 1, label: 'Poor connection', tone: 'danger' },
  reconnecting: { bars: 0, label: 'Reconnecting', tone: 'warning' },
  unknown: { bars: 0, label: 'Connection quality unknown', tone: 'muted' },
};

const TONES = {
  success: 'var(--color-success, #1a7f37)',
  warning: 'var(--color-warning, #9a6700)',
  danger: 'var(--color-danger, #cf222e)',
  muted: 'var(--color-text-muted, #8c959f)',
};

function ConnectionQualityBadge({ peerId, isLocal = false, quality: override, size = 'sm' }) {
  const measured = useConnectionQuality({ peerId, isLocal });
  const quality = override ?? measured ?? { level: 'unknown', relayed: null };
  const level = LEVELS[quality.level] ? quality.level : 'unknown';
  const meta = LEVELS[level];
  const tooltipId = useId();
  const [showDetails, setShowDetails] = useState(false);

  const who = isLocal ? 'Your connection' : 'Connection';
  const accessibleLabel = [
    `${who}: ${meta.label}`,
    quality.relayed ? 'through a relay server' : null,
  ].filter(Boolean).join(', ');

  const scale = size === 'md' ? 1.25 : 1;
  const barWidth = 3 * scale;
  const gap = 2 * scale;
  const height = 12 * scale;

  return (
    <button
      type="button"
      style={styles.root}
      data-level={level}
      data-relayed={quality.relayed ? 'true' : 'false'}
      onMouseEnter={() => setShowDetails(true)}
      onMouseLeave={() => setShowDetails(false)}
      onFocus={() => setShowDetails(true)}
      onBlur={() => setShowDetails(false)}
      onKeyDown={(event) => {
        if (event.key === 'Escape') setShowDetails(false);
      }}
      onClick={(event) => {
        event.stopPropagation(); // the tile underneath has its own click actions (pin, spotlight)
        setShowDetails((shown) => !shown); // touch devices have no hover
      }}
      aria-label={accessibleLabel}
      aria-expanded={showDetails}
      aria-describedby={showDetails ? tooltipId : undefined}
    >
      {level === 'reconnecting' ? (
        <span aria-hidden="true" style={{ ...styles.text, color: TONES.warning }}>
          <span>⟳</span> Reconnecting
        </span>
      ) : (
        <svg aria-hidden="true" width={4 * barWidth + 3 * gap} height={height} viewBox={`0 0 ${4 * barWidth + 3 * gap} ${height}`}>
          {[1, 2, 3, 4].map((bar) => {
            const barHeight = (height * bar) / 4;
            return (
              <rect
                key={bar}
                x={(bar - 1) * (barWidth + gap)}
                y={height - barHeight}
                width={barWidth}
                height={barHeight}
                rx={1}
                fill={bar <= meta.bars ? TONES[meta.tone] : 'var(--color-border, rgba(255,255,255,0.35))'}
              />
            );
          })}
        </svg>
      )}

      {quality.relayed && level !== 'reconnecting' && (
        <span aria-hidden="true" style={styles.chip}>Relayed</span>
      )}

      {showDetails && (
        <span id={tooltipId} role="tooltip" style={styles.tooltip}>
          <strong style={styles.tooltipTitle}>{`${who}: ${meta.label}`}</strong>
          <Detail label="Round trip" value={quality.rttMs} unit="ms" />
          <Detail label="Packet loss" value={quality.lossPct} unit="%" digits={1} />
          <Detail label="Jitter" value={quality.jitterMs} unit="ms" />
          <Detail label="Bitrate" value={quality.kbps} unit="kbit/s" />
          {quality.relayed === true && (
            <span style={styles.tooltipNote}>
              Connected through a relay server because a direct connection is blocked on this network. This is normal
              and usually does not affect quality.
            </span>
          )}
        </span>
      )}
    </button>
  );
}

function Detail({ label, value, unit, digits = 0 }) {
  if (!Number.isFinite(value)) return null;
  return (
    <span style={styles.detail}>
      <span>{label}</span>
      <span>{`${value.toFixed(digits)} ${unit}`}</span>
    </span>
  );
}

const styles = {
  root: {
    position: 'relative',
    display: 'inline-flex',
    alignItems: 'center',
    gap: 6,
    padding: '3px 6px',
    borderRadius: 999,
    background: 'rgba(0, 0, 0, 0.55)',
    color: '#ffffff',
    fontSize: 'var(--font-size-xs, 0.75rem)',
    lineHeight: 1,
    border: 'none',
    cursor: 'default',
    font: 'inherit',
    outlineOffset: 2,
  },
  text: { display: 'inline-flex', alignItems: 'center', gap: 4 },
  chip: {
    padding: '2px 6px',
    borderRadius: 999,
    background: 'rgba(255, 255, 255, 0.18)',
    fontWeight: 600,
    letterSpacing: 0.2,
  },
  tooltip: {
    position: 'absolute',
    top: 'calc(100% + 6px)',
    right: 0,
    zIndex: 10,
    display: 'grid',
    gap: 4,
    minWidth: 200,
    maxWidth: 260,
    padding: 10,
    borderRadius: 'var(--radius-md, 8px)',
    background: 'var(--color-surface-inverse, #1f2328)',
    color: 'var(--color-on-inverse, #ffffff)',
    fontSize: 'var(--font-size-xs, 0.75rem)',
    lineHeight: 1.4,
    boxShadow: '0 6px 20px rgba(0,0,0,0.3)',
    whiteSpace: 'normal',
  },
  tooltipTitle: { marginBottom: 2 },
  tooltipNote: { marginTop: 4, opacity: 0.85 },
  detail: { display: 'flex', justifyContent: 'space-between', gap: 12 },
};

export default memo(ConnectionQualityBadge);