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
