// Files — formats, byte checks, names, signed links, ranges.
// Run: node --test server/test/files/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  bytesMatch, deliveryHeaders, extensionOf, formatOf, linkToken, parseRange, safeName, uploadProblem, verifyLinkToken,
} from '../../src/files/fileRules.js';

const bytes = (...parts) => new Uint8Array(parts.flatMap((p) => (typeof p === 'string' ? [...p].map((c) => c.charCodeAt(0)) : p)));

test('only everyday formats, decided by extension', () => {
  assert.equal(formatOf('Worksheet 4.PDF').type, 'application/pdf');
  assert.equal(formatOf('photo.jpeg').kind, 'image');
  assert.equal(formatOf('slides.pptx').inline, false);
  for (const bad of ['page.html', 'logo.svg', 'tool.exe', 'script.js', 'archive.zip', 'noextension']) assert.equal(formatOf(bad), null, bad);
  assert.equal(extensionOf('a.tar.gz'), 'gz');
});

test('the bytes must confirm the extension', () => {
  assert.equal(bytesMatch('pdf', bytes('%PDF-1.7\n')), true);
  assert.equal(bytesMatch('pdf', bytes('<html>')), false);
  assert.equal(bytesMatch('png', bytes([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0])), true);
  assert.equal(bytesMatch('jpeg', bytes([0xff, 0xd8, 0xff, 0xe0])), true);
  assert.equal(bytesMatch('jpeg', bytes('GIF89a')), false);
  assert.equal(bytesMatch('webp', bytes('RIFF', [0, 0, 0, 0], 'WEBPVP8 ')), true);
  assert.equal(bytesMatch('wav', bytes('RIFF', [0, 0, 0, 0], 'WEBP')), false);
  assert.equal(bytesMatch('zip', bytes([0x50, 0x4b, 0x03, 0x04])), true);
  assert.equal(bytesMatch('ole', bytes([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])), true);
  assert.equal(bytesMatch('ftyp', bytes([0, 0, 0, 0x18], 'ftypmp42')), true);
  assert.equal(bytesMatch('mp3', bytes('ID3', [4, 0])), true);
  assert.equal(bytesMatch('text', bytes('Name,Age\nAnna,12\n')), true);
  assert.equal(bytesMatch('text', bytes('ok', [0], 'binary')), false);
  assert.equal(bytesMatch('text', new Uint8Array([0xc3, 0x28])), false);
  assert.equal(bytesMatch('text', new TextEncoder().encode('Grüße, ½ + ¼')), true);
});

test('names are made safe', () => {
  assert.equal(safeName('../../etc/passwd.txt'), 'passwd.txt');
  assert.equal(safeName('C:\\Users\\me\\Report "final".docx'), 'Report final.docx');
  assert.equal(safeName('  lots   of   space .pdf'), 'lots of space.pdf');
  assert.equal(safeName('noext'), null);
  assert.equal(safeName(`${'x'.repeat(300)}.png`).length, 114);
});

test('upload checks', () => {
  const max = 50 * 1024 * 1024;
  assert.equal(uploadProblem({ name: 'a.pdf', sizeBytes: 10, maxBytes: max }), null);
  assert.match(uploadProblem({ name: 'a.exe', sizeBytes: 10, maxBytes: max }), /not accepted/);
  assert.match(uploadProblem({ name: 'a.pdf', sizeBytes: 0, maxBytes: max }), /empty/);
  assert.match(uploadProblem({ name: 'a.pdf', sizeBytes: max + 1, maxBytes: max }), /larger than 50 MB/);
});

test('signed links: valid until they expire, bound to one file and one secret', () => {
  const now = Date.parse('2026-10-01T12:00:00Z');
  const token = linkToken({ fileId: 'f1', expiresAt: now + 3_600_000, secret: 's3cret' });
  assert.equal(verifyLinkToken({ fileId: 'f1', token, secret: 's3cret', now }), true);
  assert.equal(verifyLinkToken({ fileId: 'f2', token, secret: 's3cret', now }), false);
  assert.equal(verifyLinkToken({ fileId: 'f1', token, secret: 'other', now }), false);
  assert.equal(verifyLinkToken({ fileId: 'f1', token, secret: 's3cret', now: now + 3_700_000 }), false);
  assert.equal(verifyLinkToken({ fileId: 'f1', token: 'garbage', secret: 's3cret', now }), false);
  assert.equal(verifyLinkToken({ fileId: 'f1', token: `${token}x`, secret: 's3cret', now }), false);
});

test('delivery headers: inline or download, never sniffed, nothing executes', () => {
  const pdf = deliveryHeaders({ ext: 'pdf', name: 'Worksheet.pdf', sizeBytes: 10 });
  assert.match(pdf['Content-Disposition'], /^inline;/);
  assert.equal(pdf['X-Content-Type-Options'], 'nosniff');
  assert.equal(pdf['Content-Security-Policy'], undefined);
  const png = deliveryHeaders({ ext: 'png', name: 'Bild ½.png' });
  assert.match(png['Content-Security-Policy'], /sandbox/);
  assert.match(png['Content-Disposition'], /filename\*=UTF-8''Bild%20%C2%BD\.png/);
  assert.match(deliveryHeaders({ ext: 'docx', name: 'a.docx' })['Content-Disposition'], /^attachment;/);
});

test('ranges for video and audio', () => {
  assert.deepEqual(parseRange('bytes=0-99', 1000), { start: 0, end: 99 });
  assert.deepEqual(parseRange('bytes=900-', 1000), { start: 900, end: 999 });
  assert.deepEqual(parseRange('bytes=-100', 1000), { start: 900, end: 999 });
  assert.deepEqual(parseRange('bytes=0-5000', 1000), { start: 0, end: 999 });
  assert.equal(parseRange('bytes=2000-', 1000), null);
  assert.equal(parseRange('items=0-1', 1000), null);
  assert.equal(parseRange(undefined, 1000), null);
});
