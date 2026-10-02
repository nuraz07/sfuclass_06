// node --test server/test/files/libraryRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SORTS, SORT_KEYS, DEFAULT_SORT, orderBy, toUsage } from '../../src/files/libraryRules.js';

test('every sort is a fixed clause that ends on a unique column', () => {
  assert.deepEqual(SORT_KEYS, ['new', 'old', 'name', 'size']);
  for (const clause of Object.values(SORTS)) assert.match(clause, /f\.id (ASC|DESC)$/);
});

test('known sorts map to their clause', () => {
  assert.equal(orderBy('name'), SORTS.name);
  assert.equal(orderBy('size'), SORTS.size);
  assert.equal(orderBy('old'), SORTS.old);
});

test('anything else falls back to newest first, never to client text', () => {
  for (const value of [undefined, null, '', 'NAME', 'f.name; DROP TABLE files', 'constructor', '__proto__', 'toString']) {
    assert.equal(orderBy(value), SORTS[DEFAULT_SORT]);
  }
});

test('usage rows become the client view', () => {
  const view = toUsage({ material_id: 'm1', space_id: 's1', space_name: 'Algebra', space_emoji: '➗', added_at: '2026-10-01T10:00:00Z' });
  assert.deepEqual(view, { materialId: 'm1', spaceId: 's1', spaceName: 'Algebra', emoji: '➗', addedAt: '2026-10-01T10:00:00.000Z' });
  assert.deepEqual(toUsage({ material_id: 'm2', space_id: 's2' }), { materialId: 'm2', spaceId: 's2', spaceName: 'A space', emoji: null, addedAt: null });
});
