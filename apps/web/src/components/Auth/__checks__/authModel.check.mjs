// Landing — sign-in and sign-up helpers.
// Run: node --test apps/web/src/components/Auth/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { destinationOf, passwordStrength, safeNext, validateSignup, withNext } from '../authModel.js';

test('password strength grows with length first', () => {
  assert.equal(passwordStrength(''), 0);
  assert.equal(passwordStrength('short'), 1);
  assert.equal(passwordStrength('abcdefghijkl'), 2);
  assert.equal(passwordStrength('Abcdefghijk1'), 3);
  assert.equal(passwordStrength('correct horse battery staple'), 4);
});

test('sign-up validation', () => {
  assert.deepEqual(validateSignup({ displayName: 'Anna', email: 'anna@example.com', password: 'twelve chars!' }), {});
  const errors = validateSignup({ displayName: ' ', email: 'anna@', password: 'short' });
  assert.ok(errors.displayName && errors.email && errors.password);
});

test('destinations after signing in never leave the app', () => {
  assert.equal(destinationOf({ search: '?next=%2Frooms%2Fnew' }), '/rooms/new');
  assert.equal(destinationOf({ search: '?next=https%3A%2F%2Fevil.example' }), '/');
  assert.equal(destinationOf({ search: '?next=%2F%2Fevil.example' }), '/');
  assert.equal(destinationOf({ state: { from: '/rooms/abc-defg-hjk/lobby' } }), '/rooms/abc-defg-hjk/lobby');
  assert.equal(destinationOf({}), '/');
  assert.equal(safeNext('/\\evil'), '/');
  assert.equal(withNext('/signup', '/rooms/new'), '/signup?next=%2Frooms%2Fnew');
  assert.equal(withNext('/signup', '/'), '/signup');
});
