// Rooms · links — links that open for whoever receives them.
// Run: node --test server/test/rooms/*.check.mjs
// Uses the pure rules only (config/publicUrlRules.js): no environment needed.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  chooseLinkOrigin,
  hostedWorkspaceUrl,
  isLocalOrigin,
  originOf,
  resolvePublicAppUrl,
} from '../../src/config/publicUrlRules.js';

const CS = 'crispy-umbrella-6v97r5rw7pvph5pp5';
const CS_URL = `https://${CS}-5173.app.github.dev`;

test('plain local development keeps APP_URL', () => {
  assert.equal(resolvePublicAppUrl({ environment: {}, appUrl: 'http://localhost:5173' }), 'http://localhost:5173');
  assert.equal(resolvePublicAppUrl({ environment: {}, appUrl: null }), 'http://localhost:5173');
});

test('any Codespace: the forwarded address of APP_URL’s port, with no configuration', () => {
  const environment = { CODESPACE_NAME: CS, GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN: 'app.github.dev' };
  assert.equal(resolvePublicAppUrl({ environment, appUrl: 'http://localhost:5173/' }), CS_URL);
  // A fresh clone lands in a codespace with another name: the link follows.
  assert.equal(
    resolvePublicAppUrl({ environment: { CODESPACE_NAME: 'fuzzy-train-123' }, appUrl: 'http://localhost:3000' }),
    'https://fuzzy-train-123-3000.app.github.dev',
  );
});

test('Gitpod works the same way', () => {
  assert.equal(
    hostedWorkspaceUrl({ environment: { GITPOD_WORKSPACE_URL: 'https://user-repo-abc.ws-eu.gitpod.io' }, port: '5173' }),
    'https://5173-user-repo-abc.ws-eu.gitpod.io',
  );
  assert.equal(hostedWorkspaceUrl({ environment: {}, port: '5173' }), null);
});

test('a real APP_URL is kept, PUBLIC_APP_URL pins everything', () => {
  assert.equal(
    resolvePublicAppUrl({ environment: { CODESPACE_NAME: CS }, appUrl: 'https://classroom.example' }),
    'https://classroom.example',
  );
  assert.equal(
    resolvePublicAppUrl({ environment: { CODESPACE_NAME: CS, PUBLIC_APP_URL: 'https://tunnel.example/' }, appUrl: 'http://localhost:5173' }),
    'https://tunnel.example',
  );
  assert.equal(
    resolvePublicAppUrl({ environment: { PUBLIC_APP_URL: 'not a url' }, appUrl: 'http://localhost:5173' }),
    'http://localhost:5173',
  );
});

test('links for a request: the browser’s own address when trusted, never localhost for others', () => {
  const trusted = (origin) => origin === CS_URL || isLocalOrigin(origin);
  assert.equal(chooseLinkOrigin({ candidates: [CS_URL], fallback: CS_URL, trusted }), CS_URL);
  // Someone on localhost (VS Code on the desktop) still shares the public address.
  assert.equal(chooseLinkOrigin({ candidates: ['http://localhost:5173'], fallback: CS_URL, trusted }), CS_URL);
  // Untrusted origins are never echoed into a link.
  assert.equal(chooseLinkOrigin({ candidates: ['https://evil.example'], fallback: CS_URL, trusted }), CS_URL);
  // Referer with a path: only its origin counts.
  assert.equal(chooseLinkOrigin({ candidates: [`${CS_URL}/rooms/x/lobby`], fallback: 'http://localhost:5173', trusted }), CS_URL);
  // Plain local development: localhost is the right answer.
  assert.equal(
    chooseLinkOrigin({ candidates: ['http://localhost:5173'], fallback: 'http://localhost:5173', trusted }),
    'http://localhost:5173',
  );
});

test('origins', () => {
  assert.equal(originOf('https://a.example/path?q=1'), 'https://a.example');
  assert.equal(originOf('javascript:alert(1)'), null);
  assert.equal(originOf(''), null);
  assert.ok(isLocalOrigin('http://localhost:5173'));
  assert.ok(isLocalOrigin('http://127.0.0.1:4000'));
  assert.ok(!isLocalOrigin(CS_URL));
});
