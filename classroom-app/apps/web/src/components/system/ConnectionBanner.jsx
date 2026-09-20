// classroom-app/apps/web/src/components/system/ConnectionBanner.jsx
/**
 * Connection banner  (F7, F8)  [EXT]
 *
 * One strip at the top of the app that says what is wrong with the connection,
 * in the order a person can act on:
 *
 *   offline             the browser lost the network. Nothing else matters.
 *   reconnecting        the signalling socket is down. Chat and the peer list
 *                       are stale; media may still be flowing, because media
 *                       goes directly to the SFU and not through the socket.
 *   media-restarting    signalling is fine, the media path is being rebuilt —
 *                       an ICE restart, a relay retry or a node that is
 *                       draining. This is the version 7 case and it is the one
 *                       people used to read as "the app froze".
 *   media-unavailable   recovery gave up. Audio and video are gone; the rest of
 *                       the lesson still works, and the banner says so.
 *   relayed             informational: the call runs through TURN. Quality may
 *                       be lower, nothing is broken, so it is quiet and
 *                       dismissible.
 *
 * The banner never blocks the page and never shows a spinner that implies the
 * user should wait for something they cannot influence. It is a status line:
 * role="status", aria-live="polite", one sentence, one action at most.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useConnectionQuality } from '@classroom/core-client';

const useOnline = () => {
  const [online, setOnline] = useState(() =>
    typeof navigator === 'undefined' ? true : navigator.onLine,
  );

  useEffect(() => {
    const goOnline = () => setOnline(true);
    const goOffline = () => setOnline(false);
    window.addEventListener('online', goOnline);
    window.addEventListener('offline', goOffline);
    return () => {
      window.removeEventListener('online', goOnline);
      window.removeEventListener('offline', goOffline);
    };
  }, []);

  return online;
};

/**
 * @param {object} quality  from useConnectionQuality(): socket + media state
 * @param {boolean} online
 */
const resolveBanner = (quality, online) => {
  if (!online) {
    return {
      key: 'offline',
      tone: 'error',
      message: 'You are offline. Check your network connection.',
    };
  }

  if (quality.socket === 'reconnecting' || quality.socket === 'disconnected') {
    return {
      key: 'reconnecting',
      tone: 'warning',
      message: 'Reconnecting… Messages you send will be delivered once you are back.',
    };
  }

  if (quality.media === 'reconnecting') {
    return {
      key: 'media-restarting',
      tone: 'warning',
      message:
        quality.reason === 'node-draining'
          ? 'Moving the session to another server. Audio and video will be back in a moment.'
          : 'Restoring audio and video…',
    };
  }

  if (quality.media === 'unavailable') {
    return {
      key: 'media-unavailable',
      tone: 'error',
      message:
        'Audio and video could not be connected. Chat, the participant list and hand raise still work.',
      action: { label: 'Run the network test', event: 'classroom:open-network-check' },
    };
  }

  if (quality.media === 'relayed') {
    return {
      key: 'relayed',
      tone: 'info',
      dismissible: true,
      message: 'Your connection runs through a relay server. Quality may be slightly lower.',
    };
  }

  if (quality.media === 'degraded') {
    return {
      key: 'degraded',
      tone: 'info',
      dismissible: true,
      message: 'Your connection is unstable. Turning off your camera can help.',
    };
  }

  return null;
};

/**
 * @param {object} props
 * @param {object} [props.quality]  injected in tests and Storybook
 */
export default function ConnectionBanner({ quality: injected }) {
  const detected = useConnectionQuality();
  const quality = injected ?? detected;
  const online = useOnline();
  const [dismissed, setDismissed] = useState(null);

  const banner = useMemo(() => resolveBanner(quality, online), [quality, online]);

  // A new condition is worth showing again, even if the previous one was
  // dismissed a second ago.
  useEffect(() => {
    if (banner && dismissed && banner.key !== dismissed) setDismissed(null);
  }, [banner, dismissed]);

  const onAction = useCallback((event) => {
    window.dispatchEvent(new CustomEvent(event));
  }, []);

  if (!banner || banner.key === dismissed) return null;

  return (
    <div
      className={`connection-banner connection-banner--${banner.tone}`}
      role="status"
      aria-live="polite"
      data-state={banner.key}
    >
      <span className="connection-banner__message">{banner.message}</span>

      {banner.action ? (
        <button
          type="button"
          className="connection-banner__action"
          onClick={() => onAction(banner.action.event)}
        >
          {banner.action.label}
        </button>
      ) : null}

      {banner.dismissible ? (
        <button
          type="button"
          className="connection-banner__dismiss"
          aria-label="Dismiss"
          onClick={() => setDismissed(banner.key)}
        >
          ×
        </button>
      ) : null}
    </div>
  );
}

export { resolveBanner };