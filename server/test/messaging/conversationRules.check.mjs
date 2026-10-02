// node --test server/test/messaging/conversationRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MAX_PINNED, canEdit, toDetails } from '../../src/messaging/conversationRules.js';

const NOW = Date.parse('2026-10-02T12:00:00Z');
const base = { authorId: 'u1', viewerId: 'u1', createdAt: '2026-10-02T11:50:00Z', windowMin: 15, now: NOW };

test('own messages are editable inside the window', () => {
  assert.equal(canEdit(base), true);
  assert.equal(canEdit({ ...base, createdAt: '2026-10-02T11:44:00Z' }), false, '16 minutes old');
  assert.equal(canEdit({ ...base, windowMin: 0, createdAt: '2020-01-01T00:00:00Z' }), true, '0 means always');
});

test('not someone else’s, not deleted, not without a date', () => {
  assert.equal(canEdit({ ...base, viewerId: 'u2' }), false);
  assert.equal(canEdit({ ...base, deletedAt: '2026-10-02T11:55:00Z' }), false);
  assert.equal(canEdit({ ...base, createdAt: 'nonsense' }), false);
  assert.equal(canEdit({ ...base, authorId: null }), false);
});

test('details view', () => {
  const view = toDetails({
    conversation: { id: 'c1', created_at: '2026-09-01T08:00:00Z', pinned_at: null },
    sharedSpaces: [{ space_id: 's1', name: 'Algebra', emoji: '➗' }, { space_id: 's2' }],
    messageCount: '12',
    editWindowMin: 15,
  });
  assert.deepEqual(view, {
    conversationId: 'c1', startedAt: '2026-09-01T08:00:00.000Z', pinnedAt: null, messageCount: 12,
    sharedSpaces: [{ spaceId: 's1', name: 'Algebra', emoji: '➗' }, { spaceId: 's2', name: 'A space', emoji: null }],
    editWindowMin: 15,
  });
  assert.ok(MAX_PINNED >= 3 && MAX_PINNED <= 10);
});
