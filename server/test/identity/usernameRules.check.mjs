// Usernames — what is allowed, and email-or-username.
// Run: node --test server/test/identity/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { isEmail, normalise, problemWith } from '../../src/identity/usernameRules.js';

test('good usernames', () => {
  for (const name of ['anna', 'anna.b', 'Anna_B', 'a1b', 'mr-okafor', 'x'.repeat(30)]) assert.equal(problemWith(name), null, name);
  assert.equal(normalise('  Anna.B '), 'anna.b');
});

test('refused usernames, with reasons', () => {
  assert.match(problemWith('ab'), /At least 3/);
  assert.match(problemWith('x'.repeat(31)), /At most 30/);
  assert.match(problemWith('anna@x'), /"@"/);
  assert.match(problemWith('anna b'), /Only letters/);
  assert.match(problemWith('ännä'), /Only letters/);
  assert.match(problemWith('.anna'), /Start and end/);
  assert.match(problemWith('anna_'), /Start and end/);
  assert.match(problemWith('an..na'), /two dots/);
  assert.match(problemWith('Admin'), /reserved/);
});

test('an "@" makes it an email address', () => {
  assert.equal(isEmail('anna@school.example'), true);
  assert.equal(isEmail('anna.b'), false);
});
