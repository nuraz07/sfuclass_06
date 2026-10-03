// classroom-app/server/src/files/fileRules.js
/**
 * What may be uploaded, and how it is served  (Files)
 *
 * Pure: no storage, no database, no clock of its own — tested in
 * server/test/files/fileRules.check.mjs.
 *
 * Only the formats people use every day are accepted, decided by the file
 * extension and then *confirmed by the bytes*: a file called photo.png that is
 * not a PNG is refused, whatever the browser claimed. The content type sent to
 * browsers comes from this table, never from the uploader. SVG, HTML and
 * anything else that can run code in a page is not on the list.
 *
 *   inline      opens in the browser (new tab): PDF, images, video, audio, text
 *   attachment  downloads: Office documents, CSV
 */

import { createHmac, timingSafeEqual } from 'node:crypto';

export const FORMATS = Object.freeze({
  pdf: { type: 'application/pdf', kind: 'document', inline: true, magic: 'pdf' },
  png: { type: 'image/png', kind: 'image', inline: true, magic: 'png' },
  jpg: { type: 'image/jpeg', kind: 'image', inline: true, magic: 'jpeg' },
  jpeg: { type: 'image/jpeg', kind: 'image', inline: true, magic: 'jpeg' },
  gif: { type: 'image/gif', kind: 'image', inline: true, magic: 'gif' },
  webp: { type: 'image/webp', kind: 'image', inline: true, magic: 'webp' },
  txt: { type: 'text/plain; charset=utf-8', kind: 'text', inline: true, magic: 'text' },
  csv: { type: 'text/csv; charset=utf-8', kind: 'text', inline: false, magic: 'text' },
  docx: { type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', kind: 'document', inline: false, magic: 'zip' },
  xlsx: { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', kind: 'document', inline: false, magic: 'zip' },
  pptx: { type: 'application/vnd.openxmlformats-officedocument.presentationml.presentation', kind: 'document', inline: false, magic: 'zip' },
  doc: { type: 'application/msword', kind: 'document', inline: false, magic: 'ole' },
  xls: { type: 'application/vnd.ms-excel', kind: 'document', inline: false, magic: 'ole' },
  ppt: { type: 'application/vnd.ms-powerpoint', kind: 'document', inline: false, magic: 'ole' },
  mp4: { type: 'video/mp4', kind: 'video', inline: true, magic: 'ftyp' },
  m4a: { type: 'audio/mp4', kind: 'audio', inline: true, magic: 'ftyp' },
  mp3: { type: 'audio/mpeg', kind: 'audio', inline: true, magic: 'mp3' },
  wav: { type: 'audio/wav', kind: 'audio', inline: true, magic: 'wav' },
});

export const EXTENSIONS = Object.keys(FORMATS);
export const KINDS = ['image', 'document', 'video', 'audio', 'text'];
export const SNIFF_BYTES = 4096;

export const extensionOf = (name) => {
  const match = /\.([a-z0-9]{1,5})$/i.exec(String(name ?? '').trim());
  return match ? match[1].toLowerCase() : null;
};

export const formatOf = (name) => FORMATS[extensionOf(name)] ?? null;

/**
 * A name that is safe in a storage key and in a Content-Disposition header:
 * no paths, no control characters, at most 120 characters, extension kept.
 */
export const safeName = (name) => {
  const base = String(name ?? '')
    .split(/[\\/]/)
    .pop()
    .normalize('NFKC')
    .replace(/[\u0000-\u001f\u007f"<>|:*?]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  const ext = extensionOf(base);
  if (!base || !ext) return null;
  const stem = base.slice(0, base.length - ext.length - 1).slice(0, 110).trim() || 'file';
  return `${stem}.${ext}`;
};

const startsWith = (bytes, signature, offset = 0) => signature.every((byte, i) => bytes[offset + i] === byte);
const ascii = (text) => [...text].map((c) => c.charCodeAt(0));

/** Do the first bytes look like the format the extension promises? */
export const bytesMatch = (magic, bytes) => {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes ?? []);
  switch (magic) {
    case 'pdf':
      return startsWith(b, ascii('%PDF-'));
    case 'png':
      return startsWith(b, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    case 'jpeg':
      return startsWith(b, [0xff, 0xd8, 0xff]);
    case 'gif':
      return startsWith(b, ascii('GIF87a')) || startsWith(b, ascii('GIF89a'));
    case 'webp':
      return startsWith(b, ascii('RIFF')) && startsWith(b, ascii('WEBP'), 8);
    case 'wav':
      return startsWith(b, ascii('RIFF')) && startsWith(b, ascii('WAVE'), 8);
    case 'zip':
      return startsWith(b, [0x50, 0x4b, 0x03, 0x04]);
    case 'ole':
      return startsWith(b, [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]);
    case 'ftyp':
      return startsWith(b, ascii('ftyp'), 4);
    case 'mp3':
      return startsWith(b, ascii('ID3')) || (b[0] === 0xff && (b[1] & 0xe0) === 0xe0);
    case 'text': {
      if (b.includes(0)) return false;
      try {
        // A cut in the middle of a multi-byte character at the end is fine.
        new TextDecoder('utf-8', { fatal: true }).decode(b.length >= SNIFF_BYTES ? b.subarray(0, b.length - 4) : b);
        return true;
      } catch {
        return false;
      }
    }
    default:
      return false;
  }
};

/** Checks a file before an upload starts. Returns a reason, or null when fine. */
export const uploadProblem = ({ name, sizeBytes, maxBytes }) => {
  const clean = safeName(name);
  if (!clean) return 'This file has no name or no extension.';
  if (!formatOf(clean)) {
    return `This format is not accepted. Allowed: ${EXTENSIONS.filter((ext) => ext !== 'jpeg').map((ext) => ext.toUpperCase()).join(', ')}.`;
  }
  if (!Number.isInteger(sizeBytes) || sizeBytes < 1) return 'This file is empty.';
  if (sizeBytes > maxBytes) return `This file is larger than ${Math.round(maxBytes / 1024 / 1024)} MB.`;
  return null;
};

// ---------------------------------------------------------------------------
// Signed links: opening a file in a new tab, where no Authorization header goes
// ---------------------------------------------------------------------------

const sign = (secret, payload) => createHmac('sha256', secret).update(payload).digest('base64url');

/** `fileId.expires.signature` — a capability to read one file until `expires`. */
export const linkToken = ({ fileId, expiresAt, secret }) => {
  const exp = Math.floor(expiresAt / 1000);
  return `${exp}.${sign(secret, `${fileId}.${exp}`)}`;
};

export const verifyLinkToken = ({ fileId, token, secret, now = Date.now() }) => {
  const [exp, signature] = String(token ?? '').split('.');
  if (!exp || !signature || !/^\d+$/.test(exp)) return false;
  if (Number(exp) * 1000 < now) return false;
  const expected = Buffer.from(sign(secret, `${fileId}.${exp}`));
  const given = Buffer.from(signature);
  return expected.length === given.length && timingSafeEqual(expected, given);
};

/**
 * Headers for serving a file. Inline formats open in the tab; the rest
 * download. Every response forbids content sniffing, and everything but PDF
 * (whose viewer needs to run) is served with a CSP that allows nothing to
 * execute.
 */
export const deliveryHeaders = ({ ext, name, sizeBytes }) => {
  const format = FORMATS[ext];
  const encoded = encodeURIComponent(name).replace(/['()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  const fallback = name.replace(/[^\x20-\x7e]/g, '_');
  const headers = {
    'Content-Type': format.type,
    'Content-Disposition': `${format.inline ? 'inline' : 'attachment'}; filename="${fallback}"; filename*=UTF-8''${encoded}`,
    'X-Content-Type-Options': 'nosniff',
    'Cache-Control': 'private, max-age=3600',
    'Accept-Ranges': 'bytes',
    'Cross-Origin-Resource-Policy': 'same-site',
    'Referrer-Policy': 'no-referrer',
  };
  if (format.magic !== 'pdf') {
    headers['Content-Security-Policy'] = "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; sandbox";
  }
  if (sizeBytes !== undefined) headers['Content-Length'] = String(sizeBytes);
  return headers;
};

/** "bytes=0-1023" → { start, end } within the file, or null for anything else. */
export const parseRange = (header, size) => {
  const match = /^bytes=(\d*)-(\d*)$/.exec(String(header ?? '').trim());
  if (!match || (match[1] === '' && match[2] === '')) return null;
  let start;
  let end;
  if (match[1] === '') {
    const suffix = Number(match[2]);
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === '' ? size - 1 : Math.min(Number(match[2]), size - 1);
  }
  return start <= end && start < size ? { start, end } : null;
};

export default {
  FORMATS, EXTENSIONS, KINDS, SNIFF_BYTES, extensionOf, formatOf, safeName, bytesMatch, uploadProblem,
  linkToken, verifyLinkToken, deliveryHeaders, parseRange,
};
