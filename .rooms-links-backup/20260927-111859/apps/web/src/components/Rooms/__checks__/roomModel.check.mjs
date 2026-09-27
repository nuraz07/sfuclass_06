// Rooms — the pure parts of the room form and the lobby.
// Run: node --test apps/web/src/components/Rooms/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  countdown,
  defaultForm,
  destinationFor,
  durationLabel,
  formToInput,
  localInputValue,
  nextSlot,
  recurrenceOf,
  roomToForm,
  validateForm,
  weekdayOf,
} from '../roomModel.js';

const config = {
  earlyEntry: { min: 3, max: 10, default: 5 },
  duration: { min: 10, max: 480, presets: [30, 45, 60, 90] },
  capacity: { min: 2, max: 300, default: 25 },
};

test('local input values follow the time zone', () => {
  const moment = '2026-03-10T17:30:00Z';
  assert.equal(localInputValue(moment, 'UTC'), '2026-03-10T17:30');
  assert.equal(localInputValue(moment, 'Europe/Berlin'), '2026-03-10T18:30');
  assert.equal(localInputValue(moment, 'America/New_York'), '2026-03-10T13:30');
});

test('the default start is the next quarter hour at least 15 minutes away', () => {
  const slot = nextSlot(new Date('2026-03-10T10:07:12Z'));
  assert.equal(slot.toISOString(), '2026-03-10T10:30:00.000Z');
  assert.equal(nextSlot(new Date('2026-03-10T10:45:00Z')).toISOString(), '2026-03-10T11:00:00.000Z');
});

test('weekdays and series', () => {
  assert.equal(weekdayOf('2026-10-06T18:00'), 'TU');
  const form = { ...defaultForm({ timeZone: 'UTC' }), startsAtLocal: '2026-10-06T18:00' };
  assert.equal(recurrenceOf(form), null);
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'weekly', repeatCount: 6 }), { freq: 'WEEKLY', byDay: ['TU'], count: 6 });
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'biweekly', repeatEnd: 'until', repeatUntil: '2026-12-01' }), {
    freq: 'WEEKLY', interval: 2, byDay: ['TU'], until: '2026-12-01',
  });
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'weekdays', repeatCount: 10 }).byDay, ['MO', 'TU', 'WE', 'TH', 'FR']);
});

test('a form becomes the API input, and an edit carries no series', () => {
  const form = {
    ...defaultForm({ timeZone: 'Europe/Berlin' }),
    title: '  Maths revision ',
    startsAtLocal: '2026-10-06T18:00',
    invitees: [{ userId: 'u1', displayName: 'Anna' }],
    capacityMode: 'plan',
    repeat: 'weekly',
    agenda: ' 1. Fractions ',
  };
  const input = formToInput(form);
  assert.equal(input.title, 'Maths revision');
  assert.equal(input.capacity, null);
  assert.deepEqual(input.inviteeIds, ['u1']);
  assert.equal(input.settings.agenda, '1. Fractions');
  assert.equal(input.recurrence.freq, 'WEEKLY');
  assert.equal('recurrence' in formToInput(form, { editing: true }), false);
});

test('validation explains what is missing', () => {
  const base = { ...defaultForm({ timeZone: 'UTC' }), title: 'Room', access: 'link' };
  assert.deepEqual(validateForm(base, config), {});
  assert.ok(validateForm({ ...base, title: ' ' }, config).title);
  assert.ok(validateForm({ ...base, earlyEntryMinutes: 15 }, config).earlyEntryMinutes);
  assert.ok(validateForm({ ...base, earlyEntryMinutes: 2 }, config).earlyEntryMinutes);
  assert.ok(validateForm({ ...base, capacity: 1 }, config).capacity);
  assert.ok(validateForm({ ...base, access: 'invited' }, config).invitees);
  assert.ok(validateForm({ ...base, repeat: 'weekly', repeatEnd: 'until', repeatUntil: '2000-01-01' }, config).repeat);
});

test('an existing room fills the editor', () => {
  const form = roomToForm({
    title: 'T', description: null, agenda: 'A', startsAt: '2026-10-06T16:00:00Z', endsAt: '2026-10-06T17:30:00Z',
    timeZone: 'Europe/Berlin', earlyEntryMinutes: 7, lateJoinMinutes: 10, capacity: null, access: 'link', approval: true,
    invitees: [], cohosts: [], settings: { learnersJoinMuted: true },
  });
  assert.equal(form.startsAtLocal, '2026-10-06T18:00');
  assert.equal(form.durationMinutes, 90);
  assert.equal(form.capacityMode, 'plan');
  assert.equal(form.learnersJoinMuted, true);
});

test('countdowns and durations read naturally', () => {
  assert.equal(countdown(0), 'now');
  assert.equal(countdown(35_000), 'in 35 s');
  assert.equal(countdown(4 * 60_000 + 1), 'in 5 min');
  assert.equal(countdown((2 * 60 + 5) * 60_000), 'in 2 h 5 min');
  assert.equal(countdown(3 * 24 * 3_600_000), 'in 3 days');
  assert.equal(durationLabel(45), '45 min');
  assert.equal(durationLabel(90), '1 h 30 min');
  assert.equal(durationLabel(120), '2 h');
});

test('a pasted code or link leads to the right place', () => {
  assert.equal(destinationFor('kqz-7hfd-2mx'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor(' KQZ-7HFD-2MX '), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('https://app.example/rooms/kqz-7hfd-2mx/lobby'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('https://app.example/rooms/kqz-7hfd-2mx'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('00000000-0000-0000-0000-000000000000'), '/rooms/00000000-0000-0000-0000-000000000000');
  assert.equal(destinationFor('not a room!'), null);
  assert.equal(destinationFor(''), null);
});
