// Community, part 3 — study partners, badges, the late-night nudge, calm mode.
// Run: node --test server/test/hub/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ScheduleSchema, StudyProfileSchema, calmMessage, calmWait, helperLevel, isLateNight, nextMorning, scoreMatch, slotLabel,
} from '../../src/hub/partRules.js';

test('study matches come with reasons a person can check', () => {
  const me = { subjects: ['maths', 'physics'], availability: ['tue-evening', 'sat-morning'] };
  const other = { subjects: ['maths'], availability: ['tue-evening'] };
  const match = scoreMatch({ me, other, sharedSpaces: ['Year 7 maths'] });
  assert.deepEqual(match.reasons, ['Both in Year 7 maths', 'Both study maths', 'Both free Tuesday evenings']);
  assert.equal(match.score, 3 + 2 + 1);
  assert.equal(scoreMatch({ me, other: { subjects: ['art'], availability: [] } }), null);
  assert.match(scoreMatch({ me, other, sharedSpaces: ['A', 'B', 'C', 'D'] }).reasons[0], /A and B and 2 more/);
  assert.equal(slotLabel('sat-morning'), 'Saturday mornings');
});

test('study profiles are validated', () => {
  assert.equal(StudyProfileSchema.safeParse({ subjects: ['Maths'], availability: ['tue-evening'] }).data.subjects[0], 'maths');
  assert.equal(StudyProfileSchema.safeParse({ availability: ['someday'] }).success, false);
  assert.equal(StudyProfileSchema.safeParse({ subjects: Array(9).fill('x') }).success, false);
});

test('helper badges', () => {
  assert.equal(helperLevel(2), null);
  assert.equal(helperLevel(3).label, 'Helper');
  assert.equal(helperLevel(10).label, 'Mentor');
});

test('late at night, and the next 8:00 in the writer’s time zone', () => {
  assert.equal(isLateNight(new Date('2026-03-10T22:30:00Z'), 'Europe/Berlin'), true); // 23:30
  assert.equal(isLateNight(new Date('2026-03-10T05:30:00Z'), 'Europe/Berlin'), true); // 06:30
  assert.equal(isLateNight(new Date('2026-03-10T12:00:00Z'), 'Europe/Berlin'), false);
  // 23:30 Berlin (winter, UTC+1) → 08:00 next day = 07:00 UTC
  assert.equal(nextMorning(new Date('2026-03-10T22:30:00Z'), 'Europe/Berlin').toISOString(), '2026-03-11T07:00:00.000Z');
  // 06:30 Berlin → 08:00 the same day
  assert.equal(nextMorning(new Date('2026-03-10T05:30:00Z'), 'Europe/Berlin').toISOString(), '2026-03-10T07:00:00.000Z');
  // The night clocks change (29 March 2026): 08:00 is then UTC+2 = 06:00 UTC
  assert.equal(nextMorning(new Date('2026-03-28T22:30:00Z'), 'Europe/Berlin').toISOString(), '2026-03-29T06:00:00.000Z');
  assert.equal(nextMorning(new Date('2026-03-11T03:00:00Z'), 'America/New_York').toISOString(), '2026-03-11T12:00:00.000Z');
  // Month and year ends roll over
  assert.equal(nextMorning(new Date('2026-12-31T23:00:00Z'), 'UTC').toISOString(), '2027-01-01T08:00:00.000Z');
});

test('scheduled posts: one shape per kind', () => {
  const id = '00000000-0000-4000-8000-000000000000';
  assert.equal(ScheduleSchema.safeParse({ kind: 'reply', targetId: id, body: 'hi' }).success, true);
  assert.equal(ScheduleSchema.safeParse({ kind: 'thread', targetId: id, title: 'Hi there', body: 'x' }).success, true);
  assert.equal(ScheduleSchema.safeParse({ kind: 'chat', targetId: id, body: '' }).success, false);
  assert.equal(ScheduleSchema.safeParse({ kind: 'mail', targetId: id, body: 'x' }).success, false);
});

test('calm mode', () => {
  const now = Date.parse('2026-03-10T12:00:00Z');
  assert.equal(calmWait({ slowSeconds: 0, lastPostAt: '2026-03-10T11:59:00Z', now }), 0);
  assert.equal(calmWait({ slowSeconds: 300, lastPostAt: '2026-03-10T11:58:00Z', now }), 180);
  assert.equal(calmWait({ slowSeconds: 300, lastPostAt: '2026-03-10T11:50:00Z', now }), 0);
  assert.equal(calmWait({ slowSeconds: 300, lastPostAt: null, now }), 0);
  assert.match(calmMessage(180), /3 minutes/);
  assert.match(calmMessage(30), /1 minute\./);
});
