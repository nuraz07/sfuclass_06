// Community — form and wording helpers.
// Run: node --test apps/web/src/components/Hub/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  emptySpaceForm, endsLabel, paragraphs, parseTags, spaceFormToInput, spaceMark, tabFrom, threadBadge,
  validateSpaceForm, validateThreadForm,
} from '../hubModel.js';

test('tags: trimmed, lower-case, unique, at most five', () => {
  assert.deepEqual(parseTags(' Maths, exam prep , maths,,a,b,c,d'), ['maths', 'exam prep', 'a', 'b', 'c']);
  assert.deepEqual(parseTags(''), []);
});

test('space form validation', () => {
  const base = { ...emptySpaceForm(), name: 'Book club' };
  assert.deepEqual(validateSpaceForm(base), {});
  assert.ok(validateSpaceForm({ ...base, name: 'x' }).name);
  assert.ok(validateSpaceForm({ ...base, kind: 'class' }).kind);
  assert.deepEqual(validateSpaceForm({ ...base, kind: 'class' }, { canCreateClass: true }), {});
  assert.ok(validateSpaceForm({ ...base, kind: 'study' }).endsOn);
  assert.ok(validateSpaceForm({ ...base, kind: 'study', endsOn: '2026-01-01' }, { today: '2026-03-01' }).endsOn);
  assert.deepEqual(validateSpaceForm({ ...base, kind: 'study', endsOn: '2026-04-01' }, { today: '2026-03-01' }), {});
});

test('form to API input', () => {
  const input = spaceFormToInput({ ...emptySpaceForm(), name: ' Exam prep ', kind: 'study', endsOn: '2026-04-01', access: 'request', joinQuestion: ' Which class? ', tags: 'Maths' });
  assert.equal(input.name, 'Exam prep');
  assert.equal(input.joinQuestion, 'Which class?');
  assert.ok(input.endsAt.startsWith('2026-04-01') || input.endsAt.startsWith('2026-04-02') || input.endsAt.startsWith('2026-03-31'));
  assert.deepEqual(input.tags, ['maths']);
  assert.equal(spaceFormToInput({ ...emptySpaceForm(), name: 'X', access: 'open', joinQuestion: 'ignored' }).joinQuestion, null);
});

test('wording helpers', () => {
  assert.equal(spaceMark({ emoji: '📚', name: 'Books' }), '📚');
  assert.equal(spaceMark({ name: 'books' }), 'B');
  const now = new Date('2026-03-01T12:00:00Z');
  assert.equal(endsLabel(null, now), null);
  assert.equal(endsLabel('2026-03-01T10:00:00Z', now), 'Ended');
  assert.equal(endsLabel('2026-03-02T10:00:00Z', now), 'Ends tomorrow');
  assert.equal(endsLabel('2026-03-05T12:00:00Z', now), 'Ends in 4 days');
  assert.equal(threadBadge({ kind: 'discussion' }), null);
  assert.equal(threadBadge({ kind: 'question', answered: true }).text, 'Answered');
  assert.equal(tabFrom('?tab=members', ['threads', 'members'], 'threads'), 'members');
  assert.equal(tabFrom('?tab=evil', ['threads', 'members'], 'threads'), 'threads');
  assert.deepEqual(paragraphs('one\n\n\ntwo\nlines\n\n'), ['one', 'two\nlines']);
  assert.deepEqual(validateThreadForm({ title: 'Hi', body: ' ' }).title !== undefined, true);
});

import { dayLabel, groupMessages, normalizeUrl } from '../hubModel.js';

test('chat messages group by person within five minutes', () => {
  const m = (id, user, minute) => ({ messageId: id, author: { userId: user }, createdAt: new Date(Date.UTC(2026, 2, 1, 10, minute)).toISOString() });
  const groups = groupMessages([m('1', 'a', 0), m('2', 'a', 3), m('3', 'b', 4), m('4', 'b', 20), m('5', 'a', 21)]);
  assert.deepEqual(groups.map((g) => g.items.map((i) => i.messageId)), [['1', '2'], ['3'], ['4'], ['5']]);
});

test('day labels and safe links', () => {
  const now = new Date(2026, 2, 10, 12);
  assert.equal(dayLabel(new Date(2026, 2, 10, 8), now), 'Today');
  assert.equal(dayLabel(new Date(2026, 2, 9, 23), now), 'Yesterday');
  assert.equal(normalizeUrl('example.com/sheet.pdf'), 'https://example.com/sheet.pdf');
  assert.equal(normalizeUrl('https://example.com'), 'https://example.com/');
  assert.equal(normalizeUrl('javascript:alert(1)'), null);
  assert.equal(normalizeUrl('localhost'), null);
  assert.equal(normalizeUrl(''), null);
});
