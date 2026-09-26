// Rooms — who may enter when, and what a valid room is.
// Run: node --test server/test/rooms/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  CreateRoomSchema,
  entryDecision,
  freeSeats,
  icsFor,
  isRoomCode,
  newRoomCode,
  phaseOf,
  relationOf,
  windowFor,
} from '../../src/rooms/roomRules.js';

const T = Date.parse('2026-10-06T16:00:00Z');
const min = 60_000;
const room = (overrides = {}) => ({
  id: 's1',
  hostId: 'host',
  cohostIds: ['co'],
  status: 'scheduled',
  startsAt: new Date(T).toISOString(),
  endsAt: new Date(T + 60 * min).toISOString(),
  earlyEntryMinutes: 5,
  lateJoinMinutes: null,
  capacity: null,
  access: 'invited',
  approval: false,
  title: 'Maths, revision; part 1',
  sequence: 2,
  ...overrides,
});

test('room codes are readable and unguessable', () => {
  const codes = new Set(Array.from({ length: 500 }, newRoomCode));
  assert.equal(codes.size, 500);
  for (const code of codes) assert.ok(isRoomCode(code), code);
  assert.equal(isRoomCode('00000000-0000-0000-0000-000000000000'), false);
  assert.equal(isRoomCode('abc-defg-hjk'), true);
  assert.equal(isRoomCode('abc-defg-hjl'), false); // no l
});

test('the timeline: host 30 min early, doors 3–10 min early', () => {
  const time = windowFor(room({ earlyEntryMinutes: 7, lateJoinMinutes: 10 }));
  assert.equal(time.hostOpensAt, T - 30 * min);
  assert.equal(time.doorsOpenAt, T - 7 * min);
  assert.equal(time.lateUntil, T + 10 * min);
  assert.equal(windowFor(room({ earlyEntryMinutes: 60 })).doorsOpenAt, T - 10 * min);
  assert.equal(windowFor(room({ earlyEntryMinutes: 0 })).doorsOpenAt, T - 3 * min);
});

test('phases', () => {
  assert.equal(phaseOf(room(), T - 6 * min), 'scheduled');
  assert.equal(phaseOf(room(), T - 5 * min), 'doors-open');
  assert.equal(phaseOf(room(), T), 'live');
  assert.equal(phaseOf(room(), T + 60 * min), 'ended');
  assert.equal(phaseOf(room({ status: 'cancelled' }), T), 'cancelled');
});

test('relations: host, co-host, invitee, link guest, nobody', () => {
  assert.equal(relationOf(room(), { userId: 'host' }), 'host');
  assert.equal(relationOf(room(), { userId: 'co' }), 'cohost');
  assert.equal(relationOf(room(), { userId: 'x', invited: true }), 'invitee');
  assert.equal(relationOf(room(), { userId: 'x' }), null);
  assert.equal(relationOf(room({ access: 'link' }), { userId: 'x' }), 'guest');
  assert.equal(relationOf(room({ access: 'link' }), { userId: 'x', sameTenant: false }), null);
});

test('doors: before, at, and the host exception', () => {
  const r = room();
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T - 6 * min }).code, 'room_not_open');
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T - 6 * min }).opensAt, T - 5 * min);
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T - 5 * min }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'host', now: T - 20 * min }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'cohost', now: T - 31 * min }).code, 'room_not_open');
  assert.equal(entryDecision({ room: r, relation: null, now: T }).code, 'not_invited');
});

test('late entry: new people refused, returning people welcome', () => {
  const r = room({ lateJoinMinutes: 10 });
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T + 9 * min }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T + 11 * min }).code, 'room_closed_for_entry');
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T + 11 * min, joinedBefore: true }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'host', now: T + 50 * min }).allowed, true);
});

test('approval, capacity and held seats', () => {
  const knock = room({ approval: true });
  assert.equal(entryDecision({ room: knock, relation: 'guest', now: T }).code, 'needs_admission');
  assert.equal(entryDecision({ room: knock, relation: 'guest', now: T, admitted: true }).allowed, true);
  assert.equal(entryDecision({ room: knock, relation: 'host', now: T }).allowed, true);

  const small = room({ capacity: 3 });
  assert.equal(entryDecision({ room: small, relation: 'invitee', now: T, occupiedByOthers: 2 }).allowed, true);
  assert.equal(entryDecision({ room: small, relation: 'invitee', now: T, occupiedByOthers: 2, heldForOthers: 1 }).code, 'room_full');
  assert.equal(entryDecision({ room: small, relation: 'invitee', now: T, occupiedByOthers: 3, holdsSeat: true }).allowed, true);
  assert.equal(entryDecision({ room: small, relation: 'host', now: T, occupiedByOthers: 3 }).allowed, true);
  assert.equal(freeSeats({ capacity: 3, occupied: 1, held: 1 }), 1);
  assert.equal(freeSeats({ capacity: 3, occupied: 4, held: 0 }), 0);
});

test('ended and cancelled rooms admit nobody, hosts included', () => {
  assert.equal(entryDecision({ room: room(), relation: 'host', now: T + 60 * min }).code, 'room_ended');
  assert.equal(entryDecision({ room: room({ status: 'cancelled' }), relation: 'host', now: T }).code, 'room_cancelled');
});

test('create input: doors between 3 and 10 minutes, a series needs an end', () => {
  const base = {
    title: 'Room', startsAtLocal: '2026-10-06T18:00', durationMinutes: 60, timeZone: 'Europe/Berlin',
  };
  assert.equal(CreateRoomSchema.parse(base).earlyEntryMinutes, 5);
  assert.equal(CreateRoomSchema.safeParse({ ...base, earlyEntryMinutes: 2 }).success, false);
  assert.equal(CreateRoomSchema.safeParse({ ...base, earlyEntryMinutes: 11 }).success, false);
  assert.equal(CreateRoomSchema.safeParse({ ...base, earlyEntryMinutes: 10 }).success, true);
  assert.equal(CreateRoomSchema.safeParse({ ...base, recurrence: { freq: 'WEEKLY' } }).success, false);
  assert.equal(CreateRoomSchema.safeParse({ ...base, recurrence: { freq: 'WEEKLY', count: 4 } }).success, true);
  assert.equal(CreateRoomSchema.safeParse({ ...base, surprise: true }).success, false);
});

test('the calendar file is valid, escaped and folded', () => {
  const text = icsFor({ room: room({ description: 'Bring a calculator' }), url: 'https://app.example/rooms/abc-defg-hjk/lobby', now: new Date(T) });
  assert.ok(text.startsWith('BEGIN:VCALENDAR\r\n'));
  assert.ok(text.includes('DTSTART:20261006T160000Z'));
  assert.ok(text.includes('SUMMARY:Maths\\, revision\\; part 1'));
  assert.ok(text.includes('SEQUENCE:2'));
  assert.ok(text.includes('TRIGGER:-PT5M'));
  for (const line of text.split('\r\n')) assert.ok(Buffer.byteLength(line) <= 75, line);
  assert.ok(icsFor({ room: room({ status: 'cancelled' }), url: 'u' }).includes('METHOD:CANCEL'));
});
