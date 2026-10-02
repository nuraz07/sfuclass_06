// node --test apps/web/src/components/Library/__checks__/libraryModel.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  readQuery, writeQuery, previewModeOf, openLabel, nameWithoutExt, renameProblem, usageLevel, usedInLabel,
  deleteConsequence, neighbours, dateGroupOf, sectionsOf, spaceChoices, linksAreStale, LINK_REFRESH_MS,
} from '../libraryModel.js';

const ID = '3f1c9a7e-2b4d-4e6f-8a9b-0c1d2e3f4a5b';

test('the address bar is read defensively', () => {
  assert.deepEqual(readQuery(new URLSearchParams('')), { q: '', kind: '', sort: 'new', view: 'grid', file: null });
  assert.deepEqual(readQuery(new URLSearchParams(`q=maths&kind=video&sort=size&view=list&file=${ID}`)), { q: 'maths', kind: 'video', sort: 'size', view: 'list', file: ID });
  assert.deepEqual(readQuery(new URLSearchParams('kind=exe&sort=drop&view=3d&file=../x')), { q: '', kind: '', sort: 'new', view: 'grid', file: null });
  assert.equal(readQuery(new URLSearchParams(`q=${'a'.repeat(200)}`)).q.length, 80);
});

test('defaults are left out of the address bar', () => {
  assert.equal(writeQuery({ q: '', kind: '', sort: 'new', view: 'grid', file: null }).toString(), '');
  assert.equal(writeQuery({ sort: 'new' }, { kind: 'image', file: ID }).toString(), `kind=image&file=${ID}`);
  assert.equal(writeQuery({ q: 'a b', view: 'list' }, { file: null }).toString(), 'q=a+b&view=list');
});

test('preview modes by kind and format', () => {
  assert.equal(previewModeOf({ kind: 'image', ext: 'png' }), 'image');
  assert.equal(previewModeOf({ kind: 'video', ext: 'mp4' }), 'video');
  assert.equal(previewModeOf({ kind: 'audio', ext: 'mp3' }), 'audio');
  assert.equal(previewModeOf({ kind: 'text', ext: 'txt' }), 'text');
  assert.equal(previewModeOf({ kind: 'text', ext: 'csv' }), 'download');
  assert.equal(previewModeOf({ kind: 'document', ext: 'pdf' }), 'pdf');
  assert.equal(previewModeOf({ kind: 'document', ext: 'docx' }), 'download');
  assert.equal(previewModeOf(null), 'none');
  assert.equal(openLabel({ inline: true }), 'Open in new tab');
  assert.equal(openLabel({ inline: false }), 'Download');
});

test('rename shows the name without its extension and checks it like the server', () => {
  assert.equal(nameWithoutExt({ name: 'Worksheet 3.PDF', ext: 'pdf' }), 'Worksheet 3');
  assert.equal(nameWithoutExt({ name: 'notes', ext: 'txt' }), 'notes');
  assert.equal(renameProblem('  '), 'Give the file a name.');
  assert.match(renameProblem('a/b'), /cannot contain/);
  assert.match(renameProblem('x'.repeat(181)), /too long/);
  assert.equal(renameProblem('Fractions, part 2'), null);
});

test('storage levels and wording', () => {
  assert.equal(usageLevel({ usedBytes: 10, quotaBytes: 100 }), 'ok');
  assert.equal(usageLevel({ usedBytes: 80, quotaBytes: 100 }), 'high');
  assert.equal(usageLevel({ usedBytes: 99, quotaBytes: 100 }), 'full');
  assert.equal(usageLevel({}), 'ok');
  assert.equal(usedInLabel(0), 'Not in any space yet');
  assert.equal(usedInLabel(1), 'In 1 space');
  assert.equal(usedInLabel(4), 'In 4 spaces');
});

test('a delete says what else it removes', () => {
  assert.match(deleteConsequence([]), /nothing else changes/);
  assert.equal(deleteConsequence([{ spaceName: 'Algebra' }]), 'It is also removed from the materials of Algebra.');
  assert.equal(deleteConsequence([{ spaceName: 'A' }, { spaceName: 'B' }, { spaceName: 'C' }]), 'It is also removed from the materials of A, B and C.');
});

test('neighbours for arrow keys', () => {
  const items = [{ fileId: 'a' }, { fileId: 'b' }, { fileId: 'c' }];
  assert.deepEqual(neighbours(items, 'b'), { prev: 'a', next: 'c' });
  assert.deepEqual(neighbours(items, 'a'), { prev: null, next: 'b' });
  assert.deepEqual(neighbours(items, 'zz'), { prev: null, next: null });
});

test('date sections only for date sorts', () => {
  const now = new Date(2026, 9, 15, 12, 0);
  assert.equal(dateGroupOf(new Date(2026, 9, 15, 8, 0), now), 'Today');
  assert.equal(dateGroupOf(new Date(2026, 9, 14, 23, 0), now), 'Yesterday');
  assert.equal(dateGroupOf(new Date(2026, 9, 10, 9, 0), now), 'This week');
  assert.equal(dateGroupOf(new Date(2026, 9, 2, 9, 0), now), 'This month');
  assert.equal(dateGroupOf(new Date(2026, 7, 2, 9, 0), now), 'Earlier');
  assert.equal(dateGroupOf('not a date', now), 'Earlier');
  const items = [
    { fileId: '1', createdAt: new Date(2026, 9, 15, 9).toISOString() },
    { fileId: '2', createdAt: new Date(2026, 9, 15, 8).toISOString() },
    { fileId: '3', createdAt: new Date(2026, 6, 1).toISOString() },
  ];
  assert.deepEqual(sectionsOf(items, 'new', now).map((s) => [s.label, s.items.length]), [['Today', 2], ['Earlier', 1]]);
  assert.deepEqual(sectionsOf(items, 'name', now).map((s) => [s.label, s.items.length]), [[null, 3]]);
});

test('space choices: mine only, available first, with the reason', () => {
  const spaces = [
    { spaceId: 's1', name: 'Zoology', myRole: 'member' },
    { spaceId: 's2', name: 'Algebra', myRole: 'member' },
    { spaceId: 's3', name: 'Biology', myRole: 'member', ended: true },
    { spaceId: 's4', name: 'Chemistry', myRole: 'member', me: { postingBlocked: 'You are timed out until 14:00.' } },
    { spaceId: 's5', name: 'Not mine', myRole: null },
  ];
  const choices = spaceChoices(spaces, ['s1']);
  assert.deepEqual(choices.map((c) => [c.name, c.unavailable]), [
    ['Algebra', null],
    ['Biology', 'This space has ended'],
    ['Chemistry', 'You are timed out until 14:00.'],
    ['Zoology', 'Already in this space'],
  ]);
});

test('links are refreshed before they expire', () => {
  assert.equal(linksAreStale(null), true);
  assert.equal(linksAreStale(1_000, 1_000 + LINK_REFRESH_MS - 1), false);
  assert.equal(linksAreStale(1_000, 1_000 + LINK_REFRESH_MS + 1), true);
  assert.ok(LINK_REFRESH_MS < 2 * 60 * 60 * 1000);
});
