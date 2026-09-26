// Settings, Phase C — passkey conversion in the browser and history wording.
// Run: node --test apps/web/src/components/Settings/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  creationOptionsFromJSON,
  fromBase64Url,
  requestOptionsFromJSON,
  suggestedPasskeyName,
  toBase64Url,
} from '../../../lib/webauthn.js';
import { describeHistoryEntry } from '../notificationsModel.js';

test('base64url round-trips bytes the way WebAuthn sends them', () => {
  const bytes = new Uint8Array([0, 1, 250, 251, 252, 253, 254, 255, 62, 63]);
  const text = toBase64Url(bytes);
  assert.doesNotMatch(text, /[+/=]/);
  assert.deepEqual(new Uint8Array(fromBase64Url(text)), bytes);
});

test('registration options become buffers where the browser wants them', () => {
  const options = creationOptionsFromJSON({
    challenge: toBase64Url(new Uint8Array([1, 2, 3])),
    rp: { id: 'localhost', name: 'Classroom' },
    user: { id: toBase64Url(new TextEncoder().encode('user-1')), name: 'a@b.c', displayName: 'A' },
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
    excludeCredentials: [{ id: toBase64Url(new Uint8Array([9])), transports: ['internal'] }],
  });
  assert.ok(options.challenge instanceof ArrayBuffer);
  assert.equal(new TextDecoder().decode(options.user.id), 'user-1');
  assert.equal(options.excludeCredentials[0].type, 'public-key');
  assert.deepEqual(new Uint8Array(options.excludeCredentials[0].id), new Uint8Array([9]));
});

test('sign-in options without allowed credentials let the browser choose', () => {
  const discoverable = requestOptionsFromJSON({ challenge: 'AQID', allowCredentials: [] });
  assert.equal('allowCredentials' in discoverable, false);
  const specific = requestOptionsFromJSON({ challenge: 'AQID', allowCredentials: [{ id: 'CQ', type: 'public-key' }] });
  assert.equal(specific.allowCredentials.length, 1);
});

test('a new passkey gets a readable name', () => {
  assert.equal(
    suggestedPasskeyName('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'),
    'Chrome on Windows',
  );
  assert.equal(
    suggestedPasskeyName('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    'Safari on iPhone or iPad',
  );
});

test('security changes read as sentences', () => {
  assert.equal(describeHistoryEntry({ action: 'security.totp.enabled' }), 'Two-step sign-in turned on (authenticator app)');
  assert.equal(describeHistoryEntry({ action: 'security.password.changed', count: 2 }), 'Password changed; 2 other devices signed out');
  assert.equal(describeHistoryEntry({ action: 'security.passkey.added', detail: 'Chrome on Mac' }), 'Passkey added: Chrome on Mac');
  assert.equal(describeHistoryEntry({ action: 'auth.second_factor.failed', detail: 'code' }), 'Password right, wrong second-step code');
  assert.equal(describeHistoryEntry({ action: 'account.deletion.requested' }), 'Account deletion requested');
});
