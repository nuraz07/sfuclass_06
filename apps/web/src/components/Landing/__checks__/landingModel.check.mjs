// Landing — the homepage's room planner and redirects.
// Run: node --test apps/web/src/components/Landing/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { clampDoors, clock, dayShift, exampleStart, guestTimes, mmss, safeLocale, timelineFor } from '../landingModel.js';

test('doors stay between 3 and 10 minutes, like the real room editor', () => {
  assert.equal(clampDoors(1), 3);
  assert.equal(clampDoors(12), 10);
  assert.equal(clampDoors('7'), 7);
  assert.equal(clampDoors(undefined), 5);
});

test('the example start is the next half hour at least 20 minutes away', () => {
  assert.equal(exampleStart(new Date('2026-03-10T10:05:00Z')).toISOString(), '2026-03-10T10:30:00.000Z');
  assert.equal(exampleStart(new Date('2026-03-10T10:20:00Z')).toISOString(), '2026-03-10T11:00:00.000Z');
});

test('the timeline puts every moment on the bar', () => {
  const t = timelineFor({ start: '2026-03-10T10:00:00Z', lengthMinutes: 60, doorsMinutes: 5 });
  assert.deepEqual(t.marks.map((m) => m.id), ['host', 'doors', 'start', 'end']);
  assert.equal(t.marks[0].position, 0);
  assert.equal(t.marks[3].position, 100);
  // 25 of 90 minutes, 30 of 90 minutes
  assert.equal(t.marks[1].position, 27.8);
  assert.equal(t.marks[2].position, 33.3);
  assert.equal(t.doorsAt, Date.parse('2026-03-10T09:55:00Z'));
});

test('guest times: own zone first, other cities, next-day marked', () => {
  const list = guestTimes({ time: '2026-03-10T22:00:00Z', ownZone: 'Europe/Berlin', locale: 'en-GB', count: 3 });
  assert.equal(list[0].own, true);
  assert.equal(list[0].time, '23:00');
  assert.equal(list.length, 4);
  assert.ok(list.every((entry, i) => i === 0 || !entry.own));
  const sydney = guestTimes({ time: '2026-03-10T22:00:00Z', ownZone: 'Europe/Berlin', locale: 'en-GB', count: 5 }).find((e) => e.city === 'Sydney');
  assert.equal(sydney.shift, 1);
  assert.equal(dayShift('2026-03-10T22:00:00Z', 'Europe/Berlin', 'America/New_York'), 0);
});

test('countdown', () => {
  assert.equal(mmss(299_001), '5:00');
  assert.equal(mmss(61_000), '1:01');
  assert.equal(mmss(-5), '0:00');
});

test('odd browser languages and zones never break the page', () => {
  assert.equal(safeLocale('en-US@posix'), undefined);
  assert.equal(safeLocale('de-DE'), 'de-DE');
  assert.equal(safeLocale(undefined), undefined);
  assert.match(clock('2026-03-10T10:00:00Z', 'Not/AZone', 'en-US@posix'), /\d{1,2}[:.]\d{2}/);
  assert.equal(guestTimes({ time: '2026-03-10T10:00:00Z', ownZone: 'UTC', locale: 'en-US@posix', count: 3 }).length, 4);
});
