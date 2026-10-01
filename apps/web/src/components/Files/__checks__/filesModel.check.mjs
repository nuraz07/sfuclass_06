// Files — early checks and wording.
// Run: node --test apps/web/src/components/Files/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { acceptAttribute, apiHref, fileMeta, fileProblem, formatBytes, reachableUploadUrl, usagePercent } from '../filesModel.js';

test('sizes and meta', () => {
  assert.equal(formatBytes(1), '1 byte');
  assert.equal(formatBytes(2048), '2 KB');
  assert.equal(formatBytes(1.5 * 1024 * 1024), '1.5 MB');
  assert.equal(formatBytes(50 * 1024 * 1024), '50 MB');
  assert.equal(fileMeta({ ext: 'pdf', sizeBytes: 2048 }), 'PDF, 2 KB');
  assert.equal(usagePercent({ usedBytes: 50, quotaBytes: 200 }), 25);
  assert.equal(usagePercent({ usedBytes: 500, quotaBytes: 200 }), 100);
});

test('early checks mirror the server', () => {
  assert.equal(fileProblem({ name: 'a.PDF', size: 10 }), null);
  assert.equal(fileProblem({ name: 'a.jpeg', size: 10 }), null);
  assert.match(fileProblem({ name: 'a.exe', size: 10 }), /not accepted/);
  assert.match(fileProblem({ name: 'a.svg', size: 10 }), /not accepted/);
  assert.match(fileProblem({ name: 'a.pdf', size: 0 }), /empty/);
  assert.match(fileProblem({ name: 'a.pdf', size: 60 * 1024 * 1024 }), /larger than 50 MB/);
  assert.match(acceptAttribute(['pdf', 'jpg']), /^\.pdf,\.jpg,\.jpeg$/);
});

test('upload URLs: local storage through the dev server, real storage untouched', () => {
  const page = 'https://crispy-5173.app.github.dev';
  assert.equal(
    reachableUploadUrl('http://localhost:9000/classroom-dev-raw/files/a/b.pdf?X-Amz-Signature=abc', page),
    'https://crispy-5173.app.github.dev/s3/classroom-dev-raw/files/a/b.pdf?X-Amz-Signature=abc',
  );
  assert.equal(reachableUploadUrl('https://bucket.s3.eu-central-1.amazonaws.com/x?sig=1', page), 'https://bucket.s3.eu-central-1.amazonaws.com/x?sig=1');
  assert.equal(apiHref('/files/1/content?t=x'), '/api/files/1/content?t=x');
  assert.equal(apiHref('/files/1', 'https://api.example.com/'), 'https://api.example.com/files/1');
  assert.equal(apiHref(null), null);
});
