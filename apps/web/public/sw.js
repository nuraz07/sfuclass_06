/* Classroom service worker  (Settings, Phase B)
 *
 * Only for push notifications: it shows what the server sends and opens the
 * right page when a notification is clicked. It does not cache anything, so
 * it can never serve a stale version of the app.
 *
 * Payload (server/src/notifications/delivery.js):
 *   { title, body, url, tag, kind }
 */

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { title: 'Classroom', body: event.data ? event.data.text() : '' };
  }

  const title = data.title || 'Classroom';
  const options = {
    body: data.body || '',
    tag: data.tag || undefined,
    // A newer notification with the same tag replaces the old one, with a sound.
    renotify: Boolean(data.tag),
    data: { url: data.url || '/', kind: data.kind || null },
    icon: '/favicon.ico',
    badge: '/favicon.ico',
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || '/', self.location.origin).href;

  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      // An open tab of the app is reused rather than opening another one.
      for (const client of windows) {
        if (new URL(client.url).origin !== self.location.origin) continue;
        await client.focus();
        if ('navigate' in client) {
          try {
            await client.navigate(target);
          } catch {
            // Tabs the worker does not control cannot be navigated; focus is enough.
          }
        }
        return;
      }
      await self.clients.openWindow(target);
    })(),
  );
});

/* The browser replaced the subscription (keys rotated): tell the open tabs,
   which register the new one with the server. */
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const client of windows) client.postMessage({ type: 'push-subscription-changed' });
    })(),
  );
});
