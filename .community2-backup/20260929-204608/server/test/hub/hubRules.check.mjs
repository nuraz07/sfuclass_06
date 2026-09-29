// Community — who sees and does what in a space.
// Run: node --test server/test/hub/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  CreateSpaceSchema,
  CreateThreadSchema,
  authorView,
  canCreateKind,
  canMarkAnswer,
  canRemove,
  excerpt,
  hasEnded,
  memberListVisible,
  postingBlockedBecause,
  roomForMember,
  viewOf,
} from '../../src/hub/hubRules.js';

const member = { role: 'member' };
const moderator = { role: 'moderator' };
const space = (overrides = {}) => ({ access: 'open', memberList: 'members', kind: 'topic', endsAt: null, archivedAt: null, ...overrides });

test('what a space shows to whom', () => {
  assert.equal(viewOf(space(), null), 'full');
  assert.equal(viewOf(space({ access: 'request' }), null), 'preview');
  assert.equal(viewOf(space({ access: 'invite' }), null), 'hidden');
  assert.equal(viewOf(space({ access: 'invite' }), member), 'full');
});

test('member lists follow the space setting', () => {
  assert.equal(memberListVisible(space(), member), true);
  assert.equal(memberListVisible(space({ memberList: 'moderators' }), member), false);
  assert.equal(memberListVisible(space({ memberList: 'moderators' }), moderator), true);
  assert.equal(memberListVisible(space({ access: 'request' }), null), false);
  assert.equal(memberListVisible(space(), null), true);
});

test('anonymous questions: hidden from members, known to the author and moderators', () => {
  const base = { authorId: 'a', displayName: 'Anna', anonymous: true };
  assert.deepEqual(authorView({ ...base, viewerId: 'x', viewerIsModerator: false }), {
    userId: null, displayName: 'Anonymous', anonymous: true, you: false,
  });
  assert.equal(authorView({ ...base, viewerId: 'a', viewerIsModerator: false }).displayName, 'Anna');
  assert.equal(authorView({ ...base, viewerId: 'a', viewerIsModerator: false }).hiddenFromOthers, true);
  assert.equal(authorView({ ...base, viewerId: 'm', viewerIsModerator: true }).revealedToModerator, true);
  assert.equal(authorView({ ...base, anonymous: false, viewerId: 'x', viewerIsModerator: false }).displayName, 'Anna');
});

test('posting: members only, not in ended spaces, not during a timeout', () => {
  const now = Date.parse('2026-10-01T12:00:00Z');
  assert.match(postingBlockedBecause(space(), null, now), /Join/);
  assert.equal(postingBlockedBecause(space(), member, now), null);
  assert.match(postingBlockedBecause(space({ kind: 'study', endsAt: '2026-09-30T00:00:00Z' }), member, now), /ended/);
  assert.match(postingBlockedBecause(space(), { ...member, timeoutUntil: '2026-10-01T13:00:00Z' }, now), /paused/);
  assert.equal(postingBlockedBecause(space(), { ...member, timeoutUntil: '2026-10-01T11:00:00Z' }, now), null);
  assert.equal(hasEnded(space({ archivedAt: '2026-01-01T00:00:00Z' }), now), true);
});

test('answers, removal, class spaces and study group size', () => {
  const question = { kind: 'question', authorId: 'a' };
  assert.equal(canMarkAnswer({ thread: question, viewerId: 'a', membership: member }), true);
  assert.equal(canMarkAnswer({ thread: question, viewerId: 'b', membership: member }), false);
  assert.equal(canMarkAnswer({ thread: question, viewerId: 'b', membership: moderator }), true);
  assert.equal(canMarkAnswer({ thread: { ...question, kind: 'discussion' }, viewerId: 'a', membership: member }), false);
  assert.equal(canRemove({ authorId: 'a', viewerId: 'a', membership: member }), true);
  assert.equal(canRemove({ authorId: 'a', viewerId: 'b', membership: member }), false);
  assert.equal(canCreateKind('class', 'learner'), false);
  assert.equal(canCreateKind('class', 'teacher'), true);
  assert.equal(canCreateKind('topic', 'learner'), true);
  assert.equal(roomForMember(space({ kind: 'study' }), 12), false);
  assert.equal(roomForMember(space({ kind: 'topic' }), 500), true);
});

test('input: study groups need an end, only questions can be anonymous', () => {
  assert.equal(CreateSpaceSchema.safeParse({ name: 'Exam prep', kind: 'study' }).success, false);
  assert.equal(CreateSpaceSchema.safeParse({ name: 'Exam prep', kind: 'study', endsAt: '2026-12-01T00:00:00Z' }).success, true);
  assert.equal(CreateSpaceSchema.safeParse({ name: 'Books', endsAt: '2026-12-01T00:00:00Z' }).success, false);
  assert.equal(CreateSpaceSchema.parse({ name: 'Books', tags: ['  Reading '] }).tags[0], 'reading');
  assert.equal(CreateThreadSchema.safeParse({ title: 'Hello there', body: 'x', anonymous: true }).success, false);
  assert.equal(CreateThreadSchema.safeParse({ title: 'Why ¾?', body: 'x', kind: 'question', anonymous: true }).success, true);
});

test('excerpts are short and clean', () => {
  assert.equal(excerpt('# Title\n\nSome **bold** text'), 'Title Some bold text');
  assert.equal(excerpt('a'.repeat(300)).length, 180);
});
