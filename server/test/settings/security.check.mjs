// Settings, Phase C — the pure parts of two-step sign-in and the data export.
// Run: node --test server/test/settings/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';

import { base32Decode, base32Encode, codeAt, generateSecret, otpauthUri, stepAt, verifyCode } from '../../src/security/totp.js';
import { generateCodes, hashCode, looksLikeRecoveryCode, normalizeCode } from '../../src/security/recoveryCodes.js';
import { deriveKey, open, seal } from '../../src/security/secretBox.js';
import { exportFileName, stripSensitive } from '../../src/security/exportSanitize.js';

const RFC_SEED = Buffer.from('12345678901234567890', 'ascii');

test('TOTP matches the RFC 6238 test vectors (SHA-1, 8 digits)', () => {
  for (const [seconds, expected] of [
    [59, '94287082'],
    [1111111109, '07081804'],
    [1111111111, '14050471'],
    [1234567890, '89005924'],
    [2000000000, '69279037'],
  ]) {
    assert.equal(codeAt(RFC_SEED, stepAt(seconds * 1000), 8), expected);
  }
});

test('base32 round-trips and secrets are 32 characters', () => {
  const bytes = randomBytes(20);
  assert.deepEqual(base32Decode(base32Encode(bytes)), bytes);
  assert.equal(base32Encode(Buffer.from('foobar')), 'MZXW6YTBOI');
  assert.match(generateSecret(), /^[A-Z2-7]{32}$/);
});

test('codes: current and neighbouring steps pass, a used step never again', () => {
  const secret = generateSecret();
  const now = Date.UTC(2026, 8, 26, 12, 0, 10);
  const step = stepAt(now);
  assert.equal(verifyCode(secret, codeAt(secret, step), { now }), step);
  assert.equal(verifyCode(secret, codeAt(secret, step - 1), { now }), step - 1);
  assert.equal(verifyCode(secret, codeAt(secret, step + 1), { now }), step + 1);
  assert.equal(verifyCode(secret, codeAt(secret, step - 2), { now }), null);
  assert.equal(verifyCode(secret, codeAt(secret, step), { now, lastUsedStep: step }), null);
  assert.equal(verifyCode(secret, '12345', { now }), null);
  const spaced = codeAt(secret, step).replace(/(\d{3})/, '$1 ');
  assert.equal(verifyCode(secret, spaced, { now }), step);
});

test('otpauth link carries issuer, account and parameters', () => {
  const uri = otpauthUri({ secret: 'JBSWY3DPEHPK3PXP', accountName: 'anna@example.com' });
  assert.ok(uri.startsWith('otpauth://totp/Classroom%3Aanna%40example.com?'));
  const params = new URL(uri).searchParams;
  assert.equal(params.get('secret'), 'JBSWY3DPEHPK3PXP');
  assert.equal(params.get('digits'), '6');
  assert.equal(params.get('period'), '30');
});

test('recovery codes: ten, unique, typed any way, hashed', () => {
  const codes = generateCodes();
  assert.equal(codes.length, 10);
  assert.equal(new Set(codes).size, 10);
  for (const code of codes) assert.match(code, /^[a-z2-9]{4}-[a-z2-9]{4}$/);
  assert.equal(normalizeCode(' ABCD efgh '), 'abcd-efgh');
  assert.equal(normalizeCode('abcd-efg'), null);
  assert.equal(looksLikeRecoveryCode('abcd-efgh'), true);
  assert.equal(looksLikeRecoveryCode('123456'), false);
  assert.equal(hashCode('abcd-efgh'), hashCode(normalizeCode('ABCDEFGH')));
  assert.notEqual(hashCode('abcd-efgh'), 'abcd-efgh');
});

test('secretBox: round-trip, wrong key and tampering are refused', () => {
  const key = deriveKey('cookie-secret-for-tests');
  const sealed = seal('JBSWY3DPEHPK3PXP', key);
  assert.ok(sealed.startsWith('v1.'));
  assert.ok(!sealed.includes('JBSWY3DPEHPK3PXP'));
  assert.equal(open(sealed, key), 'JBSWY3DPEHPK3PXP');
  assert.throws(() => open(sealed, deriveKey('another secret')));
  const parts = sealed.split('.');
  parts[3] = parts[3].slice(0, -2) + (parts[3].endsWith('AA') ? 'BB' : 'AA');
  assert.throws(() => open(parts.join('.'), key));
  assert.equal(deriveKey('x').length, 32);
});

test('the export never carries secrets', () => {
  const clean = stripSensitive({
    id: 1,
    body: 'hello',
    password_hash: 'scrypt$…',
    secret_encrypted: 'v1.…',
    refresh_token_hash: 'x',
    p256dh: 'k',
    auth: 'a',
    public_key: Buffer.from('k'),
    created_at: new Date('2026-01-01T00:00:00Z'),
  });
  assert.deepEqual(clean, { id: 1, body: 'hello', created_at: '2026-01-01T00:00:00.000Z' });
  assert.equal(exportFileName(new Date('2026-09-26T10:00:00Z')), 'classroom-export-2026-09-26.json');
});
