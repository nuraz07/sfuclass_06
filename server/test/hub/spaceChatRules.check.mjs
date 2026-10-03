// node --test server/test/hub/spaceChatRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { removalBy, canEdit, deletedByRole } from '../../src/hub/spaceChatRules.js';

test('delete own, moderators remove, members never delete others', () => {
  assert.equal(removalBy({ authorId: 'a', viewerId: 'a', membership: { role: 'member' } }), 'author');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'a', membership: { role: 'owner' } }), 'author');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: { role: 'moderator' } }), 'moderator');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: { role: 'owner' } }), 'moderator');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: { role: 'member' } }), null);
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: null }), null);
});

test('edit only own text inside the window', () => {
  const now = Date.parse('2026-10-03T12:00:00Z');
  const base = { authorId: 'a', viewerId: 'a', body: 'hi', createdAt: '2026-10-03T11:55:00Z', windowMin: 15, now };
  assert.equal(canEdit(base), true);
  assert.equal(canEdit({ ...base, viewerId: 'b' }), false);
  assert.equal(canEdit({ ...base, body: '  ' }), false);
  assert.equal(canEdit({ ...base, deletedAt: 'x' }), false);
  assert.equal(canEdit({ ...base, createdAt: '2026-10-03T11:30:00Z' }), false);
  assert.equal(canEdit({ ...base, createdAt: '2020-01-01T00:00:00Z', windowMin: 0 }), true);
});

test('who removed it', () => {
  assert.equal(deletedByRole({ deletedBy: null, authorId: 'a' }), null);
  assert.equal(deletedByRole({ deletedBy: 'a', authorId: 'a' }), 'author');
  assert.equal(deletedByRole({ deletedBy: 'm', authorId: 'a' }), 'moderator');
});
