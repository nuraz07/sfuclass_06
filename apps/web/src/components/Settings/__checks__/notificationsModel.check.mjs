// Settings, Phase B — pure helpers of the notification, device and history tabs.
// Run: node --test apps/web/src/components/Settings/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  describeHistoryEntry,
  describeMuteEnd,
  describeQuietHours,
  mergeDeep,
  pickDeep,
  relativeTime,
} from '../notificationsModel.js';

test('pickDeep takes exactly what a patch touches — the undo', () => {
  const settings = { categories: { mentions: { push: true, email: false } }, digest: 'daily' };
  const patch = { categories: { mentions: { email: true } } };
  assert.deepEqual(pickDeep(settings, patch), { categories: { mentions: { email: false } } });
  assert.deepEqual(mergeDeep(mergeDeep(settings, patch), pickDeep(settings, patch)), settings);
});

test('mergeDeep leaves the original alone', () => {
  const original = { a: { b: 1, c: 2 } };
  const next = mergeDeep(original, { a: { b: 5 } });
  assert.deepEqual(next, { a: { b: 5, c: 2 } });
  assert.equal(original.a.b, 1);
});

test('mute end in words', () => {
  const now = new Date('2026-03-10T12:00:00Z');
  assert.equal(describeMuteEnd(null, now), 'until you turn it back on');
  assert.equal(describeMuteEnd('2026-03-10T12:30:00Z', now), 'for 30 more minutes');
  assert.equal(describeMuteEnd('2026-03-10T15:00:00Z', now), 'for 3 more hours');
  assert.equal(describeMuteEnd('2026-03-12T12:00:00Z', now, () => 'Thu'), 'until Thu');
  assert.equal(describeMuteEnd('2026-03-10T11:00:00Z', now), 'ending now');
});

test('relative time', () => {
  const now = new Date('2026-03-10T12:00:00Z');
  assert.equal(relativeTime('2026-03-10T11:59:30Z', now), 'just now');
  assert.equal(relativeTime('2026-03-10T11:55:00Z', now), '5 minutes ago');
  assert.equal(relativeTime('2026-03-08T12:00:00Z', now), '2 days ago');
});

test('history entries read as sentences', () => {
  assert.equal(describeHistoryEntry({ action: 'auth.login.succeeded' }), 'Signed in');
  assert.equal(describeHistoryEntry({ action: 'auth.login.failed', detail: 'too-many-attempts' }), 'Sign-in blocked after too many attempts');
  assert.equal(describeHistoryEntry({ action: 'auth.session.revoked', detail: 'Chrome on Windows', count: 1 }), 'Signed out Chrome on Windows');
  assert.equal(describeHistoryEntry({ action: 'auth.session.revoked', count: 3 }), 'Signed out 3 other devices');
  assert.equal(
    describeHistoryEntry({ action: 'settings.changed', section: 'notifications', fields: ['quietHours.start', 'quietHours.end', 'digest'] }),
    'Notifications: changed quiet hours, community digest',
  );
});

test('quiet hours in words', () => {
  assert.equal(describeQuietHours({ start: '22:00', end: '07:00' }), '22:00 – 07:00 (overnight)');
  assert.equal(describeQuietHours({ start: '12:00', end: '13:00' }), '12:00 – 13:00');
});
