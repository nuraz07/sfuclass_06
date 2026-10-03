// node --test server/test/messaging/chatExtrasRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isEmoji, summariseReactions, galleryKindOf, voiceDuration, MAX_VOICE_MS } from '../../src/messaging/chatExtrasRules.js';

test('one emoji, nothing else', () => {
  for (const ok of ['👍', '❤️', '😂', '👍🏽', '🇩🇪', '👩‍💻', '👨‍👩‍👧', '🙏', '🔥', '1️⃣']) assert.equal(isEmoji(ok), true, ok);
  for (const bad of ['', 'a', 'ok', '👍 ', '<b>', '👍a', 'x'.repeat(20), null, '123', '#']) assert.equal(isEmoji(bad), false, String(bad));
});

test('reaction summary: counts, mine, names, most used first', () => {
  const rows = [
    { emoji: '👍', user_id: 'u1', display_name: 'Ann', created_at: '2026-10-01T10:00:00Z' },
    { emoji: '❤️', user_id: 'u2', display_name: 'Ben', created_at: '2026-10-01T09:00:00Z' },
    { emoji: '👍', user_id: 'me', display_name: 'Me', created_at: '2026-10-01T11:00:00Z' },
  ];
  assert.deepEqual(summariseReactions(rows, 'me'), [
    { emoji: '👍', count: 2, reacted: true, names: ['Ann', 'You'] },
    { emoji: '❤️', count: 1, reacted: false, names: ['Ben'] },
  ]);
  assert.deepEqual(summariseReactions([], 'me'), []);
});

test('gallery tabs and voice length', () => {
  assert.equal(galleryKindOf({ kind: 'image', voice_duration_ms: null }), 'media');
  assert.equal(galleryKindOf({ kind: 'video' }), 'media');
  assert.equal(galleryKindOf({ kind: 'document' }), 'files');
  assert.equal(galleryKindOf({ kind: 'audio', voice_duration_ms: null }), 'files');
  assert.equal(galleryKindOf({ kind: 'video', voice_duration_ms: 4200 }), 'voice');
  assert.equal(voiceDuration('4200.4'), 4200);
  assert.equal(voiceDuration(-5), 0);
  assert.equal(voiceDuration('x'), 0);
  assert.equal(voiceDuration(10 ** 9), MAX_VOICE_MS);
});
