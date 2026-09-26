/**
 * Browser push for this device  (Settings, Phase B)
 *
 * Registers the service worker (public/sw.js), asks the browser for
 * permission, subscribes with the server's VAPID public key and hands the
 * subscription to the API, which binds it to this sign-in session. Signing
 * this device out — here or from another device — removes it on the server.
 */

const SW_URL = '/sw.js';

export const pushSupported = () =>
  typeof window !== 'undefined' &&
  'serviceWorker' in navigator &&
  'PushManager' in window &&
  'Notification' in window;

/** 'granted' · 'denied' · 'default' · 'unsupported' */
export const pushPermission = () => (pushSupported() ? Notification.permission : 'unsupported');

const base64UrlToBytes = (value) => {
  const padding = '='.repeat((4 - (value.length % 4)) % 4);
  const raw = atob((value + padding).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (char) => char.charCodeAt(0));
};

const registration = async () => {
  const existing = await navigator.serviceWorker.getRegistration(SW_URL);
  return existing ?? navigator.serviceWorker.register(SW_URL, { scope: '/' });
};

/** The current subscription of this browser, or null. Never prompts. */
export const currentSubscription = async () => {
  if (!pushSupported()) return null;
  const reg = await navigator.serviceWorker.getRegistration(SW_URL);
  return reg ? reg.pushManager.getSubscription() : null;
};

const toInput = (subscription) => {
  const json = subscription.toJSON();
  return { endpoint: json.endpoint, keys: { p256dh: json.keys.p256dh, auth: json.keys.auth } };
};

/**
 * Turns push on for this browser. Must be called from a click: browsers only
 * show the permission prompt in response to a user action.
 * @returns {Promise<{ ok: boolean, reason?: string }>}
 */
export const enablePush = async ({ account, publicKey }) => {
  if (!pushSupported()) return { ok: false, reason: 'This browser cannot receive push notifications.' };
  if (!publicKey) return { ok: false, reason: 'Push is not set up on the server.' };

  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    return {
      ok: false,
      reason:
        permission === 'denied'
          ? 'Notifications are blocked for this site. Allow them in the address bar, then try again.'
          : 'Permission was not given.',
    };
  }

  const reg = await registration();
  await navigator.serviceWorker.ready;
  let subscription = await reg.pushManager.getSubscription();

  // A subscription made with other keys (the server's keys changed) cannot be used.
  const key = base64UrlToBytes(publicKey);
  const current = subscription?.options?.applicationServerKey;
  if (subscription && current && !sameBytes(new Uint8Array(current), key)) {
    await subscription.unsubscribe().catch(() => undefined);
    subscription = null;
  }

  subscription ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  await account.registerPush(toInput(subscription));
  return { ok: true };
};

const sameBytes = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);

/** Turns push off for this browser only. */
export const disablePush = async ({ account }) => {
  const subscription = await currentSubscription();
  if (!subscription) return { ok: true };
  await account.unregisterPush(subscription.endpoint).catch(() => undefined);
  await subscription.unsubscribe().catch(() => undefined);
  return { ok: true };
};

/**
 * Keeps the server's copy in step with the browser: after the service worker
 * reports a rotated subscription, or on start when permission is still given.
 */
export const resyncPush = async ({ account }) => {
  const subscription = await currentSubscription().catch(() => null);
  if (subscription && pushPermission() === 'granted') {
    await account.registerPush(toInput(subscription)).catch(() => undefined);
  }
};

export const onServiceWorkerMessage = (handler) => {
  if (!pushSupported()) return () => undefined;
  const listener = (event) => handler(event.data ?? {});
  navigator.serviceWorker.addEventListener('message', listener);
  return () => navigator.serviceWorker.removeEventListener('message', listener);
};
