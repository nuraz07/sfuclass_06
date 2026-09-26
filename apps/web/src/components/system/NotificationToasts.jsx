import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import { onUserEvent } from '../../lib/userEvents.js';
import './notifications.css';

/**
 * A new notification, on screen  (Settings, Phase B)
 *
 * The server only sends notification:new when the person's settings say "in
 * the app" for that type, so this component has no rules of its own. At most
 * three at a time, each for six seconds; the same notification arriving on
 * two sockets shows once. Messages for the chat that is open right now are
 * not shown — the chat itself already shows them.
 */

const SHOW_MS = 6_000;
const MAX = 3;

export default function NotificationToasts() {
  const core = useCore();
  const { status } = core;
  const navigate = useNavigate();
  const location = useLocation();
  const [toasts, setToasts] = useState([]);
  const seen = useRef(new Set());
  const path = useRef(location.pathname);
  path.current = location.pathname;

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    return onUserEvent(core, 'notification:new', (payload) => {
      const notification = payload?.notification;
      if (!notification?.notificationId || seen.current.has(notification.notificationId)) return;
      seen.current.add(notification.notificationId);
      if (notification.url && notification.url === path.current) return;

      setToasts((current) => [...current, notification].slice(-MAX));
      window.setTimeout(() => {
        setToasts((current) => current.filter((toast) => toast.notificationId !== notification.notificationId));
      }, SHOW_MS);
    });
  }, [core, status]);

  if (toasts.length === 0) return null;

  const dismiss = (id) => setToasts((current) => current.filter((toast) => toast.notificationId !== id));

  return (
    <div className="nt-stack" role="region" aria-label="Notifications" aria-live="polite">
      {toasts.map((toast) => (
        <div key={toast.notificationId} className="nt-toast">
          <button
            type="button"
            className="nt-toast__body"
            onClick={() => {
              dismiss(toast.notificationId);
              if (toast.url) navigate(toast.url);
            }}
          >
            <span className="nt-toast__title">{toast.title}</span>
            {toast.body ? <span className="nt-toast__text">{toast.body}</span> : null}
          </button>
          <button type="button" className="nt-toast__close" aria-label="Dismiss" onClick={() => dismiss(toast.notificationId)}>
            ×
          </button>
        </div>
      ))}
    </div>
  );
}
