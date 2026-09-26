// Settings, Phase B — the pure rules behind notifications, devices and history.
// Run: node --test server/test/settings/*.check.mjs
// (.check.mjs rather than .test.js, so no other test runner picks these up.)

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  categoryOf,
  decide,
  isWithinQuietHours,
  mergeNotificationPatch,
  withNotificationDefaults,
  fromRow,
  toRow,
  DEFAULT_NOTIFICATION_SETTINGS,
} from '../../src/settings/notifications.js';
import { describeUserAgent } from '../../src/security/userAgent.js';
import { summarizeHeld } from '../../src/notifications/focusSummary.js';
import { fieldPaths } from '../../src/settings/fieldPaths.js';

const at = (hhmm) => new Date(`2026-03-10T${hhmm}:00Z`);

test('kinds map to the categories people see', () => {
  assert.equal(categoryOf('chat.direct.message'), 'directMessages');
  assert.equal(categoryOf('chat.mention'), 'mentions');
  assert.equal(categoryOf('chat.channel.message'), 'channelMessages');
  assert.equal(categoryOf('session.reminder.starting_soon'), 'lessonReminders');
  assert.equal(categoryOf('asset.ready'), 'coursework');
  assert.equal(categoryOf('password.reset'), 'security');
  assert.equal(categoryOf('thread.reply'), 'community');
});

test('defaults: private messages push, chatroom messages stay silent', () => {
  const settings = withNotificationDefaults({});
  assert.equal(settings.categories.directMessages.push, true);
  assert.deepEqual(settings.categories.channelMessages, { inApp: false, push: false, email: false });
  assert.equal(decide({ kind: 'chat.channel.message', settings }).channels.length, 0);
});

test('invalid stored values fall back to defaults', () => {
  const settings = withNotificationDefaults({ digest: 'hourly', quietHours: { start: '25:00' } });
  assert.equal(settings.digest, DEFAULT_NOTIFICATION_SETTINGS.digest);
  assert.equal(settings.quietHours.start, '22:00');
});

test('patches merge, unknown keys and equal quiet hours are refused', () => {
  const next = mergeNotificationPatch({}, { categories: { mentions: { email: true } }, digest: 'weekly' });
  assert.equal(next.categories.mentions.email, true);
  assert.equal(next.categories.mentions.push, true);
  assert.equal(next.digest, 'weekly');
  assert.throws(() => mergeNotificationPatch({}, { categories: { spam: { push: true } } }), { code: 'validation_failed' });
  assert.throws(() => mergeNotificationPatch({}, { quietHours: { start: '07:00', end: '07:00' } }), { code: 'validation_failed' });
});

test('rows round-trip', () => {
  const settings = mergeNotificationPatch({}, { quietHours: { enabled: true, start: '21:30' }, showPreviews: false });
  const row = { ...toRow(settings), quiet_start: '21:30:00', quiet_end: '07:00:00' };
  assert.deepEqual(fromRow(row), settings);
});

test('quiet hours run past midnight in the person\'s time zone', () => {
  const quiet = { enabled: true, start: '22:00', end: '07:00' };
  assert.equal(isWithinQuietHours(quiet, at('23:30'), 'UTC'), true);
  assert.equal(isWithinQuietHours(quiet, at('06:59'), 'UTC'), true);
  assert.equal(isWithinQuietHours(quiet, at('07:00'), 'UTC'), false);
  // 21:30 UTC is 22:30 in Berlin in March.
  assert.equal(isWithinQuietHours(quiet, at('21:30'), 'Europe/Berlin'), true);
  assert.equal(isWithinQuietHours({ ...quiet, enabled: false }, at('23:30'), 'UTC'), false);
  assert.equal(isWithinQuietHours(quiet, at('23:30'), 'Not/AZone'), true);
});

test('decide: switched off, focus, presence, quiet hours, lesson exception, security', () => {
  const base = withNotificationDefaults({});
  const quiet = mergeNotificationPatch({}, { quietHours: { enabled: true } });

  assert.deepEqual(
    decide({ kind: 'chat.direct.message', settings: base, presence: 'offline' }).channels,
    ['inApp', 'push'],
  );
  assert.equal(decide({ kind: 'chat.direct.message', settings: base, presence: 'in-class' }).hold, true);
  assert.equal(
    decide({ kind: 'chat.direct.message', settings: { ...base, focusDuringLessons: false }, presence: 'in-class' }).hold,
    false,
  );
  assert.deepEqual(decide({ kind: 'chat.direct.message', settings: base, presence: 'online' }).channels, ['inApp']);

  const night = decide({ kind: 'chat.direct.message', settings: quiet, now: at('23:00') });
  assert.deepEqual(night.channels, ['inApp']);
  assert.equal(night.reason, 'quiet hours');

  assert.ok(decide({ kind: 'session.reminder.starting_soon', settings: quiet, now: at('23:00') }).channels.includes('push'));

  const off = mergeNotificationPatch({}, { categories: { directMessages: { inApp: false, push: false, email: false } } });
  assert.equal(decide({ kind: 'chat.direct.message', settings: off }).reason, 'switched off');
  assert.deepEqual(decide({ kind: 'password.reset', settings: off, requested: ['email'] }).channels, ['email']);
});

test('user agents read as a browser on a system', () => {
  const chrome = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
  const safari = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
  const edge = `${chrome} Edg/126.0`;
  assert.equal(describeUserAgent(chrome), 'Chrome on Windows');
  assert.equal(describeUserAgent(safari), 'Safari on iPhone');
  assert.equal(describeUserAgent(edge), 'Edge on Windows');
  assert.equal(describeUserAgent(''), 'Unknown device');
  assert.equal(describeUserAgent('', 'android'), 'Classroom app on Android');
});

test('the summary after a lesson', () => {
  assert.equal(summarizeHeld([]), null);
  const one = summarizeHeld([{ type: 'message', from: 'Anna', conversationId: 'c1' }]);
  assert.equal(one.body, '1 new message from Anna');
  assert.equal(one.url, '/messages/c1');

  const many = summarizeHeld([
    { type: 'message', from: 'Anna', conversationId: 'c1' },
    { type: 'message', from: 'Ben', conversationId: 'c2' },
    { type: 'mention', from: 'Cleo', channelId: 'x' },
  ]);
  assert.equal(many.body, '2 new messages in 3 chats from Anna, Ben and 1 other, 1 mention');
  assert.equal(many.url, '/messages');
  assert.equal(many.count, 3);
});

test('field paths name what changed, never the values', () => {
  assert.deepEqual(fieldPaths({ lesson: { joinCamera: 'off' }, digest: 'weekly' }), ['lesson.joinCamera', 'digest']);
  assert.deepEqual(fieldPaths({ links: [{ url: 'x' }] }), ['links']);
  assert.deepEqual(fieldPaths({}), []);
});
