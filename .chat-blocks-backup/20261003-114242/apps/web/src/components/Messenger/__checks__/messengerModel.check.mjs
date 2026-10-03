// node --test apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  initials, hueOf, sortConversations, matches, highlightParts, dayLabel, threadRows, canEdit, canDelete,
  lastEditable, searchHits, muteState, muteUntil, MUTE_CHOICES, snippet,
} from '../messengerModel.js';

test('initials and stable colours', () => {
  assert.equal(initials('Mara Klein'), 'MK');
  assert.equal(initials('  anna '), 'A');
  assert.equal(initials('Jean Paul van Dyke'), 'JD');
  assert.equal(initials(''), '?');
  assert.equal(hueOf('u1'), hueOf('u1'));
  assert.ok(hueOf('u1') >= 0 && hueOf('u1') < 360);
});

test('pinned first, newest pin on top, then by activity', () => {
  const list = [
    { conversationId: 'a', lastMessageAt: '2026-10-02T10:00:00Z' },
    { conversationId: 'b', lastMessageAt: '2026-09-01T10:00:00Z', pinnedAt: '2026-09-10T00:00:00Z' },
    { conversationId: 'c', lastMessageAt: '2026-10-02T11:00:00Z' },
    { conversationId: 'd', createdAt: '2026-08-01T00:00:00Z', pinnedAt: '2026-09-20T00:00:00Z' },
  ];
  assert.deepEqual(sortConversations(list).map((c) => c.conversationId), ['d', 'b', 'c', 'a']);
});

test('search ignores case and accents; highlights every hit', () => {
  assert.equal(matches('Café crème', 'CAFE'), true);
  assert.equal(matches('Hello', 'bye'), false);
  assert.equal(matches('anything', '  '), true);
  assert.deepEqual(highlightParts('the cat and the CAT', 'cat'), [
    { text: 'the ', hit: false }, { text: 'cat', hit: true }, { text: ' and the ', hit: false }, { text: 'CAT', hit: true },
  ]);
  assert.deepEqual(highlightParts('plain', ''), [{ text: 'plain', hit: false }]);
});

test('day labels', () => {
  const now = new Date(2026, 9, 15, 12);
  assert.equal(dayLabel(new Date(2026, 9, 15, 8).toISOString(), now), 'Today');
  assert.equal(dayLabel(new Date(2026, 9, 14, 23).toISOString(), now), 'Yesterday');
  assert.equal(dayLabel(new Date(2026, 9, 12, 9).toISOString(), now), 'Monday');
  assert.equal(dayLabel(new Date(2026, 8, 1).toISOString(), now, () => 'old'), 'old');
});

test('thread rows: day separators and groups by author within five minutes', () => {
  const m = (id, author, at) => ({ messageId: id, author: { userId: author }, createdAt: at });
  const rows = threadRows([
    m('1', 'a', '2026-10-01T10:00:00'), m('2', 'a', '2026-10-01T10:02:00'), m('3', 'b', '2026-10-01T10:03:00'),
    m('4', 'b', '2026-10-01T10:20:00'), m('5', 'b', '2026-10-02T09:00:00'),
  ]);
  assert.deepEqual(rows.map((r) => (r.type === 'day' ? 'D' : `${r.message.messageId}${r.firstInGroup ? 'F' : ''}${r.lastInGroup ? 'L' : ''}`)),
    ['D', '1F', '2L', '3FL', '4FL', 'D', '5FL']);
});

test('edit and delete follow the server rule', () => {
  const now = Date.parse('2026-10-02T12:00:00Z');
  const mine = { author: { userId: 'me' }, delivery: 'sent', createdAt: '2026-10-02T11:55:00Z' };
  const o = { selfUserId: 'me', windowMin: 15, now };
  assert.equal(canEdit(mine, o), true);
  assert.equal(canEdit({ ...mine, createdAt: '2026-10-02T11:40:00Z' }, o), false);
  assert.equal(canEdit({ ...mine, delivery: 'sending' }, o), false);
  assert.equal(canEdit({ ...mine, deletedAt: 'x' }, o), false);
  assert.equal(canEdit({ ...mine, author: { userId: 'other' } }, o), false);
  assert.equal(canEdit({ ...mine, createdAt: '2020-01-01T00:00:00Z' }, { ...o, windowMin: 0 }), true);
  assert.equal(canDelete(mine, o), true);
  assert.equal(canDelete({ ...mine, author: { userId: 'x' } }, o), false);
  const list = [{ ...mine, messageId: '1' }, { ...mine, messageId: '2', author: { userId: 'x' } }, { ...mine, messageId: '3', delivery: 'failed' }];
  assert.equal(lastEditable(list, o).messageId, '1');
  assert.equal(lastEditable([], o), null);
});

test('search hits skip deleted messages', () => {
  const list = [{ messageId: '1', body: 'Homework due' }, { messageId: '2', body: 'homework?', deletedAt: 'x' }, { messageId: '3', body: 'HOMEWORK done' }];
  assert.deepEqual(searchHits(list, 'homework'), ['1', '3']);
  assert.deepEqual(searchHits(list, ''), []);
});

test('mutes and snippets', () => {
  const now = Date.parse('2026-10-02T12:00:00Z');
  assert.equal(muteState({ muted: false }, now), null);
  assert.deepEqual(muteState({ muted: true }, now), { forever: true });
  assert.deepEqual(muteState({ muted: true, mutedUntil: '2026-10-02T13:00:00Z' }, now), { until: '2026-10-02T13:00:00Z' });
  assert.equal(muteState({ muted: true, mutedUntil: '2026-10-02T11:00:00Z' }, now), null);
  assert.equal(muteUntil(MUTE_CHOICES[0], now), '2026-10-02T13:00:00.000Z');
  assert.equal(muteUntil(MUTE_CHOICES.at(-1), now), null);
  assert.equal(snippet('a   b\nc'), 'a b c');
  assert.equal(snippet('x'.repeat(100), 10), `${'x'.repeat(9)}…`);
});
