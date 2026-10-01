#!/usr/bin/env bash
# materials-install.sh — Community materials: links to any website, and file uploads.
#
#   - any member of a space adds a link (any website) or uploads a file
#   - only everyday formats: PDF, PNG, JPG, GIF, WEBP, TXT, CSV, DOCX, XLSX,
#     PPTX, DOC, XLS, PPT, MP4, M4A, MP3, WAV — checked by their actual bytes,
#     not just the name, then scanned (ANTIVIRUS_MODE), up to 50 MB each
#   - files open in a new tab (PDF, pictures, video, audio, text) or download
#     (Office documents, CSV) through a link that is valid for two hours
#   - moderators pin; whoever added something, or a moderator, removes it
#
# Needs Community parts 1–3.
# Run from the project folder:  bash materials-install.sh
# Writes 18 files, patches 3 more, backup in .materials-backup/<timestamp>/.
# Undo:                         bash materials-install.sh --restore
#   (the table and columns added by 029 stay — they are unused without these files)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/029_files.sql
  server/src/files/fileRules.js
  server/src/files/FileStore.js
  server/src/files/FileService.js
  server/src/routes/files.routes.js
  server/src/hub/hubRules.js
  server/src/hub/HubExtras.js
  server/test/files/fileRules.check.mjs
  server/test/hub/hubRules.check.mjs
  packages/core-client/src/api/filesApi.ts
  packages/core-client/src/api/hubApi.ts
  apps/web/src/lib/files.js
  apps/web/src/components/Files/filesModel.js
  apps/web/src/components/Files/FileDrop.jsx
  apps/web/src/components/Files/__checks__/filesModel.check.mjs
  apps/web/src/components/Hub/SpaceMaterials.jsx
  apps/web/src/components/Files/files.css
  apps/web/src/components/Hub/hub.css
  server/src/app.js
  packages/core-client/src/index.ts
  apps/web/vite.config.ts
  apps/web/.env.local
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .materials-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/029_files.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  echo "Restored from $FIRST. The migration file 029 stays, because the database already has it."
  exit 0
fi

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need server/src/hub/HubPart3.js "startHubScheduler" "Community part 3 (community3-install.sh)"
need server/src/hub/HubExtras.js "export const listMaterials" "Community part 2"
need server/src/db/migrations/027_community_part2.sql "space_materials" "Community part 2"
need server/src/config/storage.config.js "s3ClientOptions" "object storage configuration"
need server/src/app.js "scheduledRoomsRoutes" "the rooms feature"
need packages/core-client/src/index.ts "hubApi" "Community part 1"
need apps/web/vite.config.ts "'/socket.io': {" "the dev server proxy"
need apps/web/src/components/Settings/notificationsModel.js "relativeTime" "Settings Phase B"
if [ ! -d node_modules/@aws-sdk/s3-request-presigner ] && [ ! -d server/node_modules/@aws-sdk/s3-request-presigner ]; then
  MISSING+=("@aws-sdk/s3-request-presigner is not installed (npm install -w @classroom/server)")
fi
if ls server/src/db/migrations/029_*.sql 2>/dev/null | grep -qv 029_files.sql; then
  MISSING+=("another migration 029 exists: $(ls server/src/db/migrations/029_*.sql | tr '\n' ' ')")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what the materials update expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".materials-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/029_files.sql <<'__MAT_EOF__'
-- 029_files.sql  (Files and Media)
--
--   files            everyone's own uploads: the Media library. Bytes live in
--                    object storage (raw bucket until checked, then delivery);
--                    this row is the catalogue entry.
--   space_materials  can now point at a file instead of a link.
--
-- Additive only.

create table if not exists files (
  id            uuid        primary key default gen_random_uuid(),
  tenant_id     uuid        not null references tenants (id) on delete cascade,
  owner_id      uuid        not null references users (id) on delete cascade,
  name          text        not null,
  ext           text        not null,
  content_type  text        not null,
  kind          text        not null,
  size_bytes    bigint      not null,
  bucket        text        not null default 'raw',
  object_key    text        not null,
  status        text        not null default 'pending',
  reject_reason text,
  created_at    timestamptz not null default now(),
  ready_at      timestamptz,
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  constraint files_status_check check (status in ('pending', 'ready', 'rejected')),
  constraint files_kind_check check (kind in ('image', 'document', 'video', 'audio', 'text')),
  constraint files_size_check check (size_bytes > 0)
);
create index if not exists files_owner_idx on files (owner_id, created_at desc) where deleted_at is null;
create unique index if not exists files_object_key on files (object_key);

alter table space_materials add column if not exists file_id uuid references files (id) on delete set null;
alter table space_materials add column if not exists added_by_name text;
alter table space_materials alter column url drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'space_materials_target_check') then
    alter table space_materials add constraint space_materials_target_check check (url is not null or file_id is not null) not valid;
  end if;
end $$;
__MAT_EOF__
echo "wrote server/src/db/migrations/029_files.sql"

mkdir -p server/src/files
cat > server/src/files/fileRules.js <<'__MAT_EOF__'
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
__MAT_EOF__
echo "wrote server/src/files/fileRules.js"

mkdir -p server/src/files
cat > server/src/files/FileStore.js <<'__MAT_EOF__'
// classroom-app/server/src/files/FileStore.js
/**
 * Object storage for Files  (Files)
 *
 * A thin layer over S3 (MinIO locally), using the platform's existing storage
 * configuration (config/storage.config.js): the same buckets, the same
 * credentials. Two buckets matter here:
 *
 *   raw       where the browser uploads to, with a short-lived signed PUT URL.
 *             Nothing is ever served from it.
 *   delivery  where a file moves once its bytes are checked (and scanned).
 *             Served only through FileService, never directly.
 *
 * Also the ClamAV client for ANTIVIRUS_MODE=clamav: the file is streamed to
 * clamd (INSTREAM), never written to disk on the API host.
 */

import net from 'node:net';
import { buckets, s3ClientOptions } from '../config/storage.config.js';

let client = null;
const s3 = async () => {
  if (!client) {
    const { S3Client } = await import('@aws-sdk/client-s3');
    client = new S3Client(s3ClientOptions);
  }
  return client;
};
const bucketName = (alias) => buckets?.[alias] ?? alias;

/** A signed URL the browser PUTs the file to, valid for `expiresIn` seconds. */
export const presignPut = async ({ key, contentType, expiresIn = 900 }) => {
  const { PutObjectCommand } = await import('@aws-sdk/client-s3');
  const { getSignedUrl } = await import('@aws-sdk/s3-request-presigner');
  return getSignedUrl(await s3(), new PutObjectCommand({ Bucket: bucketName('raw'), Key: key, ContentType: contentType }), { expiresIn });
};

/** Size of an object, or null when it is not there. */
export const head = async ({ bucket, key }) => {
  const { HeadObjectCommand } = await import('@aws-sdk/client-s3');
  try {
    const result = await (await s3()).send(new HeadObjectCommand({ Bucket: bucketName(bucket), Key: key }));
    return { size: Number(result.ContentLength ?? 0) };
  } catch (cause) {
    if (cause?.$metadata?.httpStatusCode === 404 || cause?.name === 'NotFound' || cause?.name === 'NoSuchKey') return null;
    throw cause;
  }
};

/** The first `bytes` bytes of an object, for checking what it really is. */
export const readStart = async ({ bucket, key, bytes }) => {
  const { GetObjectCommand } = await import('@aws-sdk/client-s3');
  const result = await (await s3()).send(new GetObjectCommand({ Bucket: bucketName(bucket), Key: key, Range: `bytes=0-${bytes - 1}` }));
  return new Uint8Array(await result.Body.transformToByteArray());
};

/** A readable stream of the object, or of a byte range of it. */
export const stream = async ({ bucket, key, range = null }) => {
  const { GetObjectCommand } = await import('@aws-sdk/client-s3');
  const result = await (await s3()).send(
    new GetObjectCommand({ Bucket: bucketName(bucket), Key: key, ...(range ? { Range: `bytes=${range.start}-${range.end}` } : {}) }),
  );
  return result.Body;
};

/** raw → delivery: copy first, delete after, so a failed copy loses nothing. */
export const promote = async ({ key }) => {
  const { CopyObjectCommand, DeleteObjectCommand } = await import('@aws-sdk/client-s3');
  const c = await s3();
  await c.send(new CopyObjectCommand({ Bucket: bucketName('delivery'), Key: key, CopySource: `${bucketName('raw')}/${key.split('/').map(encodeURIComponent).join('/')}` }));
  await c.send(new DeleteObjectCommand({ Bucket: bucketName('raw'), Key: key })).catch(() => undefined);
};

export const remove = async ({ bucket, key }) => {
  const { DeleteObjectCommand } = await import('@aws-sdk/client-s3');
  await (await s3()).send(new DeleteObjectCommand({ Bucket: bucketName(bucket), Key: key })).catch(() => undefined);
};

/**
 * Streams a file to clamd. Resolves { clean: true } or { clean: false, signature }.
 * Rejects when clamd cannot be reached or answers something unexpected.
 */
export const scanWithClamd = ({ body, host, port, timeoutMs = 60_000 }) =>
  new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port: Number(port) || 3310 });
    let answer = '';
    const fail = (error) => {
      socket.destroy();
      reject(error);
    };
    socket.setTimeout(timeoutMs, () => fail(new Error('clamd timed out')));
    socket.on('error', fail);
    socket.on('data', (chunk) => {
      answer += chunk.toString('utf8');
    });
    socket.on('end', () => {
      const text = answer.replace(/\0/g, '').trim();
      if (/:\s*OK$/.test(text)) resolve({ clean: true });
      else if (/FOUND$/.test(text)) resolve({ clean: false, signature: text.replace(/^stream:\s*/, '').replace(/\s*FOUND$/, '') });
      else reject(new Error(`clamd answered: ${text || 'nothing'}`));
    });
    socket.on('connect', async () => {
      try {
        socket.write('zINSTREAM\0');
        for await (const chunk of body) {
          const size = Buffer.alloc(4);
          size.writeUInt32BE(chunk.length, 0);
          socket.write(size);
          socket.write(chunk);
        }
        socket.write(Buffer.alloc(4));
      } catch (error) {
        fail(error);
      }
    });
  });

export default { presignPut, head, readStart, stream, promote, remove, scanWithClamd };
__MAT_EOF__
echo "wrote server/src/files/FileStore.js"

mkdir -p server/src/files
cat > server/src/files/FileService.js <<'__MAT_EOF__'
// classroom-app/server/src/files/FileService.js
/**
 * Files: everyone's own uploads  (Files and Media)
 *
 *   1. createUpload    checks name, format and size, reserves a row, returns a
 *                      signed PUT URL into the raw bucket (the bytes go from the
 *                      browser to storage, not through the API)
 *   2. completeUpload  checks that the upload arrived with the announced size,
 *                      that its first bytes really are the promised format,
 *                      scans it (ANTIVIRUS_MODE), and only then moves it to the
 *                      delivery bucket and marks it ready. Anything else is
 *                      deleted and the reason is told.
 *   3. openPath        a link valid for two hours: /files/:id/content?t=…
 *                      It opens in a new tab, where no Authorization header
 *                      goes, so the link itself carries the permission.
 *
 * Who may open a file: its owner, and everyone who can see a space where it
 * is a material. Limits: FILES_MAX_MB (default 50) per file, FILES_QUOTA_MB
 * (default 2048) per person.
 */

import { randomUUID } from 'node:crypto';
import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Rules from './fileRules.js';
import * as Store from './FileStore.js';

const log = logger.child({ component: 'files' });

const fail = (code, message) => {
  throw Object.assign(new Error(message), { code });
};
const iso = (value) => (value ? new Date(value).toISOString() : null);

export const limits = () => ({
  maxFileBytes: Number(process.env.FILES_MAX_MB || 50) * 1024 * 1024,
  quotaBytes: Number(process.env.FILES_QUOTA_MB || 2048) * 1024 * 1024,
});

const secret = () => {
  const value = process.env.FILES_LINK_SECRET || process.env.COOKIE_SECRET;
  if (!value) fail('internal', 'No secret for file links (set FILES_LINK_SECRET or COOKIE_SECRET).');
  return value;
};

const LINK_TTL_MS = 2 * 60 * 60 * 1000;

/** A path relative to the API, valid for two hours. */
export const openPath = (fileId) =>
  `/files/${fileId}/content?t=${Rules.linkToken({ fileId, expiresAt: Date.now() + LINK_TTL_MS, secret: secret() })}`;

export const toView = (row, { withLink = true } = {}) => ({
  fileId: row.id,
  name: row.name,
  ext: row.ext,
  kind: row.kind,
  contentType: row.content_type,
  sizeBytes: Number(row.size_bytes),
  status: row.status,
  rejectReason: row.reject_reason ?? null,
  inline: Boolean(Rules.FORMATS[row.ext]?.inline),
  createdAt: iso(row.created_at),
  usedIn: row.used_in !== undefined ? Number(row.used_in) : undefined,
  openUrl: withLink && row.status === 'ready' && !row.deleted_at ? openPath(row.id) : null,
});

const usageOf = async (ownerId) => {
  const { rows } = await pool.query(
    `SELECT coalesce(sum(size_bytes), 0)::bigint AS used FROM files
      WHERE owner_id = $1 AND deleted_at IS NULL
        AND (status = 'ready' OR (status = 'pending' AND created_at > now() - interval '1 day'))`,
    [ownerId],
  );
  return Number(rows[0].used);
};

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

export const createUpload = async ({ viewer, name, sizeBytes }) => {
  const { maxFileBytes, quotaBytes } = limits();
  const problem = Rules.uploadProblem({ name, sizeBytes, maxBytes: maxFileBytes });
  if (problem) fail('validation_failed', problem);
  const clean = Rules.safeName(name);
  const ext = Rules.extensionOf(clean);
  const format = Rules.FORMATS[ext];
  if ((await usageOf(viewer.userId)) + sizeBytes > quotaBytes) {
    fail('forbidden', `Your upload storage is full (${Math.round(quotaBytes / 1024 / 1024)} MB).`);
  }
  const id = randomUUID();
  const key = `files/${viewer.tenantId}/${viewer.userId}/${id}.${ext}`;
  await pool.query(
    `INSERT INTO files (id, tenant_id, owner_id, name, ext, content_type, kind, size_bytes, bucket, object_key)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'raw', $9)`,
    [id, viewer.tenantId, viewer.userId, clean, ext, format.type, format.kind, sizeBytes, key],
  );
  const uploadUrl = await Store.presignPut({ key, contentType: format.type });
  return { fileId: id, uploadUrl, uploadHeaders: { 'Content-Type': format.type }, expiresInSec: 900 };
};

const reject = async (row, reason) => {
  await pool.query(`UPDATE files SET status = 'rejected', reject_reason = $2, updated_at = now() WHERE id = $1`, [row.id, reason]);
  await Store.remove({ bucket: row.bucket, key: row.object_key });
  log.info({ fileId: row.id, reason }, 'upload rejected');
  fail('validation_failed', reason);
};

const scan = async (row) => {
  const mode = String(process.env.ANTIVIRUS_MODE || 'disabled').toLowerCase();
  if (mode === 'disabled') {
    if (process.env.NODE_ENV === 'production') return { ok: false, reason: 'Uploads are paused: virus scanning is switched off.' };
    return { ok: true };
  }
  const host = process.env.CLAMAV_HOST;
  if (!host) {
    log.error({ mode }, 'ANTIVIRUS_MODE needs CLAMAV_HOST for Files uploads');
    return { ok: false, reason: 'The virus scan is not set up for uploads yet. Ask an administrator.' };
  }
  try {
    const body = await Store.stream({ bucket: row.bucket, key: row.object_key });
    const result = await Store.scanWithClamd({ body, host, port: process.env.CLAMAV_PORT });
    return result.clean ? { ok: true } : { ok: false, reason: 'The virus scanner flagged this file, so it was not kept.', signature: result.signature };
  } catch (cause) {
    log.warn({ err: cause, fileId: row.id }, 'virus scan unavailable');
    return { ok: false, reason: 'The virus scan is not available right now. Try again in a few minutes.' };
  }
};

export const completeUpload = async ({ viewer, fileId }) => {
  const { rows } = await pool.query(
    `SELECT * FROM files WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL`,
    [fileId, viewer.userId],
  );
  const row = rows[0];
  if (!row) fail('not_found', 'No such upload');
  if (row.status === 'ready') return toView(row);
  if (row.status !== 'pending') fail('validation_failed', row.reject_reason ?? 'This upload was not accepted.');

  const found = await Store.head({ bucket: row.bucket, key: row.object_key });
  if (!found) fail('validation_failed', 'The file did not arrive. Try the upload again.');
  if (found.size !== Number(row.size_bytes)) await reject(row, 'The file arrived incomplete. Try the upload again.');

  const start = await Store.readStart({ bucket: row.bucket, key: row.object_key, bytes: Rules.SNIFF_BYTES });
  if (!Rules.bytesMatch(Rules.FORMATS[row.ext].magic, start)) {
    await reject(row, `This file is not really a ${row.ext.toUpperCase()} file, so it was not kept.`);
  }

  const scanned = await scan(row);
  if (!scanned.ok) {
    if (scanned.signature) log.warn({ fileId: row.id, signature: scanned.signature }, 'infected upload removed');
    await reject(row, scanned.reason);
  }

  await Store.promote({ key: row.object_key });
  const { rows: done } = await pool.query(
    `UPDATE files SET status = 'ready', bucket = 'delivery', ready_at = now(), updated_at = now() WHERE id = $1 RETURNING *`,
    [row.id],
  );
  log.info({ fileId: row.id, ext: row.ext, size: Number(row.size_bytes) }, 'file ready');
  return toView(done[0]);
};

// ---------------------------------------------------------------------------
// The library
// ---------------------------------------------------------------------------

export const list = async ({ viewer, q = null, kind = null }) => {
  const params = [viewer.userId];
  const filters = [];
  if (q) {
    params.push(q);
    filters.push(`f.name ILIKE '%' || $${params.length} || '%'`);
  }
  if (kind) {
    params.push(kind);
    filters.push(`f.kind = $${params.length}`);
  }
  const { rows } = await pool.query(
    `SELECT f.*, (SELECT count(*) FROM space_materials m WHERE m.file_id = f.id AND m.deleted_at IS NULL) AS used_in
       FROM files f
      WHERE f.owner_id = $1 AND f.deleted_at IS NULL AND f.status = 'ready' ${filters.length ? `AND ${filters.join(' AND ')}` : ''}
      ORDER BY f.created_at DESC LIMIT 500`,
    params,
  );
  const { maxFileBytes, quotaBytes } = limits();
  return {
    items: rows.map((row) => toView(row)),
    usage: { usedBytes: await usageOf(viewer.userId), quotaBytes, maxFileBytes },
    accept: Rules.EXTENSIONS.filter((ext) => ext !== 'jpeg'),
  };
};

const ownFile = async (viewer, fileId) => {
  const { rows } = await pool.query(`SELECT * FROM files WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL`, [fileId, viewer.userId]);
  if (!rows[0]) fail('not_found', 'No such file');
  return rows[0];
};

export const rename = async ({ viewer, fileId, name }) => {
  const row = await ownFile(viewer, fileId);
  const wanted = String(name ?? '').trim();
  const withExt = Rules.extensionOf(wanted) === row.ext ? wanted : `${wanted}.${row.ext}`;
  const clean = Rules.safeName(withExt);
  if (!clean || clean === `.${row.ext}`) fail('validation_failed', 'Give the file a name.');
  const { rows } = await pool.query(`UPDATE files SET name = $2, updated_at = now() WHERE id = $1 RETURNING *`, [row.id, clean]);
  return toView(rows[0]);
};

/** Deleting a file also removes it from every space it was a material in. */
export const remove = async ({ viewer, fileId }) => {
  const row = await ownFile(viewer, fileId);
  await pool.query(`UPDATE files SET deleted_at = now(), updated_at = now() WHERE id = $1`, [row.id]);
  await pool.query(`UPDATE space_materials SET deleted_at = now() WHERE file_id = $1 AND deleted_at IS NULL`, [row.id]).catch(() => undefined);
  await Store.remove({ bucket: row.bucket, key: row.object_key });
  return { removed: true };
};

/** The owner, or anyone who can see a space where the file is a material. */
export const canView = async ({ viewer, fileId }) => {
  const { rows } = await pool.query(
    `SELECT 1 FROM files f WHERE f.id = $1 AND f.deleted_at IS NULL AND f.status = 'ready' AND f.tenant_id = $3
        AND (f.owner_id = $2 OR EXISTS (
              SELECT 1 FROM space_materials m
                JOIN spaces s ON s.id = m.space_id AND s.tenant_id = $3
                LEFT JOIN space_memberships sm ON sm.space_id = s.id AND sm.user_id = $2
               WHERE m.file_id = f.id AND m.deleted_at IS NULL AND (sm.user_id IS NOT NULL OR s.access = 'open')))`,
    [fileId, viewer.userId, viewer.tenantId],
  );
  return rows.length > 0;
};

export const linkFor = async ({ viewer, fileId }) => {
  if (!(await canView({ viewer, fileId }))) fail('not_found', 'No such file');
  return { url: openPath(fileId) };
};

/** For a signed link: the file's headers and a stream (or a range of it). */
export const open = async ({ fileId, token, rangeHeader }) => {
  if (!Rules.verifyLinkToken({ fileId, token, secret: secret() })) fail('forbidden', 'This link has expired. Open the file again from where you found it.');
  const { rows } = await pool.query(`SELECT * FROM files WHERE id = $1 AND status = 'ready' AND deleted_at IS NULL`, [fileId]);
  const row = rows[0];
  if (!row) fail('not_found', 'This file is no longer available.');
  const size = Number(row.size_bytes);
  const range = rangeHeader ? Rules.parseRange(rangeHeader, size) : null;
  if (rangeHeader && !range) return { status: 416, headers: { 'Content-Range': `bytes */${size}` }, body: null };
  const headers = Rules.deliveryHeaders({ ext: row.ext, name: row.name, sizeBytes: range ? range.end - range.start + 1 : size });
  if (range) headers['Content-Range'] = `bytes ${range.start}-${range.end}/${size}`;
  const body = await Store.stream({ bucket: row.bucket, key: row.object_key, range });
  return { status: range ? 206 : 200, headers, body };
};

export default { limits, openPath, toView, createUpload, completeUpload, list, rename, remove, canView, linkFor, open };
__MAT_EOF__
echo "wrote server/src/files/FileService.js"

mkdir -p server/src/routes
cat > server/src/routes/files.routes.js <<'__MAT_EOF__'
/**
 * files.routes — uploads and the Media library  (Files and Media)
 *
 * Mounted under /files (app.js). Storage and rules: files/FileService.js.
 *
 *   POST   /uploads            { name, sizeBytes } → a signed PUT URL into storage
 *   POST   /:id/complete       after the PUT: checked, scanned, ready (or refused with the reason)
 *   GET    /?q=&kind=          my library, with usage and the accepted formats
 *   PATCH  /:id  { name }      rename
 *   DELETE /:id                delete (also from every space it was a material in)
 *   GET    /:id/link           a fresh link to open the file (owner, or the spaces it is in)
 *   GET    /:id/content?t=…    the file itself — no sign-in header needed, the
 *                              link's signature is the permission (new tabs send none)
 *
 * The older /media routes are left as they are.
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Files from '../files/FileService.js';
import { viewerOf } from '../hub/HubService.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, notFound, badRequest, forbidden } from './_helpers.js';

const router = Router();

const asHttp = (error) => {
  switch (error?.code) {
    case 'validation_failed':
      return badRequest(error.message);
    case 'forbidden':
      return forbidden(error.message);
    case 'not_found':
      return notFound(error.message);
    default:
      return error;
  }
};

const handle = (fn) =>
  route(async (req, res) => {
    try {
      return await fn(req, res, await viewerOf(req.user.id));
    } catch (error) {
      throw asHttp(error);
    }
  });

const idParam = z.object({ id: z.string().uuid() });

router.post(
  '/uploads',
  requireAuth,
  rateLimit({ key: 'files:upload', points: 60, durationSec: 600, by: ['user'] }),
  validate({ body: z.object({ name: z.string().trim().min(1).max(255), sizeBytes: z.number().int().min(1) }) }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Files.createUpload({ viewer, name: req.body.name, sizeBytes: req.body.sizeBytes });
  }),
);

router.post('/:id/complete', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.completeUpload({ viewer, fileId: req.params.id })));

router.get(
  '/',
  requireAuth,
  validate({ query: z.object({ q: z.string().trim().max(80).optional(), kind: z.enum(['image', 'document', 'video', 'audio', 'text']).optional() }).passthrough() }),
  handle((req, res, viewer) => Files.list({ viewer, q: req.query.q || null, kind: req.query.kind ?? null })),
);

router.patch(
  '/:id',
  requireAuth,
  validate({ params: idParam, body: z.object({ name: z.string().trim().min(1).max(200) }) }),
  handle((req, res, viewer) => Files.rename({ viewer, fileId: req.params.id, name: req.body.name })),
);

router.delete('/:id', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.remove({ viewer, fileId: req.params.id })));

router.get('/:id/link', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.linkFor({ viewer, fileId: req.params.id })));

/** Streams the file. Not wrapped in route(): the answer is bytes, not JSON. */
router.get('/:id/content', validate({ params: idParam }), async (req, res, next) => {
  try {
    const opened = await Files.open({ fileId: req.params.id, token: req.query.t, rangeHeader: req.get('range') });
    // The global security headers are for the app's pages; a file gets its own (fileRules.deliveryHeaders).
    res.removeHeader('Content-Security-Policy');
    res.removeHeader('Cross-Origin-Embedder-Policy');
    res.status(opened.status).set(opened.headers);
    if (!opened.body) return res.end();
    opened.body.on('error', (error) => res.destroy(error));
    req.on('close', () => opened.body.destroy?.());
    return opened.body.pipe(res);
  } catch (error) {
    if (error?.code === 'forbidden' || error?.code === 'not_found') {
      res.status(error.code === 'forbidden' ? 403 : 404).type('text/plain; charset=utf-8').send(error.message);
      return undefined;
    }
    return next(error);
  }
});

export default router;
__MAT_EOF__
echo "wrote server/src/routes/files.routes.js"

mkdir -p server/src/hub
cat > server/src/hub/hubRules.js <<'__MAT_EOF__'
// classroom-app/server/src/hub/hubRules.js
/**
 * Community rules  (Community, part 1)
 *
 * The one place that decides what a person may see and do in a space. Pure:
 * no database, no clock of its own — the service and the tests call the same
 * functions, so the page and the server can never disagree.
 *
 *   kinds    class (a course or class) · topic (an interest) · study (small, ends)
 *   access   open     anyone in the organisation can read and join
 *            request  anyone can see the space exists; a moderator admits
 *            invite   invisible to everyone who is not a member
 *   roles    owner · moderator · member
 *
 * Part 2 adds knowledge cards (a good answer, saved), hidden solutions
 * (replies that show only when opened), a chat per space, materials (links),
 * and drop-in rooms that the space's members may enter.
 *
 * Privacy, unlike a messenger group: members never see each other's email or
 * phone. Names and roles only — and a space can hide its member list from
 * everyone but moderators. A question can be asked anonymously: other members
 * see "Anonymous"; moderators see who it was, so anonymity cannot be used to
 * harass.
 */

import { z } from 'zod';

export const KINDS = ['class', 'topic', 'study'];
export const ACCESS = ['open', 'request', 'invite'];
export const ROLES = ['owner', 'moderator', 'member'];
export const TEACHING_ROLES = new Set(['teacher', 'owner', 'admin']);
export const MAX_STUDY_GROUP = 12;

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

const emoji = z
  .string()
  .max(16)
  .refine((value) => [...value].length <= 4, 'one emoji');

export const CreateSpaceSchema = z
  .object({
    name: z.string().trim().min(2).max(80),
    description: z.string().trim().max(500).nullish(),
    kind: z.enum(KINDS).default('topic'),
    access: z.enum(ACCESS).default('open'),
    memberList: z.enum(['members', 'moderators']).default('members'),
    joinQuestion: z.string().trim().max(200).nullish(),
    endsAt: z.string().datetime({ offset: true }).nullish(),
    emoji: emoji.nullish(),
    tags: z.array(z.string().trim().toLowerCase().min(1).max(24)).max(5).default([]),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.kind === 'study' && !value.endsAt) {
      ctx.addIssue({ code: 'custom', path: ['endsAt'], message: 'A study group needs an end date, for example the exam.' });
    }
    if (value.kind !== 'study' && value.endsAt) {
      ctx.addIssue({ code: 'custom', path: ['endsAt'], message: 'Only study groups end.' });
    }
  });

export const UpdateSpaceSchema = z
  .object({
    name: z.string().trim().min(2).max(80),
    description: z.string().trim().max(500).nullable(),
    access: z.enum(ACCESS),
    memberList: z.enum(['members', 'moderators']),
    joinQuestion: z.string().trim().max(200).nullable(),
    endsAt: z.string().datetime({ offset: true }).nullable(),
    emoji: emoji.nullable(),
    tags: z.array(z.string().trim().toLowerCase().min(1).max(24)).max(5),
  })
  .partial()
  .strict();

export const CreateThreadSchema = z
  .object({
    title: z.string().trim().min(3).max(160),
    body: z.string().trim().min(1).max(10000),
    kind: z.enum(['discussion', 'question']).default('discussion'),
    anonymous: z.boolean().default(false),
  })
  .strict()
  .refine((value) => !value.anonymous || value.kind === 'question', {
    message: 'Only questions can be asked anonymously.',
    path: ['anonymous'],
  });

export const ReplySchema = z
  .object({
    body: z.string().trim().min(1).max(10000),
    replyToId: z.string().uuid().nullish(),
    hiddenSolution: z.boolean().default(false),
  })
  .strict();

export const CardSchema = z
  .object({
    title: z.string().trim().min(3).max(160),
    body: z.string().trim().min(1).max(10000),
    postId: z.string().uuid().nullish(),
  })
  .strict();

export const UpdateCardSchema = z
  .object({ title: z.string().trim().min(3).max(160), body: z.string().trim().min(1).max(10000) })
  .partial()
  .strict();

/** Only http(s) links: no javascript:, data: or file: addresses end up clickable. */
export const safeUrl = (value) => {
  try {
    const url = new URL(String(value ?? '').trim());
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.toString() : null;
  } catch {
    return null;
  }
};

/**
 * A material is a link to any website, or a file from the person's Media
 * library (Files) — exactly one of the two. A file's title defaults to its name.
 */
export const MaterialSchema = z
  .object({
    title: z.string().trim().max(120).nullish(),
    url: z.string().trim().max(2000).refine((value) => safeUrl(value) !== null, 'a web address starting with https://').nullish(),
    fileId: z.string().uuid().nullish(),
    note: z.string().trim().max(300).nullish(),
    pinned: z.boolean().default(false),
  })
  .strict()
  .refine((value) => Boolean(value.url) !== Boolean(value.fileId), { message: 'Either a link or a file.', path: ['url'] })
  .refine((value) => Boolean(value.fileId) || Boolean(value.title), { message: 'Give the link a title.', path: ['title'] });

/** Every member adds materials; whoever added one, or a moderator, removes it. */
export const canRemoveMaterial = ({ addedBy, viewerId, membership }) => addedBy === viewerId || isModerator(membership);

export const ChatMessageSchema = z.object({ body: z.string().trim().min(1).max(2000) }).strict();

/** How long a drop-in room stays open, and how many can start at once in one space. */
export const DROP_IN_MINUTES = 60;

/** Members start drop-in rooms; cards and materials are curated by moderators. */
export const canCurate = (membership) => isModerator(membership);

/** Who may remove a chat message: its author, or a moderator. */
export const canRemoveMessage = ({ authorId, viewerId, membership }) => authorId === viewerId || isModerator(membership);

/** A hidden solution is shown folded to everyone but its author. */
export const solutionFolded = ({ hiddenSolution, authorId, viewerId }) => Boolean(hiddenSolution) && authorId !== viewerId;

export const ReportSchema = z
  .object({
    targetType: z.enum(['thread', 'post', 'user']),
    targetId: z.string().uuid(),
    reason: z.enum(['spam', 'harassment', 'hate', 'inappropriate', 'off-topic', 'other']),
    note: z.string().trim().max(500).nullish(),
  })
  .strict();

// ---------------------------------------------------------------------------
// Decisions
// ---------------------------------------------------------------------------

export const isModerator = (membership) => membership?.role === 'owner' || membership?.role === 'moderator';

/** A study group whose end date has passed is read-only. */
export const hasEnded = (space, now = Date.now()) =>
  Boolean(space.archivedAt) || (space.endsAt ? new Date(space.endsAt).getTime() <= now : false);

/**
 * What someone sees of a space.
 *   'full'    everything (members; everyone in the organisation for open spaces)
 *   'preview' name, description and numbers, to decide whether to ask to join
 *   'hidden'  nothing: the space does not exist for them
 */
export const viewOf = (space, membership) => {
  if (membership) return 'full';
  if (space.access === 'open') return 'full';
  if (space.access === 'request') return 'preview';
  return 'hidden';
};

/** May this person write in the space right now? Returns a reason when not. */
export const postingBlockedBecause = (space, membership, now = Date.now()) => {
  if (!membership) return 'Join the space to write in it.';
  if (hasEnded(space, now)) return 'This space has ended and is read-only.';
  if (membership.timeoutUntil && new Date(membership.timeoutUntil).getTime() > now) {
    return 'A moderator paused your posting here for a while.';
  }
  return null;
};

export const canCreateKind = (kind, userRole) => kind !== 'class' || TEACHING_ROLES.has(userRole);

/** Members see each other unless the space shows its list to moderators only. */
export const memberListVisible = (space, membership) =>
  isModerator(membership) || ((Boolean(membership) || space.access === 'open') && space.memberList !== 'moderators');

/**
 * How an author is shown to a viewer. An anonymous question's author (and
 * that person's replies in the same thread) is "Anonymous" to everyone except
 * the author and the space's moderators.
 */
export const authorView = ({ authorId, displayName, anonymous, viewerId, viewerIsModerator }) => {
  const you = authorId === viewerId;
  if (!anonymous) return { userId: authorId, displayName, anonymous: false, you };
  if (you) return { userId: authorId, displayName, anonymous: true, you, hiddenFromOthers: true };
  if (viewerIsModerator) return { userId: authorId, displayName, anonymous: true, you: false, revealedToModerator: true };
  return { userId: null, displayName: 'Anonymous', anonymous: true, you: false };
};

/** Who may mark an answer: the person who asked, or a moderator. */
export const canMarkAnswer = ({ thread, viewerId, membership }) =>
  thread.kind === 'question' && (thread.authorId === viewerId || isModerator(membership));

/** Who may delete a post or thread: its author, or a moderator. */
export const canRemove = ({ authorId, viewerId, membership }) => authorId === viewerId || isModerator(membership);

/** Study groups stay small, so they stay a group. */
export const roomForMember = (space, memberCount) => space.kind !== 'study' || memberCount < MAX_STUDY_GROUP;

/** A short excerpt for lists, without markdown noise. */
export const excerpt = (text, length = 180) => {
  const clean = String(text ?? '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/[#>*_`~\[\]()]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return clean.length > length ? `${clean.slice(0, length - 1).trimEnd()}…` : clean;
};

export default {
  KINDS, ACCESS, ROLES, CreateSpaceSchema, UpdateSpaceSchema, CreateThreadSchema, ReplySchema, ReportSchema,
  CardSchema, UpdateCardSchema, MaterialSchema, ChatMessageSchema, safeUrl, canCurate, canRemoveMessage, solutionFolded, canRemoveMaterial,
  isModerator, hasEnded, viewOf, postingBlockedBecause, canCreateKind, memberListVisible, authorView,
  canMarkAnswer, canRemove, roomForMember, excerpt,
};
__MAT_EOF__
echo "wrote server/src/hub/hubRules.js"

mkdir -p server/src/hub
cat > server/src/hub/HubExtras.js <<'__MAT_EOF__'
// classroom-app/server/src/hub/HubExtras.js
/**
 * Community, part 2  (Community)
 *
 *   knowledge cards   moderators save a good answer as a card; everyone in the
 *                     space can search the cards later
 *   materials         links to any website and files from members' Media
 *                     libraries, pinned ones first; files open in a new tab
 *   chat              quick messages in a space, next to the threads
 *   rooms             drop-in rooms that belong to the space: any member can
 *                     start one; they use the rooms feature (doors, seats,
 *                     lobby, closing on time) and the space's members may enter
 *   live now          which rooms in your spaces are open, and how many are in
 *
 * Same rules as part 1 (hub/hubRules.js): what a space shows to whom,
 * blocks in both directions, posting pauses, ended study groups.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Rules from './hubRules.js';
import { internals } from './HubService.js';
import * as Part3 from './partRules.js';

const log = logger.child({ component: 'community-extras' });
const { loadSpace, notify, notBlocked, iso, fail, logAction } = internals;

const requireFullView = async (viewer, spaceId) => {
  const loaded = await loadSpace(viewer, spaceId);
  if (Rules.viewOf(loaded.space, loaded.membership) !== 'full') fail('forbidden', 'Join the space to see this.');
  return loaded;
};

// ---------------------------------------------------------------------------
// Knowledge cards
// ---------------------------------------------------------------------------

const toCard = (row) => ({
  cardId: row.id,
  spaceId: row.space_id,
  threadId: row.thread_id ?? null,
  postId: row.post_id ?? null,
  title: row.title,
  body: row.body,
  createdBy: row.author_name ?? null,
  createdAt: iso(row.created_at),
  updatedAt: iso(row.updated_at),
});

export const listCards = async ({ viewer, spaceId, q = null }) => {
  const { membership } = await requireFullView(viewer, spaceId);
  const params = [spaceId];
  let search = '';
  if (q) {
    params.push(q);
    search = `AND (c.title ILIKE '%' || $2 || '%' OR c.body ILIKE '%' || $2 || '%')`;
  }
  const { rows } = await pool.query(
    `SELECT c.*, u.display_name AS author_name FROM space_cards c LEFT JOIN users u ON u.id = c.created_by
      WHERE c.space_id = $1 AND c.deleted_at IS NULL ${search}
      ORDER BY c.updated_at DESC LIMIT 200`,
    params,
  );
  return { items: rows.map(toCard), canCurate: Rules.canCurate(membership) };
};

export const createCard = async ({ viewer, spaceId, input }) => {
  const { membership } = await requireFullView(viewer, spaceId);
  if (!Rules.canCurate(membership)) fail('forbidden', 'Only moderators save knowledge cards.');
  let threadId = null;
  if (input.postId) {
    const { rows } = await pool.query(
      `SELECT p.thread_id FROM posts p JOIN threads t ON t.id = p.thread_id WHERE p.id = $1 AND t.space_id = $2 AND p.deleted_at IS NULL`,
      [input.postId, spaceId],
    );
    if (!rows[0]) fail('not_found', 'That reply is not in this space.');
    threadId = rows[0].thread_id;
  }
  const { rows } = await pool.query(
    `INSERT INTO space_cards (space_id, thread_id, post_id, title, body, created_by)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [spaceId, threadId, input.postId ?? null, input.title, input.body, viewer.userId],
  );
  log.info({ spaceId, cardId: rows[0].id }, 'knowledge card saved');
  return toCard({ ...rows[0], author_name: viewer.displayName });
};

const loadCard = async (viewer, cardId) => {
  const { rows } = await pool.query(`SELECT * FROM space_cards WHERE id = $1 AND deleted_at IS NULL`, [cardId]);
  if (!rows[0]) fail('not_found', 'No such card');
  const { membership } = await requireFullView(viewer, rows[0].space_id);
  if (!Rules.canCurate(membership)) fail('forbidden', 'Only moderators change knowledge cards.');
  return rows[0];
};

export const updateCard = async ({ viewer, cardId, patch }) => {
  const card = await loadCard(viewer, cardId);
  const { rows } = await pool.query(
    `UPDATE space_cards SET title = coalesce($2, title), body = coalesce($3, body), updated_at = now() WHERE id = $1 RETURNING *`,
    [card.id, patch.title ?? null, patch.body ?? null],
  );
  return toCard(rows[0]);
};

export const removeCard = async ({ viewer, cardId }) => {
  const card = await loadCard(viewer, cardId);
  await pool.query(`UPDATE space_cards SET deleted_at = now() WHERE id = $1`, [card.id]);
  await logAction(card.space_id, viewer.userId, 'card.remove', { detail: { title: card.title } });
  return { removed: true };
};

// ---------------------------------------------------------------------------
// Materials
// ---------------------------------------------------------------------------

const toMaterial = (row, { viewer = null, membership = null, openPath = null } = {}) => {
  let host = null;
  if (row.url) {
    try {
      host = new URL(row.url).hostname.replace(/^www\./, '');
    } catch {
      host = null;
    }
  }
  const isFile = Boolean(row.file_id);
  const fileReady = isFile && row.file_status === 'ready' && !row.file_deleted_at;
  return {
    materialId: row.id,
    type: isFile ? 'file' : 'link',
    title: row.title || row.file_name || 'File',
    url: row.url ?? null,
    host,
    file: isFile
      ? {
          fileId: row.file_id,
          name: row.file_name ?? null,
          ext: row.file_ext ?? null,
          kind: row.file_kind ?? null,
          sizeBytes: row.file_size !== undefined && row.file_size !== null ? Number(row.file_size) : null,
          available: fileReady,
          openUrl: fileReady && openPath ? openPath(row.file_id) : null,
        }
      : null,
    note: row.note ?? null,
    pinned: Boolean(row.pinned),
    addedBy: row.author_name ?? row.added_by_name ?? null,
    createdAt: iso(row.created_at),
    canRemove: viewer ? Rules.canRemoveMaterial({ addedBy: row.added_by, viewerId: viewer.userId, membership }) : false,
  };
};

const MATERIAL_SELECT = `
  SELECT m.*, u.display_name AS author_name,
         f.name AS file_name, f.ext AS file_ext, f.kind AS file_kind, f.size_bytes AS file_size,
         f.status AS file_status, f.deleted_at AS file_deleted_at
    FROM space_materials m
    LEFT JOIN users u ON u.id = m.added_by
    LEFT JOIN files f ON f.id = m.file_id`;

const filesModule = () => import('../files/FileService.js');

export const listMaterials = async ({ viewer, spaceId }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const { rows } = await pool.query(
    `${MATERIAL_SELECT} WHERE m.space_id = $1 AND m.deleted_at IS NULL ORDER BY m.pinned DESC, m.created_at DESC LIMIT 200`,
    [spaceId],
  );
  const { openPath } = await filesModule();
  return {
    items: rows.map((row) => toMaterial(row, { viewer, membership, openPath })),
    canCurate: Rules.canCurate(membership),
    canAdd: Boolean(membership) && !Rules.postingBlockedBecause(space, membership),
  };
};

/** Any member adds a link to any website, or a file from their own Media library. */
export const addMaterial = async ({ viewer, spaceId, input }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const blocked = Rules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);
  let url = null;
  let title = input.title ?? null;
  let fileId = null;
  if (input.fileId) {
    const { rows } = await pool.query(
      `SELECT id, name FROM files WHERE id = $1 AND owner_id = $2 AND status = 'ready' AND deleted_at IS NULL`,
      [input.fileId, viewer.userId],
    );
    if (!rows[0]) fail('not_found', 'That file is not among your uploads.');
    fileId = rows[0].id;
    title = title || rows[0].name;
  } else {
    url = Rules.safeUrl(input.url);
    if (!url) fail('validation_failed', 'A web address starting with https:// is needed.');
  }
  const pinned = Boolean(input.pinned) && Rules.isModerator(membership);
  const { rows } = await pool.query(
    `INSERT INTO space_materials (space_id, title, url, file_id, note, pinned, added_by, added_by_name)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
    [spaceId, title, url, fileId, input.note ?? null, pinned, viewer.userId, viewer.displayName],
  );
  const { rows: full } = await pool.query(`${MATERIAL_SELECT} WHERE m.id = $1`, [rows[0].id]);
  const { openPath } = await filesModule();
  return toMaterial(full[0], { viewer, membership, openPath });
};

const loadMaterial = async (viewer, materialId) => {
  const { rows } = await pool.query(`SELECT * FROM space_materials WHERE id = $1 AND deleted_at IS NULL`, [materialId]);
  if (!rows[0]) fail('not_found', 'No such material');
  const { membership } = await requireFullView(viewer, rows[0].space_id);
  return { material: rows[0], membership };
};

export const pinMaterial = async ({ viewer, materialId, pinned }) => {
  const { material, membership } = await loadMaterial(viewer, materialId);
  if (!Rules.canCurate(membership)) fail('forbidden', 'Only moderators pin materials.');
  await pool.query(`UPDATE space_materials SET pinned = $2 WHERE id = $1`, [material.id, Boolean(pinned)]);
  const { rows } = await pool.query(`${MATERIAL_SELECT} WHERE m.id = $1`, [material.id]);
  const { openPath } = await filesModule();
  return toMaterial(rows[0], { viewer, membership, openPath });
};

export const removeMaterial = async ({ viewer, materialId }) => {
  const { material, membership } = await loadMaterial(viewer, materialId);
  if (!Rules.canRemoveMaterial({ addedBy: material.added_by, viewerId: viewer.userId, membership })) {
    fail('forbidden', 'Only the person who added it, or a moderator, removes a material.');
  }
  await pool.query(`UPDATE space_materials SET deleted_at = now() WHERE id = $1`, [material.id]);
  if (material.added_by !== viewer.userId) {
    await logAction(material.space_id, viewer.userId, 'material.remove', { detail: { title: material.title } });
  }
  return { removed: true };
};

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

const toMessage = (row, viewer, membership) => ({
  messageId: row.id,
  body: row.body,
  author: { userId: row.author_id, displayName: row.display_name, you: row.author_id === viewer.userId },
  createdAt: iso(row.created_at),
  // Microseconds, as stored: a millisecond timestamp would fetch the last message twice.
  cursor: row.cursor,
  canRemove: Rules.canRemoveMessage({ authorId: row.author_id, viewerId: viewer.userId, membership }),
});

const CURSOR = `to_char(m.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

/** The newest 80 messages, or those after a cursor (for catching up). Oldest first. */
export const listMessages = async ({ viewer, spaceId, after = null }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const params = [spaceId, viewer.userId];
  let since = '';
  if (after) {
    params.push(after);
    since = `AND m.created_at > $3::timestamptz`;
  }
  const { rows } = await pool.query(
    `SELECT * FROM (
       SELECT m.id, m.author_id, m.body, m.created_at, ${CURSOR} AS cursor, u.display_name
         FROM space_messages m JOIN users u ON u.id = m.author_id
        WHERE m.space_id = $1 AND m.deleted_at IS NULL ${since} AND ${notBlocked('m.author_id', '$2')}
        ORDER BY m.created_at DESC LIMIT 80) latest
      ORDER BY created_at ASC`,
    params,
  );
  const items = rows.map((row) => toMessage(row, viewer, membership));
  return {
    items,
    nextCursor: items.length ? items[items.length - 1].cursor : after,
    calmSeconds: space.chatSlowSeconds ?? 0,
    canModerate: Rules.isModerator(membership),
    postingBlocked: Rules.postingBlockedBecause(space, membership),
    serverTime: new Date().toISOString(),
  };
};

/** Members who are told a message arrived, so their open chat fetches it at once. */
const LIVE_FANOUT_LIMIT = 150;

export const sendMessage = async ({ viewer, spaceId, input }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const blocked = Rules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);
  if (space.chatSlowSeconds > 0 && !Rules.isModerator(membership)) {
    const { rows: last } = await pool.query(
      `SELECT max(created_at) AS at FROM space_messages WHERE space_id = $1 AND author_id = $2 AND deleted_at IS NULL`,
      [spaceId, viewer.userId],
    );
    const wait = Part3.calmWait({ slowSeconds: space.chatSlowSeconds, lastPostAt: last[0]?.at });
    if (wait > 0) fail('forbidden', Part3.calmMessage(wait));
  }
  const { rows } = await pool.query(
    `INSERT INTO space_messages AS m (space_id, author_id, body) VALUES ($1, $2, $3)
     RETURNING m.id, m.author_id, m.body, m.created_at, ${CURSOR} AS cursor`,
    [spaceId, viewer.userId, input.body],
  );
  try {
    const { rows: members } = await pool.query(
      `SELECT user_id FROM space_memberships WHERE space_id = $1 AND user_id <> $2 LIMIT ${LIVE_FANOUT_LIMIT}`,
      [spaceId, viewer.userId],
    );
    const { pushToUser } = await import('../realtime/userEvents.js');
    await Promise.all(members.map((member) => pushToUser(member.user_id, 'hub:chat', { spaceId })));
  } catch (cause) {
    log.debug({ err: cause }, 'chat live signal not sent; members catch up on their next fetch');
  }
  return toMessage({ ...rows[0], display_name: viewer.displayName }, viewer, membership);
};

export const removeMessage = async ({ viewer, messageId }) => {
  const { rows } = await pool.query(`SELECT id, space_id, author_id FROM space_messages WHERE id = $1 AND deleted_at IS NULL`, [messageId]);
  if (!rows[0]) fail('not_found', 'No such message');
  const { membership } = await requireFullView(viewer, rows[0].space_id);
  if (!Rules.canRemoveMessage({ authorId: rows[0].author_id, viewerId: viewer.userId, membership })) fail('forbidden', 'You cannot remove this message.');
  await pool.query(`UPDATE space_messages SET deleted_at = now(), deleted_by = $2 WHERE id = $1`, [messageId, viewer.userId]);
  if (rows[0].author_id !== viewer.userId) await logAction(rows[0].space_id, viewer.userId, 'chat.remove');
  return { removed: true };
};

// ---------------------------------------------------------------------------
// Rooms of a space
// ---------------------------------------------------------------------------

const occupancy = async (liveId) => {
  try {
    const { occupancy: read } = await import('../capacity/CapacityGuard.js');
    return (await read(liveId)).occupied ?? 0;
  } catch {
    return 0;
  }
};

const roomRules = () => import('../rooms/roomRules.js');

const toSpaceRoom = async (row) => {
  const R = await roomRules();
  const room = {
    startsAt: row.starts_at, endsAt: row.ends_at, status: row.status, earlyEntryMinutes: row.early_entry_min,
  };
  const phase = R.phaseOf(room);
  return {
    code: row.room_code,
    title: row.title,
    hostName: row.host_name,
    startsAt: iso(row.starts_at),
    endsAt: iso(row.ends_at),
    phase,
    dropIn: Boolean(row.room_settings?.dropIn),
    here: phase === 'live' || phase === 'doors-open' ? await occupancy(row.id) : 0,
    spaceId: row.space_id,
    spaceName: row.space_name ?? undefined,
  };
};

const ROOM_SELECT = `
  SELECT s.id, s.room_code, s.title, s.starts_at, s.ends_at, s.status, s.early_entry_min, s.room_settings, s.space_id,
         u.display_name AS host_name, sp.name AS space_name
    FROM scheduled_sessions s
    JOIN users u ON u.id = s.host_id
    JOIN spaces sp ON sp.id = s.space_id`;

/** Upcoming and running rooms of one space. */
export const listRooms = async ({ viewer, spaceId }) => {
  await requireFullView(viewer, spaceId);
  const { rows } = await pool.query(
    `${ROOM_SELECT}
      WHERE s.space_id = $1 AND s.room_code IS NOT NULL AND s.status IN ('scheduled', 'live') AND s.ends_at > now()
      ORDER BY s.starts_at LIMIT 20`,
    [spaceId],
  );
  return { items: await Promise.all(rows.map(toSpaceRoom)) };
};

/** What is live right now in any of my spaces, for Home and the rail. */
export const liveInMySpaces = async ({ viewer }) => {
  const { rows } = await pool.query(
    `${ROOM_SELECT}
      JOIN space_memberships m ON m.space_id = s.space_id AND m.user_id = $1
      WHERE s.room_code IS NOT NULL AND s.status IN ('scheduled', 'live')
        AND s.ends_at > now() AND s.starts_at - make_interval(mins => s.early_entry_min) <= now()
      ORDER BY s.starts_at LIMIT 10`,
    [viewer.userId],
  );
  return Promise.all(rows.map(toSpaceRoom));
};

/** "HH:MM" wall-clock of now in a time zone, as the room editor would send it. */
const localNow = (timeZone) => {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date());
  const get = (type) => parts.find((part) => part.type === type)?.value ?? '00';
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour') === '24' ? '00' : get('hour')}:${get('minute')}`;
};

/**
 * Starts a drop-in room for the space, now, for an hour. If one is already
 * open in this space, that one is returned instead: one study hall at a time.
 */
export const startDropIn = async ({ viewer, spaceId }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const blocked = Rules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);

  const { rows: open } = await pool.query(
    `${ROOM_SELECT}
      WHERE s.space_id = $1 AND s.room_code IS NOT NULL AND s.status IN ('scheduled', 'live')
        AND s.ends_at > now() AND s.starts_at <= now() + interval '5 minutes'
        AND (s.room_settings ->> 'dropIn') = 'true'
      ORDER BY s.starts_at LIMIT 1`,
    [spaceId],
  );
  if (open[0]) return { room: await toSpaceRoom(open[0]), started: false };

  const { rows: zone } = await pool.query(`SELECT time_zone FROM users WHERE id = $1`, [viewer.userId]);
  const timeZone = zone[0]?.time_zone || 'UTC';
  const Rooms = await import('../rooms/ScheduledRooms.js');
  let created;
  try {
    [created] = await Rooms.create({
      tenantId: viewer.tenantId,
      hostId: viewer.userId,
      input: {
        title: `${space.name}: drop-in`,
        description: `An open study room for everyone in ${space.name}.`,
        startsAtLocal: localNow(timeZone),
        durationMinutes: Rules.DROP_IN_MINUTES,
        timeZone,
        earlyEntryMinutes: 3,
        lateJoinMinutes: null,
        capacity: null,
        access: 'invited',
        approval: false,
        inviteeIds: [],
        cohostIds: [],
        settings: { learnersJoinMuted: true, reactionsEnabled: true, learnersMayShare: true, dropIn: true },
        recurrence: null,
      },
    });
  } catch (cause) {
    if (cause?.code === 'conflict') fail('conflict', 'You already have a room at this time. Join that one, or end it first.');
    throw cause;
  }
  await pool.query(
    `UPDATE scheduled_sessions SET space_id = $2, room_settings = room_settings || '{"dropIn": true}'::jsonb WHERE id = $1`,
    [created.id, spaceId],
  );
  const { rows } = await pool.query(`${ROOM_SELECT} WHERE s.id = $1`, [created.id]);
  const room = await toSpaceRoom(rows[0]);

  const { rows: members } = await pool.query(
    // Part 3: only people who want each notification from this space; "daily" gets it in the summary.
    `SELECT user_id FROM space_memberships WHERE space_id = $1 AND user_id <> $2 AND notify_mode = 'each' LIMIT 500`,
    [spaceId, viewer.userId],
  );
  await notify({
    userIds: members.map((member) => member.user_id),
    type: 'space.live',
    title: `${viewer.displayName} opened a drop-in room in ${space.name}`,
    body: 'Come in for the next hour.',
    href: `/rooms/${room.code}/lobby`,
    actorId: viewer.userId,
    data: { spaceId, roomCode: room.code },
    dedupeKey: `space.live:${spaceId}:${Math.floor(Date.now() / 3_600_000)}`,
  });
  log.info({ spaceId, code: room.code }, 'drop-in room started');
  return { room, started: true };
};

export { localNow };

export default {
  listCards, createCard, updateCard, removeCard, listMaterials, addMaterial, pinMaterial, removeMaterial,
  listMessages, sendMessage, removeMessage, listRooms, liveInMySpaces, startDropIn,
};
__MAT_EOF__
echo "wrote server/src/hub/HubExtras.js"

mkdir -p server/test/files
cat > server/test/files/fileRules.check.mjs <<'__MAT_EOF__'
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
__MAT_EOF__
echo "wrote server/test/files/fileRules.check.mjs"

mkdir -p server/test/hub
cat > server/test/hub/hubRules.check.mjs <<'__MAT_EOF__'
// Community — who sees and does what in a space.
// Run: node --test server/test/hub/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  CreateSpaceSchema,
  CreateThreadSchema,
  authorView,
  canCreateKind,
  canMarkAnswer,
  canRemove,
  excerpt,
  hasEnded,
  memberListVisible,
  postingBlockedBecause,
  roomForMember,
  viewOf,
} from '../../src/hub/hubRules.js';

const member = { role: 'member' };
const moderator = { role: 'moderator' };
const space = (overrides = {}) => ({ access: 'open', memberList: 'members', kind: 'topic', endsAt: null, archivedAt: null, ...overrides });

test('what a space shows to whom', () => {
  assert.equal(viewOf(space(), null), 'full');
  assert.equal(viewOf(space({ access: 'request' }), null), 'preview');
  assert.equal(viewOf(space({ access: 'invite' }), null), 'hidden');
  assert.equal(viewOf(space({ access: 'invite' }), member), 'full');
});

test('member lists follow the space setting', () => {
  assert.equal(memberListVisible(space(), member), true);
  assert.equal(memberListVisible(space({ memberList: 'moderators' }), member), false);
  assert.equal(memberListVisible(space({ memberList: 'moderators' }), moderator), true);
  assert.equal(memberListVisible(space({ access: 'request' }), null), false);
  assert.equal(memberListVisible(space(), null), true);
});

test('anonymous questions: hidden from members, known to the author and moderators', () => {
  const base = { authorId: 'a', displayName: 'Anna', anonymous: true };
  assert.deepEqual(authorView({ ...base, viewerId: 'x', viewerIsModerator: false }), {
    userId: null, displayName: 'Anonymous', anonymous: true, you: false,
  });
  assert.equal(authorView({ ...base, viewerId: 'a', viewerIsModerator: false }).displayName, 'Anna');
  assert.equal(authorView({ ...base, viewerId: 'a', viewerIsModerator: false }).hiddenFromOthers, true);
  assert.equal(authorView({ ...base, viewerId: 'm', viewerIsModerator: true }).revealedToModerator, true);
  assert.equal(authorView({ ...base, anonymous: false, viewerId: 'x', viewerIsModerator: false }).displayName, 'Anna');
});

test('posting: members only, not in ended spaces, not during a timeout', () => {
  const now = Date.parse('2026-10-01T12:00:00Z');
  assert.match(postingBlockedBecause(space(), null, now), /Join/);
  assert.equal(postingBlockedBecause(space(), member, now), null);
  assert.match(postingBlockedBecause(space({ kind: 'study', endsAt: '2026-09-30T00:00:00Z' }), member, now), /ended/);
  assert.match(postingBlockedBecause(space(), { ...member, timeoutUntil: '2026-10-01T13:00:00Z' }, now), /paused/);
  assert.equal(postingBlockedBecause(space(), { ...member, timeoutUntil: '2026-10-01T11:00:00Z' }, now), null);
  assert.equal(hasEnded(space({ archivedAt: '2026-01-01T00:00:00Z' }), now), true);
});

test('answers, removal, class spaces and study group size', () => {
  const question = { kind: 'question', authorId: 'a' };
  assert.equal(canMarkAnswer({ thread: question, viewerId: 'a', membership: member }), true);
  assert.equal(canMarkAnswer({ thread: question, viewerId: 'b', membership: member }), false);
  assert.equal(canMarkAnswer({ thread: question, viewerId: 'b', membership: moderator }), true);
  assert.equal(canMarkAnswer({ thread: { ...question, kind: 'discussion' }, viewerId: 'a', membership: member }), false);
  assert.equal(canRemove({ authorId: 'a', viewerId: 'a', membership: member }), true);
  assert.equal(canRemove({ authorId: 'a', viewerId: 'b', membership: member }), false);
  assert.equal(canCreateKind('class', 'learner'), false);
  assert.equal(canCreateKind('class', 'teacher'), true);
  assert.equal(canCreateKind('topic', 'learner'), true);
  assert.equal(roomForMember(space({ kind: 'study' }), 12), false);
  assert.equal(roomForMember(space({ kind: 'topic' }), 500), true);
});

test('input: study groups need an end, only questions can be anonymous', () => {
  assert.equal(CreateSpaceSchema.safeParse({ name: 'Exam prep', kind: 'study' }).success, false);
  assert.equal(CreateSpaceSchema.safeParse({ name: 'Exam prep', kind: 'study', endsAt: '2026-12-01T00:00:00Z' }).success, true);
  assert.equal(CreateSpaceSchema.safeParse({ name: 'Books', endsAt: '2026-12-01T00:00:00Z' }).success, false);
  assert.equal(CreateSpaceSchema.parse({ name: 'Books', tags: ['  Reading '] }).tags[0], 'reading');
  assert.equal(CreateThreadSchema.safeParse({ title: 'Hello there', body: 'x', anonymous: true }).success, false);
  assert.equal(CreateThreadSchema.safeParse({ title: 'Why ¾?', body: 'x', kind: 'question', anonymous: true }).success, true);
});

test('excerpts are short and clean', () => {
  assert.equal(excerpt('# Title\n\nSome **bold** text'), 'Title Some bold text');
  assert.equal(excerpt('a'.repeat(300)).length, 180);
});

import { CardSchema, MaterialSchema, ReplySchema, canCurate, canRemoveMessage, safeUrl, solutionFolded } from '../../src/hub/hubRules.js';

test('part 2: materials only link to web addresses', () => {
  assert.equal(safeUrl('https://example.com/a?b=1'), 'https://example.com/a?b=1');
  assert.equal(safeUrl('javascript:alert(1)'), null);
  assert.equal(safeUrl('data:text/html,hi'), null);
  assert.equal(safeUrl('not a url'), null);
  assert.equal(MaterialSchema.safeParse({ title: 'Slides', url: 'https://example.com/s.pdf' }).success, true);
  assert.equal(MaterialSchema.safeParse({ title: 'Evil', url: 'javascript:alert(1)' }).success, false);
});

test('part 2: cards, hidden solutions, chat removal', () => {
  assert.equal(CardSchema.safeParse({ title: 'Adding fractions', body: 'Same bottoms first.' }).success, true);
  assert.equal(CardSchema.safeParse({ title: 'x', body: 'y' }).success, false);
  assert.equal(ReplySchema.parse({ body: 'answer' }).hiddenSolution, false);
  assert.equal(solutionFolded({ hiddenSolution: true, authorId: 'a', viewerId: 'b' }), true);
  assert.equal(solutionFolded({ hiddenSolution: true, authorId: 'a', viewerId: 'a' }), false);
  assert.equal(solutionFolded({ hiddenSolution: false, authorId: 'a', viewerId: 'b' }), false);
  assert.equal(canCurate({ role: 'moderator' }), true);
  assert.equal(canCurate({ role: 'member' }), false);
  assert.equal(canRemoveMessage({ authorId: 'a', viewerId: 'a', membership: { role: 'member' } }), true);
  assert.equal(canRemoveMessage({ authorId: 'a', viewerId: 'b', membership: { role: 'member' } }), false);
  assert.equal(canRemoveMessage({ authorId: 'a', viewerId: 'b', membership: { role: 'owner' } }), true);
});

import { canRemoveMaterial, MaterialSchema as Materials } from '../../src/hub/hubRules.js';

test('materials: a link or a file, never both, never neither', () => {
  const fileId = '00000000-0000-4000-8000-000000000001';
  assert.equal(Materials.safeParse({ title: 'Docs', url: 'https://any-website.example/path?q=1' }).success, true);
  assert.equal(Materials.safeParse({ fileId }).success, true);
  assert.equal(Materials.safeParse({ title: 'Both', url: 'https://a.example', fileId }).success, false);
  assert.equal(Materials.safeParse({ title: 'Neither' }).success, false);
  assert.equal(Materials.safeParse({ url: 'https://a.example' }).success, false, 'a link needs a title');
  assert.equal(Materials.safeParse({ title: 'x', url: 'ftp://a.example' }).success, false);
  assert.equal(canRemoveMaterial({ addedBy: 'a', viewerId: 'a', membership: { role: 'member' } }), true);
  assert.equal(canRemoveMaterial({ addedBy: 'a', viewerId: 'b', membership: { role: 'member' } }), false);
  assert.equal(canRemoveMaterial({ addedBy: 'a', viewerId: 'b', membership: { role: 'moderator' } }), true);
});
__MAT_EOF__
echo "wrote server/test/hub/hubRules.check.mjs"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/filesApi.ts <<'__MAT_EOF__'
/**
 * Files API  (Files and Media)
 *
 * Your own uploads — the Media library. Paths are the server's
 * (server/src/routes/files.routes.js, mounted under /files).
 *
 * An upload is three steps: startUpload() reserves it and returns a signed
 * URL; the browser PUTs the bytes there (apps/web/src/lib/files.js does that,
 * with progress); completeUpload() has the server check and scan the file and
 * answers with the ready file — or an error that says why it was refused.
 *
 * `openUrl` is a path relative to the API, valid for two hours; it opens the
 * file in a new tab without a sign-in header.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

export const FileViewSchema = z
  .object({
    fileId: z.string(),
    name: z.string(),
    ext: z.string(),
    kind: z.enum(['image', 'document', 'video', 'audio', 'text']),
    contentType: z.string(),
    sizeBytes: z.number(),
    status: z.string(),
    inline: z.boolean().default(false),
    createdAt: z.string().nullable(),
    usedIn: z.number().optional(),
    openUrl: z.string().nullable().default(null),
  })
  .passthrough();
export type FileView = z.infer<typeof FileViewSchema>;

const UploadTicketSchema = z
  .object({
    fileId: z.string(),
    uploadUrl: z.string(),
    uploadHeaders: z.record(z.string(), z.string()).default({}),
    expiresInSec: z.number().default(900),
  })
  .passthrough();
export type UploadTicket = z.infer<typeof UploadTicketSchema>;

const LibrarySchema = z
  .object({
    items: z.array(FileViewSchema),
    usage: z.object({ usedBytes: z.number(), quotaBytes: z.number(), maxFileBytes: z.number() }).passthrough(),
    accept: z.array(z.string()).default([]),
  })
  .passthrough();
export type FileLibrary = z.infer<typeof LibrarySchema>;

export interface FilesApi {
  startUpload(input: { name: string; sizeBytes: number }): Promise<UploadTicket>;
  completeUpload(fileId: string): Promise<FileView>;
  list(query?: { q?: string; kind?: string }, signal?: AbortSignal): Promise<FileLibrary>;
  rename(fileId: string, name: string): Promise<FileView>;
  remove(fileId: string): Promise<unknown>;
  link(fileId: string): Promise<{ url: string }>;
}

const enc = encodeURIComponent;

export const createFilesApi = (http: HttpClient): FilesApi => ({
  startUpload: (input) => http.post('/files/uploads', input, { schema: UploadTicketSchema, retry: { attempts: 1 } }),
  completeUpload: (fileId) => http.post(`/files/${enc(fileId)}/complete`, {}, { schema: FileViewSchema, retry: { attempts: 1 } }),
  list: (query = {}, signal) =>
    http.get('/files', {
      schema: LibrarySchema,
      query: Object.fromEntries(Object.entries(query).filter(([, value]) => value)),
      signal,
    }),
  rename: (fileId, name) => http.patch(`/files/${enc(fileId)}`, { name }, { schema: FileViewSchema }),
  remove: (fileId) => http.delete(`/files/${enc(fileId)}`),
  link: (fileId) => http.get(`/files/${enc(fileId)}/link`, { schema: z.object({ url: z.string() }).passthrough() }),
});
__MAT_EOF__
echo "wrote packages/core-client/src/api/filesApi.ts"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/hubApi.ts <<'__MAT_EOF__'
/**
 * Community API  (Community, part 1)
 *
 * Spaces, membership, threads, questions and reports — and, since part 2,
 * knowledge cards, materials, a chat per space and the space's rooms — and,
 * since part 3, study partners, posts that wait until morning, calm mode,
 * per-space notification modes and the moderators' log.
 * Paths are the server's
 * (server/src/routes/hub.routes.js, mounted under /hub). Responses are
 * validated loosely (passthrough): the server shapes every view, including
 * who is shown as "Anonymous".
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const Badge = z.object({ level: z.string(), label: z.string() }).nullable().default(null);

const Author = z
  .object({
    userId: z.string().nullable(),
    displayName: z.string(),
    anonymous: z.boolean().default(false),
    you: z.boolean().default(false),
    hiddenFromOthers: z.boolean().optional(),
    revealedToModerator: z.boolean().optional(),
  })
  .passthrough();
export type HubAuthor = z.infer<typeof Author>;

export const HubSpaceSchema = z
  .object({
    spaceId: z.string(),
    name: z.string(),
    description: z.string().nullable().default(null),
    kind: z.enum(['class', 'topic', 'study']),
    access: z.enum(['open', 'request', 'invite']),
    memberList: z.enum(['members', 'moderators']),
    joinQuestion: z.string().nullable().default(null),
    endsAt: z.string().nullable().default(null),
    emoji: z.string().nullable().default(null),
    tags: z.array(z.string()).default([]),
    chatSlowSeconds: z.number().default(0),
    courseId: z.string().nullable().default(null),
    memberCount: z.number().default(0),
    newActivity: z.number().default(0),
    openQuestions: z.number().default(0),
    lastActivityAt: z.string().nullable().default(null),
    myRole: z.string().nullable().default(null),
    myRequest: z.string().nullable().default(null),
    ended: z.boolean().default(false),
    view: z.enum(['full', 'preview', 'hidden']).optional(),
    me: z
      .object({
        role: z.string().nullable(),
        moderator: z.boolean(),
        postingBlocked: z.string().nullable(),
        timeoutUntil: z.string().nullable().default(null),
        request: z.string().nullable().default(null),
        notifyMode: z.string().nullable().default(null),
      })
      .passthrough()
      .optional(),
  })
  .passthrough();
export type HubSpace = z.infer<typeof HubSpaceSchema>;

export const HubThreadSummarySchema = z
  .object({
    threadId: z.string(),
    spaceId: z.string(),
    spaceName: z.string().optional(),
    spaceEmoji: z.string().nullable().optional(),
    title: z.string(),
    kind: z.enum(['discussion', 'question']),
    excerpt: z.string().default(''),
    author: Author,
    replies: z.number().default(0),
    answered: z.boolean().default(false),
    metoo: z.number().default(0),
    myMetoo: z.boolean().default(false),
    pinned: z.boolean().default(false),
    locked: z.boolean().default(false),
    createdAt: z.string().nullable(),
    lastPostAt: z.string().nullable(),
  })
  .passthrough();
export type HubThreadSummary = z.infer<typeof HubThreadSummarySchema>;

export const HubThreadSchema = HubThreadSummarySchema.extend({
  space: z.object({ spaceId: z.string(), name: z.string(), emoji: z.string().nullable(), kind: z.string() }).passthrough(),
  answeredPostId: z.string().nullable().default(null),
  calm: z.object({ slowSeconds: z.number().default(0), waitSeconds: z.number().default(0) }).passthrough().default({ slowSeconds: 0, waitSeconds: 0 }),
  posts: z.array(
    z
      .object({
        postId: z.string(),
        first: z.boolean(),
        body: z.string(),
        replyToId: z.string().nullable().default(null),
        createdAt: z.string().nullable(),
        editedAt: z.string().nullable().default(null),
        author: Author,
        answer: z.boolean().default(false),
        canRemove: z.boolean().default(false),
        hiddenSolution: z.boolean().default(false),
        folded: z.boolean().default(false),
        badge: Badge,
      })
      .passthrough(),
  ),
  me: z
    .object({
      moderator: z.boolean(),
      canReply: z.boolean(),
      replyBlocked: z.string().nullable().default(null),
      canMarkAnswer: z.boolean(),
      canRemoveThread: z.boolean(),
      canMetoo: z.boolean(),
      canSaveCard: z.boolean().default(false),
    })
    .passthrough(),
}).passthrough();
export type HubThread = z.infer<typeof HubThreadSchema>;

const Items = <T extends z.ZodTypeAny>(item: T) => z.object({ items: z.array(item) }).passthrough();

const MembersSchema = z
  .object({
    listVisible: z.boolean(),
    count: z.number(),
    items: z.array(
      z
        .object({
          userId: z.string(),
          displayName: z.string(),
          role: z.string(),
          joinedAt: z.string().nullable(),
          you: z.boolean().default(false),
          timeoutUntil: z.string().nullable().optional(),
          badge: Badge,
        })
        .passthrough(),
    ),
  })
  .passthrough();
export type HubMembers = z.infer<typeof MembersSchema>;

export const HubRoomSchema = z
  .object({
    code: z.string(),
    title: z.string(),
    hostName: z.string().nullable().default(null),
    startsAt: z.string(),
    endsAt: z.string(),
    phase: z.string(),
    dropIn: z.boolean().default(false),
    here: z.number().default(0),
    spaceId: z.string(),
    spaceName: z.string().optional(),
  })
  .passthrough();
export type HubRoom = z.infer<typeof HubRoomSchema>;

export const HubCardSchema = z
  .object({
    cardId: z.string(),
    spaceId: z.string(),
    threadId: z.string().nullable().default(null),
    postId: z.string().nullable().default(null),
    title: z.string(),
    body: z.string(),
    createdBy: z.string().nullable().default(null),
    createdAt: z.string().nullable(),
    updatedAt: z.string().nullable(),
  })
  .passthrough();
export type HubCard = z.infer<typeof HubCardSchema>;

export const HubMaterialSchema = z
  .object({
    materialId: z.string(),
    type: z.enum(['link', 'file']).default('link'),
    title: z.string(),
    url: z.string().nullable().default(null),
    host: z.string().nullable().default(null),
    file: z
      .object({
        fileId: z.string(),
        name: z.string().nullable(),
        ext: z.string().nullable(),
        kind: z.string().nullable(),
        sizeBytes: z.number().nullable(),
        available: z.boolean(),
        openUrl: z.string().nullable(),
      })
      .passthrough()
      .nullable()
      .default(null),
    note: z.string().nullable().default(null),
    pinned: z.boolean().default(false),
    addedBy: z.string().nullable().default(null),
    createdAt: z.string().nullable(),
    canRemove: z.boolean().default(false),
  })
  .passthrough();
export type HubMaterial = z.infer<typeof HubMaterialSchema>;

export const HubMessageSchema = z
  .object({
    messageId: z.string(),
    body: z.string(),
    author: z.object({ userId: z.string(), displayName: z.string(), you: z.boolean().default(false) }).passthrough(),
    createdAt: z.string().nullable(),
    cursor: z.string(),
    canRemove: z.boolean().default(false),
  })
  .passthrough();
export type HubMessage = z.infer<typeof HubMessageSchema>;

const ChatPageSchema = z
  .object({
    items: z.array(HubMessageSchema),
    nextCursor: z.string().nullable().default(null),
    postingBlocked: z.string().nullable().default(null),
    calmSeconds: z.number().default(0),
    canModerate: z.boolean().default(false),
  })
  .passthrough();

export const StudyProfileSchema = z
  .object({
    exists: z.boolean(),
    active: z.boolean(),
    subjects: z.array(z.string()),
    availability: z.array(z.string()),
    note: z.string().nullable().default(null),
  })
  .passthrough();
export type StudyProfile = z.infer<typeof StudyProfileSchema>;

const SuggestionsSchema = z
  .object({
    needsProfile: z.boolean(),
    items: z.array(
      z
        .object({ userId: z.string(), displayName: z.string(), note: z.string().nullable().default(null), reasons: z.array(z.string()) })
        .passthrough(),
    ),
  })
  .passthrough();

const PartnersSchema = z
  .object({
    partners: z.array(z.object({ userId: z.string(), displayName: z.string(), since: z.string().nullable(), sharedTimes: z.array(z.string()) }).passthrough()),
    incoming: z.array(z.object({ userId: z.string(), displayName: z.string(), message: z.string().nullable().default(null), at: z.string().nullable() }).passthrough()),
    outgoing: z.array(z.object({ userId: z.string(), displayName: z.string(), at: z.string().nullable() }).passthrough()),
  })
  .passthrough();
export type PartnersPage = z.infer<typeof PartnersSchema>;

export const ScheduledSchema = z
  .object({ scheduledId: z.string(), kind: z.string(), sendAt: z.string(), preview: z.string(), targetId: z.string().optional() })
  .passthrough();
export type ScheduledPost = z.infer<typeof ScheduledSchema>;

const LogSchema = z
  .object({
    items: z.array(
      z
        .object({
          entryId: z.string(),
          action: z.string(),
          label: z.string(),
          actorName: z.string(),
          targetName: z.string().nullable().default(null),
          detail: z.record(z.string(), z.unknown()).default({}),
          at: z.string().nullable(),
        })
        .passthrough(),
    ),
  })
  .passthrough();
export type HubLog = z.infer<typeof LogSchema>;

export type ScheduleInput =
  | { kind: 'reply'; targetId: string; body: string; hiddenSolution?: boolean }
  | { kind: 'thread'; targetId: string; title: string; body: string; threadKind?: 'discussion' | 'question'; anonymous?: boolean }
  | { kind: 'chat'; targetId: string; body: string };

const HomeSchema = z
  .object({
    live: z.array(HubRoomSchema).default([]),
    spaces: z.array(HubSpaceSchema),
    recent: z.array(HubThreadSummarySchema),
    myThreads: z.array(HubThreadSummarySchema),
    openQuestions: z.number().default(0),
  })
  .passthrough();
export type HubHome = z.infer<typeof HomeSchema>;

const RequestSchema = z
  .object({ userId: z.string(), displayName: z.string(), answer: z.string().nullable().default(null), at: z.string().nullable() })
  .passthrough();
const ReportSchema = z
  .object({
    reportId: z.string(),
    targetType: z.string(),
    targetId: z.string(),
    reason: z.string(),
    note: z.string().nullable().default(null),
    threadId: z.string().nullable().default(null),
    threadTitle: z.string().nullable().default(null),
    excerpt: z.string().nullable().default(null),
    targetName: z.string().nullable().default(null),
    at: z.string().nullable(),
  })
  .passthrough();
export type HubReport = z.infer<typeof ReportSchema>;

export interface NewSpaceInput {
  name: string;
  description?: string | null;
  kind: 'class' | 'topic' | 'study';
  access: 'open' | 'request' | 'invite';
  memberList: 'members' | 'moderators';
  joinQuestion?: string | null;
  endsAt?: string | null;
  emoji?: string | null;
  tags?: string[];
}

export interface HubApi {
  home(signal?: AbortSignal): Promise<HubHome>;
  questions(query?: { filter?: 'unanswered' | 'answered' | 'all'; sort?: 'metoo' | 'new' }, signal?: AbortSignal): Promise<{ items: HubThreadSummary[] }>;
  spaces(query?: { scope?: 'mine' | 'discover'; q?: string; kind?: string }, signal?: AbortSignal): Promise<{ items: HubSpace[] }>;
  createSpace(input: NewSpaceInput): Promise<HubSpace>;
  space(spaceId: string, signal?: AbortSignal): Promise<HubSpace>;
  updateSpace(spaceId: string, patch: Partial<NewSpaceInput>): Promise<HubSpace>;
  archiveSpace(spaceId: string): Promise<unknown>;
  join(spaceId: string, answer?: string | null): Promise<HubSpace>;
  leave(spaceId: string): Promise<unknown>;
  requests(spaceId: string, signal?: AbortSignal): Promise<{ items: z.infer<typeof RequestSchema>[] }>;
  decide(spaceId: string, userId: string, approve: boolean): Promise<unknown>;
  invite(spaceId: string, userIds: string[]): Promise<{ added: number }>;
  members(spaceId: string, signal?: AbortSignal): Promise<HubMembers>;
  updateMember(spaceId: string, userId: string, patch: { role?: string; timeoutMinutes?: number }): Promise<unknown>;
  removeMember(spaceId: string, userId: string): Promise<unknown>;
  threads(spaceId: string, filter?: 'all' | 'questions' | 'unanswered', signal?: AbortSignal): Promise<{ items: HubThreadSummary[] }>;
  createThread(spaceId: string, input: { title: string; body: string; kind: 'discussion' | 'question'; anonymous?: boolean }): Promise<HubThread>;
  thread(threadId: string, signal?: AbortSignal): Promise<HubThread>;
  reply(threadId: string, body: string, replyToId?: string | null, hiddenSolution?: boolean): Promise<HubThread>;
  markAnswer(threadId: string, postId: string | null): Promise<HubThread>;
  metoo(threadId: string): Promise<HubThread>;
  moderateThread(threadId: string, patch: { pinned?: boolean; locked?: boolean }): Promise<HubThread>;
  removeThread(threadId: string): Promise<{ removed: boolean; spaceId: string }>;
  removePost(postId: string): Promise<HubThread>;
  report(spaceId: string, input: { targetType: 'thread' | 'post' | 'user'; targetId: string; reason: string; note?: string | null }): Promise<unknown>;
  reports(spaceId: string, signal?: AbortSignal): Promise<{ items: HubReport[] }>;
  resolveReport(spaceId: string, reportId: string, action: 'remove' | 'dismiss'): Promise<unknown>;
  // Part 2
  cards(spaceId: string, q?: string, signal?: AbortSignal): Promise<{ items: HubCard[]; canCurate: boolean }>;
  createCard(spaceId: string, input: { title: string; body: string; postId?: string | null }): Promise<HubCard>;
  updateCard(cardId: string, patch: { title?: string; body?: string }): Promise<HubCard>;
  removeCard(cardId: string): Promise<unknown>;
  materials(spaceId: string, signal?: AbortSignal): Promise<{ items: HubMaterial[]; canCurate: boolean; canAdd: boolean }>;
  /** A link to any website ({ title, url }) or a file from your Media library ({ fileId }). */
  addMaterial(
    spaceId: string,
    input: { title?: string | null; url?: string | null; fileId?: string | null; note?: string | null; pinned?: boolean },
  ): Promise<HubMaterial>;
  pinMaterial(materialId: string, pinned: boolean): Promise<HubMaterial>;
  removeMaterial(materialId: string): Promise<unknown>;
  chat(spaceId: string, after?: string | null, signal?: AbortSignal): Promise<z.infer<typeof ChatPageSchema>>;
  sendChat(spaceId: string, body: string): Promise<HubMessage>;
  removeChat(messageId: string): Promise<unknown>;
  rooms(spaceId: string, signal?: AbortSignal): Promise<{ items: HubRoom[] }>;
  dropIn(spaceId: string): Promise<{ room: HubRoom; started: boolean }>;
  // Part 3
  studyProfile(signal?: AbortSignal): Promise<StudyProfile>;
  saveStudyProfile(input: { active: boolean; subjects: string[]; availability: string[]; note?: string | null }): Promise<StudyProfile>;
  studySuggestions(signal?: AbortSignal): Promise<z.infer<typeof SuggestionsSchema>>;
  partners(signal?: AbortSignal): Promise<PartnersPage>;
  requestPartner(userId: string, message?: string | null): Promise<unknown>;
  respondPartner(userId: string, accept: boolean): Promise<unknown>;
  endPartner(userId: string): Promise<unknown>;
  studyNow(userId: string): Promise<{ code: string }>;
  scheduled(signal?: AbortSignal): Promise<{ items: ScheduledPost[] }>;
  schedule(input: ScheduleInput): Promise<ScheduledPost>;
  cancelScheduled(scheduledId: string): Promise<unknown>;
  setThreadCalm(threadId: string, seconds: number): Promise<HubThread>;
  setChatCalm(spaceId: string, seconds: number): Promise<unknown>;
  setNotifyMode(spaceId: string, mode: 'each' | 'daily' | 'off'): Promise<unknown>;
  log(spaceId: string, signal?: AbortSignal): Promise<HubLog>;
}

const enc = encodeURIComponent;
const once = { retry: { attempts: 1 } };

export const createHubApi = (http: HttpClient): HubApi => ({
  home: (signal) => http.get('/hub/home', { schema: HomeSchema, signal }),
  questions: (query = {}, signal) => http.get('/hub/questions', { schema: Items(HubThreadSummarySchema), query, signal }),
  spaces: (query = {}, signal) => http.get('/hub/spaces', { schema: Items(HubSpaceSchema), query, signal }),
  createSpace: (input) => http.post('/hub/spaces', input, { schema: HubSpaceSchema, ...once }),
  space: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}`, { schema: HubSpaceSchema, signal }),
  updateSpace: (spaceId, patch) => http.patch(`/hub/spaces/${enc(spaceId)}`, patch, { schema: HubSpaceSchema }),
  archiveSpace: (spaceId) => http.post(`/hub/spaces/${enc(spaceId)}/archive`, {}, once),
  join: (spaceId, answer = null) => http.post(`/hub/spaces/${enc(spaceId)}/join`, { answer }, { schema: HubSpaceSchema, ...once }),
  leave: (spaceId) => http.post(`/hub/spaces/${enc(spaceId)}/leave`, {}, once),
  requests: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/requests`, { schema: Items(RequestSchema), signal }),
  decide: (spaceId, userId, approve) => http.post(`/hub/spaces/${enc(spaceId)}/requests/${enc(userId)}`, { approve }, once),
  invite: (spaceId, userIds) =>
    http.post(`/hub/spaces/${enc(spaceId)}/invite`, { userIds }, { schema: z.object({ added: z.number() }).passthrough(), ...once }),
  members: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/members`, { schema: MembersSchema, signal }),
  updateMember: (spaceId, userId, patch) => http.patch(`/hub/spaces/${enc(spaceId)}/members/${enc(userId)}`, patch),
  removeMember: (spaceId, userId) => http.delete(`/hub/spaces/${enc(spaceId)}/members/${enc(userId)}`),
  threads: (spaceId, filter = 'all', signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/threads`, { schema: Items(HubThreadSummarySchema), query: { filter }, signal }),
  createThread: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/threads`, input, { schema: HubThreadSchema, ...once }),
  thread: (threadId, signal) => http.get(`/hub/threads/${enc(threadId)}`, { schema: HubThreadSchema, signal }),
  reply: (threadId, body, replyToId = null, hiddenSolution = false) =>
    http.post(`/hub/threads/${enc(threadId)}/replies`, { body, replyToId, hiddenSolution }, { schema: HubThreadSchema, ...once }),
  markAnswer: (threadId, postId) => http.post(`/hub/threads/${enc(threadId)}/answer`, { postId }, { schema: HubThreadSchema }),
  metoo: (threadId) => http.post(`/hub/threads/${enc(threadId)}/metoo`, {}, { schema: HubThreadSchema }),
  moderateThread: (threadId, patch) => http.patch(`/hub/threads/${enc(threadId)}`, patch, { schema: HubThreadSchema }),
  removeThread: (threadId) =>
    http.delete(`/hub/threads/${enc(threadId)}`, { schema: z.object({ removed: z.boolean(), spaceId: z.string() }).passthrough() }),
  removePost: (postId) => http.delete(`/hub/posts/${enc(postId)}`, { schema: HubThreadSchema }),
  report: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/reports`, input, once),
  reports: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/reports`, { schema: Items(ReportSchema), signal }),
  resolveReport: (spaceId, reportId, action) => http.post(`/hub/spaces/${enc(spaceId)}/reports/${enc(reportId)}`, { action }, once),

  cards: (spaceId, q = '', signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/cards`, {
      schema: z.object({ items: z.array(HubCardSchema), canCurate: z.boolean().default(false) }).passthrough(),
      query: q ? { q } : undefined,
      signal,
    }),
  createCard: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/cards`, input, { schema: HubCardSchema, ...once }),
  updateCard: (cardId, patch) => http.patch(`/hub/cards/${enc(cardId)}`, patch, { schema: HubCardSchema }),
  removeCard: (cardId) => http.delete(`/hub/cards/${enc(cardId)}`),
  materials: (spaceId, signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/materials`, {
      schema: z.object({ items: z.array(HubMaterialSchema), canCurate: z.boolean().default(false), canAdd: z.boolean().default(false) }).passthrough(),
      signal,
    }),
  addMaterial: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/materials`, input, { schema: HubMaterialSchema, ...once }),
  pinMaterial: (materialId, pinned) => http.patch(`/hub/materials/${enc(materialId)}`, { pinned }, { schema: HubMaterialSchema }),
  removeMaterial: (materialId) => http.delete(`/hub/materials/${enc(materialId)}`),
  chat: (spaceId, after = null, signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/chat`, { schema: ChatPageSchema, query: after ? { after } : undefined, signal, retry: { attempts: 1 } }),
  sendChat: (spaceId, body) => http.post(`/hub/spaces/${enc(spaceId)}/chat`, { body }, { schema: HubMessageSchema, ...once }),
  removeChat: (messageId) => http.delete(`/hub/chat/${enc(messageId)}`),
  rooms: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/rooms`, { schema: Items(HubRoomSchema), signal }),
  dropIn: (spaceId) =>
    http.post(`/hub/spaces/${enc(spaceId)}/rooms/drop-in`, {}, {
      schema: z.object({ room: HubRoomSchema, started: z.boolean() }).passthrough(),
      ...once,
    }),

  studyProfile: (signal) => http.get('/hub/study/profile', { schema: StudyProfileSchema, signal }),
  saveStudyProfile: (input) => http.put('/hub/study/profile', input, { schema: StudyProfileSchema }),
  studySuggestions: (signal) => http.get('/hub/study/suggestions', { schema: SuggestionsSchema, signal }),
  partners: (signal) => http.get('/hub/study/partners', { schema: PartnersSchema, signal }),
  requestPartner: (userId, message = null) => http.post(`/hub/study/requests/${enc(userId)}`, { message }, once),
  respondPartner: (userId, accept) => http.post(`/hub/study/requests/${enc(userId)}/respond`, { accept }, once),
  endPartner: (userId) => http.delete(`/hub/study/partners/${enc(userId)}`),
  studyNow: (userId) => http.post(`/hub/study/partners/${enc(userId)}/room`, {}, { schema: z.object({ code: z.string() }).passthrough(), ...once }),
  scheduled: (signal) => http.get('/hub/scheduled', { schema: Items(ScheduledSchema), signal }),
  schedule: (input) => http.post('/hub/scheduled', input, { schema: ScheduledSchema, ...once }),
  cancelScheduled: (scheduledId) => http.delete(`/hub/scheduled/${enc(scheduledId)}`),
  setThreadCalm: (threadId, seconds) => http.patch(`/hub/threads/${enc(threadId)}/calm`, { seconds }, { schema: HubThreadSchema }),
  setChatCalm: (spaceId, seconds) => http.patch(`/hub/spaces/${enc(spaceId)}/chat/calm`, { seconds }),
  setNotifyMode: (spaceId, mode) => http.patch(`/hub/spaces/${enc(spaceId)}/notify`, { mode }),
  log: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/log`, { schema: LogSchema, signal }),
});
__MAT_EOF__
echo "wrote packages/core-client/src/api/hubApi.ts"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/files.js <<'__MAT_EOF__'
import { apiHref, reachableUploadUrl } from '../components/Files/filesModel.js';

/**
 * Uploading a file  (Files and Media)
 *
 * startUpload → PUT the bytes to the signed URL (with progress) → completeUpload.
 * Returns the ready file; throws an Error whose message says why not.
 */

export const API_BASE = (import.meta.env?.VITE_API_URL || '/api').replace(/\/$/, '');

/** An absolute-enough href for a path the API returned (openUrl). */
export const fileHref = (path) => apiHref(path, API_BASE);

const put = (url, file, headers, onProgress, signal) =>
  new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', url);
    for (const [name, value] of Object.entries(headers ?? {})) xhr.setRequestHeader(name, value);
    xhr.upload.onprogress = (event) => event.lengthComputable && onProgress?.(event.loaded / event.total);
    xhr.onload = () => (xhr.status >= 200 && xhr.status < 300 ? resolve() : reject(new Error(`The upload was refused by storage (${xhr.status}).`)));
    xhr.onerror = () => reject(new Error('The upload could not reach the storage. Check your connection.'));
    xhr.onabort = () => reject(new Error('Upload cancelled.'));
    signal?.addEventListener('abort', () => xhr.abort());
    xhr.send(file);
  });

export const uploadFile = async ({ files, file, onProgress, onPhase, signal }) => {
  try {
    onPhase?.('starting');
    const ticket = await files.startUpload({ name: file.name, sizeBytes: file.size });
    onPhase?.('uploading');
    await put(reachableUploadUrl(ticket.uploadUrl, window.location.origin), file, ticket.uploadHeaders, onProgress, signal);
    onPhase?.('checking');
    return await files.completeUpload(ticket.fileId);
  } catch (cause) {
    throw new Error(cause?.detail ?? cause?.message ?? 'The upload did not work.');
  }
};
__MAT_EOF__
echo "wrote apps/web/src/lib/files.js"

mkdir -p apps/web/src/components/Files
cat > apps/web/src/components/Files/filesModel.js <<'__MAT_EOF__'
/**
 * Pure helpers for files  (Files and Media)
 * Tested in __checks__/filesModel.check.mjs. The server decides; these only
 * check early (so nobody waits for an upload that will be refused) and word
 * things.
 */

export const DEFAULT_ACCEPT = ['pdf', 'png', 'jpg', 'gif', 'webp', 'txt', 'csv', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt', 'mp4', 'm4a', 'mp3', 'wav'];

export const KIND_FILTERS = [
  { value: '', label: 'All' },
  { value: 'image', label: 'Images' },
  { value: 'document', label: 'Documents' },
  { value: 'video', label: 'Video' },
  { value: 'audio', label: 'Audio' },
  { value: 'text', label: 'Text' },
];

export const extensionOf = (name) => {
  const match = /\.([a-z0-9]{1,5})$/i.exec(String(name ?? ''));
  return match ? match[1].toLowerCase() : null;
};

/** "2.4 MB", "830 KB", "12 bytes". */
export const formatBytes = (bytes) => {
  const value = Number(bytes) || 0;
  if (value < 1024) return `${value} ${value === 1 ? 'byte' : 'bytes'}`;
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  if (value < 1024 ** 3) return `${(value / 1024 / 1024).toFixed(value < 10 * 1024 * 1024 ? 1 : 0)} MB`;
  return `${(value / 1024 ** 3).toFixed(1)} GB`;
};

/** The `accept` attribute for a file input: ".pdf,.png,…" (plus .jpeg). */
export const acceptAttribute = (extensions = DEFAULT_ACCEPT) =>
  [...extensions, ...(extensions.includes('jpg') ? ['jpeg'] : [])].map((ext) => `.${ext}`).join(',');

/** The same check the server makes first: a reason, or null. */
export const fileProblem = (file, { accept = DEFAULT_ACCEPT, maxBytes = 50 * 1024 * 1024 } = {}) => {
  const ext = extensionOf(file?.name);
  const allowed = [...accept, ...(accept.includes('jpg') ? ['jpeg'] : [])];
  if (!ext || !allowed.includes(ext)) return `${file?.name ?? 'This file'}: this format is not accepted.`;
  if (!file.size) return `${file.name} is empty.`;
  if (file.size > maxBytes) return `${file.name} is larger than ${Math.round(maxBytes / 1024 / 1024)} MB.`;
  return null;
};

/** A small emoji per kind, for lists without a preview. */
export const iconFor = (kind) => ({ image: '🖼️', document: '📄', video: '🎬', audio: '🎧', text: '📝' })[kind] ?? '📎';

/** "PDF, 1.2 MB" */
export const fileMeta = ({ ext, sizeBytes }) => [ext ? ext.toUpperCase() : null, sizeBytes ? formatBytes(sizeBytes) : null].filter(Boolean).join(', ');

/** 0–100 for a usage bar. */
export const usagePercent = ({ usedBytes, quotaBytes }) => (quotaBytes > 0 ? Math.min(100, Math.round((usedBytes / quotaBytes) * 100)) : 0);

/**
 * In development MinIO listens on localhost:9000, which a browser outside the
 * machine (a Codespace, a phone on the network) cannot reach. Signed URLs for
 * such hosts go through the dev server instead (/s3 → MinIO, vite.config).
 * Real storage URLs are left alone.
 */
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '0.0.0.0', 'minio', 'host.docker.internal']);
export const reachableUploadUrl = (url, pageOrigin) => {
  try {
    const target = new URL(url);
    if (!LOCAL_HOSTS.has(target.hostname)) return url;
    return `${pageOrigin ?? ''}/s3${target.pathname}${target.search}`;
  } catch {
    return url;
  }
};

/** The API base the browser uses ('/api' in development), plus a path from the API. */
export const apiHref = (path, base = '/api') => (path ? `${String(base).replace(/\/$/, '')}${path}` : null);
__MAT_EOF__
echo "wrote apps/web/src/components/Files/filesModel.js"

mkdir -p apps/web/src/components/Files
cat > apps/web/src/components/Files/FileDrop.jsx <<'__MAT_EOF__'
import { useMemo, useRef, useState } from 'react';
import { createFilesApi, useCore } from '@classroom/core-client';
import { uploadFile } from '../../lib/files.js';
import { DEFAULT_ACCEPT, acceptAttribute, fileProblem, formatBytes } from './filesModel.js';
import './files.css';

/**
 * Drop files here, or choose them  (Files and Media)
 *
 * Several at once, each with its own progress: uploading → checking → ready,
 * or the reason it was refused (wrong format, too large, not really a PDF,
 * flagged by the virus scan). Used by Media and by a space's materials.
 */
export default function FileDrop({ onUploaded, accept = DEFAULT_ACCEPT, maxBytes = 50 * 1024 * 1024, compact = false, multiple = true }) {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const inputRef = useRef(null);
  const [over, setOver] = useState(false);
  const [queue, setQueue] = useState([]);

  const update = (id, patch) => setQueue((current) => current.map((item) => (item.id === id ? { ...item, ...patch } : item)));

  const start = (list) => {
    const chosen = [...list].slice(0, multiple ? 20 : 1);
    for (const file of chosen) {
      const id = `${file.name}-${file.size}-${Math.random().toString(36).slice(2)}`;
      const problem = fileProblem(file, { accept, maxBytes });
      setQueue((current) => [...current, { id, name: file.name, size: file.size, phase: problem ? 'refused' : 'starting', progress: 0, error: problem }]);
      if (problem) continue;
      uploadFile({
        files,
        file,
        onPhase: (phase) => update(id, { phase }),
        onProgress: (progress) => update(id, { progress }),
      })
        .then((ready) => {
          update(id, { phase: 'ready', progress: 1 });
          onUploaded?.(ready);
          window.setTimeout(() => setQueue((current) => current.filter((item) => item.id !== id)), 2500);
        })
        .catch((cause) => update(id, { phase: 'refused', error: cause.message }));
    }
  };

  const label = { starting: 'Preparing…', uploading: 'Uploading…', checking: 'Checking…', ready: 'Ready', refused: 'Not uploaded' };

  return (
    <div className={compact ? 'fl-drop is-compact' : 'fl-drop'}>
      <div
        className={over ? 'fl-drop__zone is-over' : 'fl-drop__zone'}
        role="button"
        tabIndex={0}
        aria-label="Upload files"
        onClick={() => inputRef.current?.click()}
        onKeyDown={(event) => (event.key === 'Enter' || event.key === ' ') && (event.preventDefault(), inputRef.current?.click())}
        onDragOver={(event) => {
          event.preventDefault();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={(event) => {
          event.preventDefault();
          setOver(false);
          start(event.dataTransfer.files);
        }}
      >
        <span className="fl-drop__icon" aria-hidden="true">⬆</span>
        <span className="fl-drop__text">
          <strong>{compact ? 'Upload a file' : 'Drop files here, or choose files'}</strong>
          <span>
            {accept.filter((ext) => ext !== 'jpeg').map((ext) => ext.toUpperCase()).join(', ')}, up to {formatBytes(maxBytes)} each
          </span>
        </span>
        <input
          ref={inputRef}
          type="file"
          hidden
          multiple={multiple}
          accept={acceptAttribute(accept)}
          onChange={(event) => {
            start(event.target.files);
            event.target.value = '';
          }}
        />
      </div>
      {queue.length ? (
        <ul className="fl-queue" aria-live="polite">
          {queue.map((item) => (
            <li key={item.id} className={`fl-queue__item is-${item.phase}`}>
              <span className="fl-queue__name">{item.name}</span>
              <span className="fl-queue__state">{item.phase === 'refused' ? item.error : label[item.phase]}</span>
              {item.phase !== 'refused' ? (
                <span className="fl-queue__bar" aria-hidden="true">
                  <i style={{ transform: `scaleX(${item.phase === 'checking' || item.phase === 'ready' ? 1 : item.progress})` }} />
                </span>
              ) : (
                <button type="button" className="fl-queue__dismiss" aria-label="Dismiss" onClick={() => setQueue((current) => current.filter((entry) => entry.id !== item.id))}>
                  ×
                </button>
              )}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
__MAT_EOF__
echo "wrote apps/web/src/components/Files/FileDrop.jsx"

mkdir -p apps/web/src/components/Files/__checks__
cat > apps/web/src/components/Files/__checks__/filesModel.check.mjs <<'__MAT_EOF__'
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
__MAT_EOF__
echo "wrote apps/web/src/components/Files/__checks__/filesModel.check.mjs"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/SpaceMaterials.jsx <<'__MAT_EOF__'
import { useCallback, useEffect, useMemo, useState } from 'react';
import { createFilesApi, useCore } from '@classroom/core-client';
import FileDrop from '../Files/FileDrop.jsx';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { normalizeUrl } from './hubModel.js';

/**
 * Materials  (Community · Files)
 *
 * What a space keeps at hand: links to any website, and files — worksheets,
 * slides, pictures, recordings. Every member can add: paste a link, upload a
 * file, or pick one they uploaded before. Files open in a new tab (PDF,
 * pictures, video, audio, text) or download (Office documents). Moderators
 * pin; whoever added something, or a moderator, can remove it.
 */

function AddLink({ onAdd }) {
  const [title, setTitle] = useState('');
  const [url, setUrl] = useState('');
  const [error, setError] = useState(null);
  const normalized = normalizeUrl(url);
  return (
    <form
      className="hb-matadd__form"
      onSubmit={async (event) => {
        event.preventDefault();
        if (!title.trim() || !normalized) return;
        setError(null);
        try {
          await onAdd({ title: title.trim(), url: normalized });
          setTitle('');
          setUrl('');
        } catch (cause) {
          setError(cause?.detail ?? 'Not added.');
        }
      }}
    >
      <div className="hb-row2 hb-row2--even">
        <input className="hb-input" placeholder="Title, e.g. Fractions explained" maxLength={120} value={title} onChange={(event) => setTitle(event.target.value)} />
        <input className="hb-input" placeholder="Any web address, e.g. youtube.com/watch?v=…" maxLength={2000} value={url} onChange={(event) => setUrl(event.target.value)} aria-invalid={Boolean(url && !normalized)} />
      </div>
      {url && !normalized ? <p className="hb-error">That is not a web address.</p> : null}
      {error ? <p className="hb-error">{error}</p> : null}
      <div className="hb-inline">
        <button type="submit" className="btn btn--primary" disabled={!title.trim() || !normalized}>
          Add link
        </button>
      </div>
    </form>
  );
}

function FromLibrary({ onAdd }) {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const [items, setItems] = useState(null);
  const [q, setQ] = useState('');
  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      files
        .list({ q: q.trim() }, controller.signal)
        .then((result) => setItems(result.items))
        .catch(() => !controller.signal.aborted && setItems([]));
    }, 200);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [files, q]);
  return (
    <div className="hb-matadd__form">
      <input className="hb-input" type="search" placeholder="Search your uploads" value={q} onChange={(event) => setQ(event.target.value)} />
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? <p className="hb-muted">No uploads yet. Upload a file instead.</p> : null}
      <ul className="hb-pick">
        {(items ?? []).slice(0, 30).map((file) => (
          <li key={file.fileId}>
            <button type="button" onClick={() => onAdd({ fileId: file.fileId })}>
              <span aria-hidden="true">{iconFor(file.kind)}</span>
              <span className="hb-pick__name">{file.name}</span>
              <span className="hb-muted">{fileMeta(file)}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default function SpaceMaterials({ hub, space }) {
  const [data, setData] = useState(null);
  const [mode, setMode] = useState(null); // null · link · upload · library
  const [status, setStatus] = useState(null);

  const load = useCallback(async () => {
    try {
      setData(await hub.materials(space.spaceId));
    } catch {
      setData({ items: [], canCurate: false, canAdd: false });
    }
  }, [hub, space.spaceId]);

  useEffect(() => {
    load();
  }, [load]);

  const add = async (input) => {
    const added = await hub.addMaterial(space.spaceId, input);
    setStatus(`Added: ${added.title}`);
    setMode(null);
    await load();
  };

  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
  };

  return (
    <div>
      {data?.canAdd ? (
        <div className="hb-matadd">
          <div className="hb-segment" role="tablist" aria-label="Add a material">
            {[
              ['link', 'Link'],
              ['upload', 'Upload a file'],
              ['library', 'From my uploads'],
            ].map(([value, label]) => (
              <button key={value} type="button" role="tab" aria-selected={mode === value} className={mode === value ? 'is-on' : ''} onClick={() => setMode(mode === value ? null : value)}>
                {label}
              </button>
            ))}
          </div>
          {mode === 'link' ? <AddLink onAdd={add} /> : null}
          {mode === 'upload' ? (
            <FileDrop compact multiple={false} onUploaded={(file) => add({ fileId: file.fileId }).catch((cause) => setStatus(cause?.detail ?? 'Not added.'))} />
          ) : null}
          {mode === 'library' ? <FromLibrary onAdd={(input) => add(input).catch((cause) => setStatus(cause?.detail ?? 'Not added.'))} /> : null}
          {status ? <p className="hb-muted" role="status">{status}</p> : null}
        </div>
      ) : null}

      {data === null ? <p className="hb-muted">Loading…</p> : null}
      {data?.items.length === 0 ? <p className="hb-muted">No materials yet.{data.canAdd ? ' Add a link or a file above.' : ''}</p> : null}
      <ul className="hb-materials">
        {(data?.items ?? []).map((material) => {
          const isFile = material.type === 'file';
          const href = isFile ? fileHref(material.file?.openUrl) : material.url;
          const missing = isFile && !material.file?.available;
          return (
            <li key={material.materialId} className={material.pinned ? 'hb-material is-pinned' : 'hb-material'}>
              {missing ? (
                <span className="hb-material__link is-missing">
                  <span className="hb-material__icon" aria-hidden="true">🚫</span>
                  <span className="hb-material__text">
                    <span className="hb-material__title">{material.title}</span>
                    <span className="hb-muted">This file was deleted by its owner.</span>
                  </span>
                </span>
              ) : (
                <a className="hb-material__link" href={href} target="_blank" rel="noopener noreferrer">
                  <span className={`hb-material__icon hb-material__icon--${isFile ? material.file.kind : 'link'}`} aria-hidden="true">
                    {material.pinned ? '📌' : isFile ? iconFor(material.file.kind) : '🔗'}
                  </span>
                  <span className="hb-material__text">
                    <span className="hb-material__title">{material.title}</span>
                    <span className="hb-muted">
                      {isFile ? fileMeta(material.file) : material.host}
                      {material.addedBy ? `, added by ${material.addedBy}` : ''}
                      {material.note ? `: ${material.note}` : ''}
                    </span>
                  </span>
                  <span className="hb-material__open" aria-hidden="true">↗</span>
                </a>
              )}
              <span className="hb-inline">
                {data.canCurate ? (
                  <button type="button" className="hb-link" onClick={() => act(() => hub.pinMaterial(material.materialId, !material.pinned))}>
                    {material.pinned ? 'Unpin' : 'Pin'}
                  </button>
                ) : null}
                {material.canRemove ? (
                  <button type="button" className="hb-link hb-link--danger" onClick={() => window.confirm('Remove this material from the space?') && act(() => hub.removeMaterial(material.materialId))}>
                    Remove
                  </button>
                ) : null}
              </span>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
__MAT_EOF__
echo "wrote apps/web/src/components/Hub/SpaceMaterials.jsx"

mkdir -p apps/web/src/components/Files
cat > apps/web/src/components/Files/files.css <<'__MAT_EOF__'
/* Uploading files — see components/Files/FileDrop.jsx.
   Neutral tones and the app's colour variables, so it fits the app's look. */

.fl-drop { display: grid; gap: 10px; }
.fl-drop__zone {
  display: flex; align-items: center; gap: 16px; padding: 22px 24px; border-radius: 18px;
  border: 2px dashed rgba(127, 140, 140, 0.45); background: rgba(127, 140, 140, 0.06); cursor: pointer;
  transition: border-color 0.25s ease, background-color 0.25s ease, transform 0.35s cubic-bezier(0.16, 1, 0.3, 1);
}
.fl-drop__zone:hover, .fl-drop__zone:focus-visible { border-color: var(--color-accent, #5a7bf2); background: rgba(90, 123, 242, 0.08); outline: none; }
.fl-drop__zone.is-over { border-color: var(--color-accent, #5a7bf2); background: rgba(90, 123, 242, 0.14); transform: scale(1.01); }
.fl-drop__icon { display: grid; place-items: center; width: 46px; height: 46px; border-radius: 14px; background: rgba(90, 123, 242, 0.18); color: var(--color-accent, #5a7bf2); font-size: 20px; font-weight: 800; flex: 0 0 auto; }
.fl-drop__text { display: grid; gap: 2px; }
.fl-drop__text strong { font-size: 16px; }
.fl-drop__text span { font-size: 13px; color: var(--color-muted, #a8bcb9); }
.fl-drop.is-compact .fl-drop__zone { padding: 14px 16px; }
.fl-drop.is-compact .fl-drop__icon { width: 38px; height: 38px; font-size: 17px; }

.fl-queue { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.fl-queue__item {
  display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 4px 12px; align-items: center; padding: 10px 14px; border-radius: 12px;
  background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13));
  animation: fl-in 0.35s cubic-bezier(0.16, 1, 0.3, 1) both;
}
.fl-queue__name { font-weight: 700; font-size: 14.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.fl-queue__state { font-size: 13px; color: var(--color-muted, #a8bcb9); }
.fl-queue__item.is-ready .fl-queue__state { color: #3fbf8f; font-weight: 700; }
.fl-queue__item.is-refused { grid-template-columns: minmax(0, 1fr) auto auto; border-color: rgba(229, 72, 77, 0.55); }
.fl-queue__item.is-refused .fl-queue__state { color: #ef6b6f; }
.fl-queue__bar { grid-column: 1 / -1; height: 4px; border-radius: 2px; background: rgba(127, 140, 140, 0.2); overflow: hidden; }
.fl-queue__bar i { display: block; height: 100%; background: var(--color-accent, #5a7bf2); transform-origin: left; transition: transform 0.3s ease; }
.fl-queue__item.is-checking .fl-queue__bar i { animation: fl-pulse 1.2s ease-in-out infinite; }
.fl-queue__dismiss { border: 0; background: none; font-size: 18px; cursor: pointer; color: var(--color-muted, #a8bcb9); }
@keyframes fl-in { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
@keyframes fl-pulse { 50% { opacity: 0.45; } }

@media (max-width: 620px) { .fl-drop__zone { padding: 16px; } }
@media (prefers-reduced-motion: reduce) {
  .fl-queue__item { animation: none; }
  .fl-drop__zone, .fl-queue__bar i { transition: none; }
}
__MAT_EOF__
echo "wrote apps/web/src/components/Files/files.css"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/hub.css <<'__MAT_EOF__'
/* Community — see pages/CommunityPage.jsx.
   Uses the app's colour variables (theme.css), so it follows the app's look,
   and adds the community's own structure: a rail, rows, posts, a composer. */

.hb { display: grid; grid-template-columns: 260px minmax(0, 1fr); gap: 32px; align-items: start; max-width: 1180px; margin: 0 auto; }
.hb-main { min-width: 0; animation: hb-in 0.5s cubic-bezier(0.16, 1, 0.3, 1) both; }
@keyframes hb-in { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
@media (max-width: 900px) { .hb { grid-template-columns: minmax(0, 1fr); gap: 16px; } }
@media (prefers-reduced-motion: reduce) { .hb-main { animation: none; } }

.hb-muted { color: var(--color-muted, #a8bcb9); font-size: 14px; }
.hb-error { color: #ff9b91; font-size: 14px; margin: 4px 0 0; }
.hb-label { display: block; font-weight: 700; font-size: 15px; }
.hb-inline { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.hb-note { padding: 12px 14px; border-radius: 12px; background: rgba(255, 213, 74, 0.1); color: #ffe38a; font-size: 14.5px; }
.hb-link { border: 0; padding: 0; background: none; color: #9db4ff; font: inherit; font-size: 14px; cursor: pointer; text-decoration: none; }
.hb-link:hover { text-decoration: underline; text-underline-offset: 3px; }
.hb-link--quiet { color: var(--color-muted, #a8bcb9); }
.hb-link--danger { color: #ff9b91; }
.hb-link:disabled { opacity: 0.5; cursor: default; }
.hb-anon { font-style: italic; color: var(--color-muted, #a8bcb9); }
.hb :where(p, h1, h2, span) a:not([class]) { color: #9db4ff; text-underline-offset: 3px; }
.hb .page, .hb { min-width: 0; }

.hb-input { width: 100%; box-sizing: border-box; padding: 10px 12px; border-radius: 12px; border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); background: var(--color-surface-2, #2f4f57); color: inherit; font: inherit; font-size: 15px; }
.hb-input--title { font-size: 17px; font-weight: 700; }
.hb-input--small { width: auto; padding: 6px 8px; font-size: 13px; }
textarea.hb-input { resize: vertical; line-height: 1.5; }

.hb-head { margin-bottom: 18px; }
.hb-head h1 { margin: 0 0 4px; font-size: clamp(26px, 3vw, 34px); }
.hb-head .hb-muted { margin: 0; font-size: 15px; }

/* ---------------- rail */
.hb-rail { position: sticky; top: 86px; display: flex; flex-direction: column; gap: 6px; }
.hb-rail__places { display: flex; flex-direction: column; gap: 2px; }
.hb-place { display: flex; justify-content: space-between; align-items: center; padding: 10px 14px; border-radius: 12px; color: var(--color-muted, #a8bcb9); text-decoration: none; font-weight: 700; transition: background-color 0.3s ease, color 0.2s ease; }
.hb-place:hover { background: rgba(238, 242, 238, 0.06); color: var(--color-text, #eef4f2); }
.hb-place.is-on { background: rgba(238, 242, 238, 0.11); color: var(--color-text, #eef4f2); }
.hb-place--new { color: #ffd54a; }
.hb-count { min-width: 22px; padding: 1px 7px; border-radius: 999px; background: #ffd54a; color: #2a2206; font-size: 12px; text-align: center; }
.hb-rail__head { margin: 18px 14px 4px; font-size: 13px; font-weight: 700; color: var(--color-muted, #a8bcb9); }
.hb-rail__empty { margin: 4px 14px; }
.hb-rail__spaces { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.hb-spacelink { display: flex; align-items: center; gap: 10px; padding: 7px 10px; border-radius: 12px; color: var(--color-text, #eef4f2); text-decoration: none; transition: background-color 0.3s ease; }
.hb-spacelink:hover { background: rgba(238, 242, 238, 0.06); }
.hb-spacelink.is-on { background: rgba(238, 242, 238, 0.11); }
.hb-spacelink__name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14.5px; }
.hb-dot { width: 8px; height: 8px; border-radius: 50%; background: #ffd54a; flex: 0 0 auto; }
@media (max-width: 900px) {
  .hb-rail { position: static; }
  .hb-rail__places { flex-direction: row; overflow-x: auto; }
  .hb-place { white-space: nowrap; }
  .hb-rail__head, .hb-rail__spaces, .hb-rail__empty { display: none; }
}

.hb-mark { display: inline-grid; place-items: center; width: 30px; height: 30px; border-radius: 9px; flex: 0 0 auto; font-weight: 800; font-size: 15px; color: #13262b; }
.hb-mark--topic { background: #8cc8ff; }
.hb-mark--study { background: #ffd54a; }
.hb-mark--class { background: #7fd6b4; }
.hb-mark--big { width: 44px; height: 44px; border-radius: 13px; font-size: 20px; }
.hb-mark--huge { width: 64px; height: 64px; border-radius: 18px; font-size: 30px; }

/* ---------------- home */
.hb-tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 12px; margin: 8px 0 28px; }
.hb-tile { display: flex; flex-direction: column; gap: 6px; padding: 16px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); color: inherit; text-decoration: none; transition: transform 0.35s cubic-bezier(0.16, 1, 0.3, 1), border-color 0.25s ease; }
.hb-tile:hover { transform: translateY(-2px); border-color: rgba(214, 232, 227, 0.28); }
.hb-tile__name { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hb-block { margin-top: 26px; }
.hb-block__title { margin: 0 0 10px; font-size: 18px; }
.hb-empty { max-width: 560px; padding: 32px; border-radius: 20px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); display: grid; gap: 12px; }
.hb-empty__title { margin: 0; font: 780 26px/1.15 'Bricolage Grotesque', var(--font-sans, system-ui); }

/* ---------------- lists of threads */
.hb-list { display: flex; flex-direction: column; gap: 8px; }
.hb-row { display: flex; gap: 16px; justify-content: space-between; padding: 16px 18px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); color: inherit; text-decoration: none; transition: border-color 0.25s ease, transform 0.35s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-row:hover { border-color: rgba(214, 232, 227, 0.28); transform: translateY(-1px); }
.hb-row.is-pinned { border-color: rgba(255, 213, 74, 0.35); }
.hb-row__main { min-width: 0; }
.hb-row__meta { margin: 0 0 4px; display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.hb-row__space { font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-row__title { margin: 0; font-weight: 700; font-size: 16.5px; line-height: 1.35; }
.hb-row__excerpt { margin: 4px 0 0; color: var(--color-muted, #a8bcb9); font-size: 14.5px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.hb-row__by { margin: 8px 0 0; font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-row__stats { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; flex: 0 0 auto; font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-stat strong { color: var(--color-text, #eef4f2); font-size: 15px; }
.hb-stat.is-mine strong { color: #ffd54a; }

.hb-badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; font-weight: 700; background: rgba(238, 242, 238, 0.1); color: var(--color-text, #eef4f2); margin-left: 6px; }
.hb-row__meta .hb-badge, .hb-post__head .hb-badge { margin-left: 0; }
.hb-badge--open { background: rgba(140, 200, 255, 0.18); color: #b8dcff; }
.hb-badge--done { background: rgba(127, 214, 180, 0.18); color: #9fe6c9; }
.hb-badge--pin { background: rgba(255, 213, 74, 0.16); color: #ffe38a; }
.hb-badge--warn { background: rgba(255, 155, 145, 0.16); color: #ffb3ab; }

/* ---------------- toolbars */
.hb-toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; margin: 6px 0 14px; }
.hb-segment { display: inline-flex; gap: 2px; padding: 3px; border-radius: 999px; background: rgba(238, 242, 238, 0.07); }
.hb-segment button { padding: 7px 14px; border: 0; border-radius: 999px; background: transparent; color: var(--color-muted, #a8bcb9); font: inherit; font-size: 14px; cursor: pointer; transition: background-color 0.3s ease, color 0.2s ease; }
.hb-segment button.is-on { background: rgba(238, 242, 238, 0.14); color: var(--color-text, #eef4f2); font-weight: 700; }
.hb-sort { display: inline-flex; align-items: center; gap: 8px; font-size: 14px; color: var(--color-muted, #a8bcb9); }
.hb-sort .hb-input { width: auto; }
.hb-search { flex: 1 1 260px; }
.hb-toolbar > select.hb-input { width: auto; }

/* ---------------- discover */
.hb-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 14px; }
.hb-card { display: flex; flex-direction: column; gap: 10px; padding: 18px; border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); }
.hb-card__top { display: flex; gap: 12px; align-items: center; }
.hb-card__top p { margin: 0; }
.hb-card__name { font-weight: 800; font-size: 17px; }
.hb-card__text { margin: 0; font-size: 14.5px; }
.hb-card__foot { margin-top: auto; display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; }
.hb-tags { margin: 0; display: flex; flex-wrap: wrap; gap: 6px; }
.hb-tag { padding: 3px 10px; border: 0; border-radius: 999px; background: rgba(238, 242, 238, 0.08); color: var(--color-muted, #a8bcb9); font: inherit; font-size: 13px; cursor: pointer; }
.hb-tag:hover { color: var(--color-text, #eef4f2); }
.hb-ask { display: grid; gap: 8px; width: 100%; }

/* ---------------- forms */
.hb-form { display: grid; gap: 18px; max-width: 680px; }
.hb-fieldset { margin: 0; padding: 18px; border-radius: 18px; border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); background: var(--color-surface, #27434a); display: grid; gap: 14px; }
.hb-fieldset legend { padding: 0 6px; font-weight: 800; }
.hb-field { display: grid; gap: 6px; }
.hb-row2 { display: grid; grid-template-columns: 90px 1fr; gap: 12px; }
.hb-field--emoji .hb-input { text-align: center; font-size: 22px; }
.hb-options { display: grid; gap: 8px; }
.hb-option { display: flex; gap: 12px; align-items: flex-start; padding: 12px 14px; border-radius: 14px; border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); cursor: pointer; transition: border-color 0.25s ease, background-color 0.25s ease; }
.hb-option.is-on { border-color: rgba(255, 213, 74, 0.6); background: rgba(255, 213, 74, 0.06); }
.hb-option input { margin-top: 4px; accent-color: #ffd54a; }
.hb-option .hb-muted { display: block; }
.hb-check { display: flex; gap: 12px; align-items: flex-start; cursor: pointer; }
.hb-check input { margin-top: 4px; width: 18px; height: 18px; accent-color: #ffd54a; }
.hb-check .hb-muted { display: block; }

/* ---------------- a space */
.hb-space__head { display: flex; gap: 16px; align-items: center; margin-bottom: 14px; }
.hb-space__title { flex: 1; min-width: 0; }
.hb-space__title h1 { margin: 0; font-size: clamp(26px, 3vw, 34px); overflow-wrap: anywhere; }
.hb-space__title p { margin: 2px 0 0; }
.hb-joinbox { display: grid; gap: 8px; padding: 16px; border-radius: 16px; background: rgba(140, 200, 255, 0.08); margin-bottom: 16px; }
.hb-joinbox .hb-inline .hb-input { flex: 1 1 240px; width: auto; }
.hb-tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); margin-bottom: 18px; overflow-x: auto; }
.hb-tab { padding: 10px 11px; border: 0; border-bottom: 2px solid transparent; background: none; color: var(--color-muted, #a8bcb9); font: inherit; font-weight: 700; font-size: 14.5px; cursor: pointer; white-space: nowrap; transition: color 0.2s ease, border-color 0.3s ease; }
.hb-tab.is-on { color: var(--color-text, #eef4f2); border-bottom-color: #ffd54a; }
.hb-panel { animation: hb-in 0.45s cubic-bezier(0.16, 1, 0.3, 1) both; }

.hb-starter { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 14px; }
.hb-starter__button { padding: 16px; border-radius: 16px; border: 1px dashed rgba(214, 232, 227, 0.25); background: transparent; color: var(--color-text, #eef4f2); font: inherit; font-weight: 700; cursor: pointer; transition: border-color 0.25s ease, background-color 0.25s ease; }
.hb-starter__button:hover { border-color: rgba(255, 213, 74, 0.6); background: rgba(255, 213, 74, 0.05); }
.hb-composer { display: grid; gap: 10px; padding: 16px; border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); margin-bottom: 16px; animation: hb-in 0.4s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-composer .hb-segment { justify-self: start; }

.hb-members { list-style: none; margin: 10px 0 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.hb-member { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 14px; background: var(--color-surface, #27434a); }
.hb-member__name { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; font-weight: 700; }
.hb-member__name .hb-badge { align-self: flex-start; margin-left: 0; }
.hb-member__actions { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.hb-avatar { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 50%; background: rgba(238, 242, 238, 0.12); font-weight: 800; flex: 0 0 auto; }

.hb-reports { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
.hb-reportcard { display: grid; gap: 6px; padding: 14px; border-radius: 14px; background: var(--color-surface, #27434a); border-left: 3px solid #ff9b91; }
.hb-reportcard p { margin: 0; }
.hb-report { display: grid; gap: 8px; padding: 10px; border-radius: 12px; background: rgba(0, 0, 0, 0.15); min-width: 240px; }

.hb-about { display: grid; gap: 16px; max-width: 640px; }
.hb-facts { margin: 0; display: grid; gap: 10px; }
.hb-facts div { display: grid; grid-template-columns: 140px 1fr; gap: 12px; }
.hb-facts dt { color: var(--color-muted, #a8bcb9); }
.hb-facts dd { margin: 0; }

/* ---------------- a thread */
.hb-thread { max-width: 820px; }
.hb-crumbs { margin: 0 0 12px; }
.hb-crumbs a { display: inline-flex; align-items: center; gap: 8px; color: var(--color-muted, #a8bcb9); text-decoration: none; font-weight: 700; }
.hb-crumbs a:hover { color: var(--color-text, #eef4f2); }
.hb-crumbs .hb-mark { width: 24px; height: 24px; border-radius: 7px; font-size: 13px; }
.hb-thread__title { margin: 4px 0 10px; font-size: clamp(24px, 3vw, 32px); line-height: 1.15; overflow-wrap: anywhere; }
.hb-thread__count { margin: 26px 0 10px; font-size: 16px; color: var(--color-muted, #a8bcb9); }
.hb-post { padding: 18px 20px; border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); margin-bottom: 10px; }
.hb-post--first { background: linear-gradient(180deg, rgba(238, 242, 238, 0.04), transparent 50%), var(--color-surface, #27434a); }
.hb-post.is-answer { border-color: rgba(127, 214, 180, 0.55); box-shadow: 0 0 0 3px rgba(127, 214, 180, 0.08); }
.hb-post__head { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; font-size: 14px; }
.hb-post__author { font-weight: 700; display: inline-flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.hb-post__body { margin-top: 10px; font-size: 16px; line-height: 1.65; overflow-wrap: anywhere; }
.hb-post__body p { margin: 0 0 10px; white-space: pre-wrap; }
.hb-post__body p:last-child { margin-bottom: 0; }
.hb-post__foot { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; margin-top: 12px; }
.hb-metoo { display: inline-flex; align-items: center; gap: 10px; padding: 7px 8px 7px 14px; border-radius: 999px; border: 1px solid rgba(214, 232, 227, 0.2); background: transparent; color: var(--color-text, #eef4f2); font: inherit; font-size: 14px; font-weight: 700; cursor: pointer; transition: background-color 0.3s ease, border-color 0.3s ease, transform 0.3s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-metoo:hover:not(:disabled) { border-color: rgba(255, 213, 74, 0.6); }
.hb-metoo:active:not(:disabled) { transform: scale(0.97); }
.hb-metoo.is-on { background: rgba(255, 213, 74, 0.14); border-color: rgba(255, 213, 74, 0.6); }
.hb-metoo:disabled { cursor: default; opacity: 0.8; }
.hb-metoo__count { min-width: 26px; padding: 2px 8px; border-radius: 999px; background: rgba(238, 242, 238, 0.12); text-align: center; }
.hb-metoo.is-on .hb-metoo__count { background: #ffd54a; color: #2a2206; }
.hb-composer--reply { margin-top: 18px; }

@media (max-width: 620px) {
  .hb-row { flex-direction: column; gap: 8px; }
  .hb-row__stats { flex-direction: row; align-items: center; gap: 12px; }
  .hb-starter { grid-template-columns: 1fr; }
  .hb-facts div { grid-template-columns: 1fr; gap: 2px; }
  .hb-space__head { flex-wrap: wrap; }
}
@media (prefers-reduced-motion: reduce) {
  .hb-panel, .hb-composer { animation: none; }
  .hb-row, .hb-tile, .hb-metoo { transition: none; }
}

/* ================================================================ part 2 */

/* Live now */
.hb-livebar { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 12px 16px; margin-bottom: 14px; border-radius: 14px; background: rgba(255, 107, 94, 0.12); border: 1px solid rgba(255, 107, 94, 0.3); }
.hb-livebar > span:nth-child(2) { flex: 1; min-width: 200px; }
.hb-livebar .btn { margin-left: auto; }
.hb-livedot { width: 10px; height: 10px; border-radius: 50%; background: #ff6b5e; box-shadow: 0 0 0 0 rgba(255, 107, 94, 0.6); animation: hb-pulse 1.8s ease-out infinite; flex: 0 0 auto; }
.hb-livedot.is-off { background: rgba(238, 242, 238, 0.3); animation: none; }
@keyframes hb-pulse { 0% { box-shadow: 0 0 0 0 rgba(255, 107, 94, 0.55); } 70% { box-shadow: 0 0 0 9px rgba(255, 107, 94, 0); } 100% { box-shadow: 0 0 0 0 rgba(255, 107, 94, 0); } }
.hb-block--live { margin-top: 0; }

/* Rooms */
.hb-dropin { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 16px; padding: 18px; margin-bottom: 16px; border-radius: 18px; background: linear-gradient(135deg, rgba(255, 213, 74, 0.1), rgba(140, 200, 255, 0.08)); border: 1px solid rgba(255, 213, 74, 0.25); }
.hb-dropin p { margin: 0; }
.hb-dropin .hb-muted { margin-top: 4px; max-width: 44em; }
.hb-roomlist { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.hb-roomitem { display: flex; align-items: center; gap: 14px; padding: 14px 16px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); }
.hb-roomitem.is-live { border-color: rgba(255, 107, 94, 0.35); }
.hb-roomitem__text { flex: 1; min-width: 0; display: grid; gap: 2px; }
.app a.btn.btn--tiny, .hb a.btn--tiny { padding: 5px 12px; font-size: 13px; }

/* Chat */
.hb-chat { display: flex; flex-direction: column; height: clamp(420px, calc(100vh - 360px), 720px); border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); overflow: hidden; }
.hb-chat__list { flex: 1; overflow-y: auto; padding: 16px 16px 8px; display: flex; flex-direction: column; gap: 10px; }
.hb-chat__empty { margin: auto; color: var(--color-muted, #a8bcb9); }
.hb-chat__day { align-self: center; margin: 6px 0; padding: 3px 12px; border-radius: 999px; background: rgba(238, 242, 238, 0.07); font-size: 12.5px; color: var(--color-muted, #a8bcb9); }
.hb-msggroup { display: flex; gap: 10px; align-items: flex-start; animation: hb-in 0.35s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-msggroup.is-mine { flex-direction: row-reverse; }
.hb-msggroup__body { display: flex; flex-direction: column; gap: 3px; max-width: min(78%, 560px); }
.hb-msggroup.is-mine .hb-msggroup__body { align-items: flex-end; }
.hb-msggroup__who { margin: 0 4px 2px; font-size: 13px; font-weight: 700; display: flex; gap: 8px; align-items: baseline; }
.hb-msggroup__who .hb-muted { font-size: 12px; font-weight: 400; }
.hb-msg { position: relative; display: flex; align-items: center; gap: 4px; }
.hb-msggroup.is-mine .hb-msg { flex-direction: row-reverse; }
.hb-msg__text { margin: 0; padding: 8px 12px; border-radius: 16px; background: rgba(238, 242, 238, 0.09); white-space: pre-wrap; overflow-wrap: anywhere; font-size: 15px; line-height: 1.45; }
.hb-msggroup.is-mine .hb-msg__text { background: var(--color-accent, #5a7bf2); color: #fff; }
.hb-msg__remove { opacity: 0; border: 0; background: none; color: var(--color-muted, #a8bcb9); font-size: 16px; cursor: pointer; padding: 2px 6px; border-radius: 6px; transition: opacity 0.2s ease; }
.hb-msg:hover .hb-msg__remove, .hb-msg__remove:focus-visible { opacity: 1; }
.hb-avatar--small { width: 28px; height: 28px; font-size: 13px; margin-top: 20px; }
.hb-chat__composer { display: flex; gap: 8px; align-items: flex-end; padding: 10px; border-top: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); background: rgba(0, 0, 0, 0.08); }
.hb-chat__composer .hb-input { flex: 1; resize: none; max-height: 140px; border-radius: 18px; }
.hb-chat > .hb-note, .hb-chat > .hb-error { margin: 8px 12px; }

/* Knowledge cards */
.hb-cardlist { display: grid; gap: 8px; }
.hb-kcard { border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); overflow: hidden; }
.hb-kcard.is-open { border-color: rgba(127, 214, 180, 0.4); }
.hb-kcard__head { width: 100%; display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 16px 18px; border: 0; background: none; color: inherit; font: inherit; text-align: start; cursor: pointer; }
.hb-kcard__title { font-weight: 700; font-size: 16.5px; }
.hb-kcard__title::before { content: '💡 '; }
.hb-kcard__chev { width: 10px; height: 10px; border-right: 2px solid currentColor; border-bottom: 2px solid currentColor; transform: rotate(45deg); transition: transform 0.45s cubic-bezier(0.16, 1, 0.3, 1); opacity: 0.6; flex: 0 0 auto; }
.hb-kcard.is-open .hb-kcard__chev { transform: rotate(-135deg); }
.hb-kcard__body { display: grid; grid-template-rows: 0fr; transition: grid-template-rows 0.5s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-kcard__body > div { overflow: hidden; padding: 0 18px; }
.hb-kcard.is-open .hb-kcard__body { grid-template-rows: 1fr; }
.hb-kcard.is-open .hb-kcard__body > div { padding-bottom: 16px; }
.hb-kcard__body p { margin: 0 0 10px; white-space: pre-wrap; line-height: 1.6; }
.hb-kcard__meta { font-size: 13px; color: var(--color-muted, #a8bcb9); }

/* Materials */
.hb-materials { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.hb-material { display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); }
.hb-material.is-pinned { border-color: rgba(255, 213, 74, 0.35); }
.hb-material__link { flex: 1; min-width: 0; display: flex; align-items: center; gap: 12px; color: inherit; text-decoration: none; }
.hb-material__link:hover .hb-material__title { text-decoration: underline; text-underline-offset: 3px; }
.hb-material__icon { display: grid; place-items: center; width: 38px; height: 38px; border-radius: 12px; background: rgba(238, 242, 238, 0.08); flex: 0 0 auto; }
.hb-material__text { min-width: 0; display: grid; gap: 2px; }
.hb-material__title { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hb-material__text .hb-muted { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hb-row2--even { grid-template-columns: 1fr 1fr; }
@media (max-width: 620px) { .hb-row2--even { grid-template-columns: 1fr; } }

/* Hidden solutions */
.hb-folded { position: relative; margin-top: 10px; border-radius: 14px; overflow: hidden; min-height: 132px; }
.hb-folded__veil { filter: blur(9px); opacity: 0.5; user-select: none; pointer-events: none; min-height: 132px; max-height: 160px; overflow: hidden; }
.hb-folded__cover { position: absolute; inset: 0; display: grid; place-content: center; justify-items: center; gap: 6px; text-align: center; background: rgba(20, 38, 44, 0.45); }
.hb-folded__cover p { margin: 0; }
.hb-savecard { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.hb-savecard .hb-input { min-width: 220px; }

@media (prefers-reduced-motion: reduce) {
  .hb-livedot, .hb-msggroup { animation: none; }
  .hb-kcard__body, .hb-kcard__chev { transition: none; }
}

/* Many tabs: they scroll sideways, and fade at the edge instead of being cut. */
.hb-tabs { scrollbar-width: none; mask-image: linear-gradient(90deg, #000 calc(100% - 28px), transparent); -webkit-mask-image: linear-gradient(90deg, #000 calc(100% - 28px), transparent); }
.hb-tabs::-webkit-scrollbar { display: none; }
.hb-tabs::after { content: ''; flex: 0 0 24px; }

/* ================================================================ part 3 */

/* Late-night nudge */
.hb-nudge { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 14px; background: rgba(140, 160, 255, 0.1); border: 1px solid rgba(140, 160, 255, 0.25); font-size: 14px; animation: hb-in 0.5s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-nudge__text { flex: 1; min-width: 200px; color: #d6deff; }
.hb-nudge.is-done { margin: 0; color: #d6deff; }
.hb-chat__nudge { padding: 0 10px 10px; }
.hb-chat__nudge:empty { display: none; }

/* Calm mode */
.hb-calm { display: flex; align-items: center; gap: 8px; margin: 10px 0; padding: 10px 14px; border-radius: 14px; background: rgba(127, 214, 180, 0.1); border: 1px solid rgba(127, 214, 180, 0.28); color: #bdeedb; font-size: 14.5px; }
.hb-calm--inline { margin: 0; padding: 4px 10px; font-size: 13px; }
.hb-chat__bar { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); background: rgba(0, 0, 0, 0.06); }

/* Badges and notifications */
.hb-badge--helper { background: rgba(255, 213, 74, 0.16); color: #ffe38a; }
.hb-badge--helper::before { content: '★ '; }
.hb-space__action { display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 10px; }
.hb-notify { display: inline-flex; align-items: center; gap: 6px; }

/* Log */
.hb-log { list-style: none; margin: 10px 0 0; padding: 0; display: grid; gap: 2px; }
.hb-log li { display: flex; justify-content: space-between; gap: 16px; padding: 10px 12px; border-radius: 12px; background: var(--color-surface, #27434a); font-size: 14.5px; }
.hb-log li .hb-muted { flex: 0 0 auto; }

/* Waiting until morning */
.hb-waiting { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.hb-waiting li { display: flex; align-items: center; gap: 12px; padding: 10px 14px; border-radius: 14px; background: rgba(140, 160, 255, 0.08); }
.hb-waiting__text { flex: 1; min-width: 0; display: grid; gap: 2px; }
.hb-waiting__text > span:first-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Study partners */
.hb-partners .hb-fieldset { margin-bottom: 18px; }
.hb-profile-line { margin: 0 0 18px; }
.hb-slots { display: grid; grid-template-columns: 86px repeat(7, minmax(30px, 1fr)); gap: 6px; align-items: center; max-width: 520px; }
.hb-slots__head { text-align: center; font-size: 12.5px; color: var(--color-muted, #a8bcb9); }
.hb-slots__row { font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-slot { height: 30px; border-radius: 9px; border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); background: rgba(238, 242, 238, 0.04); cursor: pointer; transition: background-color 0.25s ease, border-color 0.25s ease, transform 0.3s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-slot:hover { border-color: rgba(255, 213, 74, 0.5); }
.hb-slot.is-on { background: #ffd54a; border-color: #ffd54a; }
.hb-slot:active { transform: scale(0.94); }
.hb-avatar--big { width: 44px; height: 44px; font-size: 18px; }
.hb-avatar--partner { background: rgba(255, 213, 74, 0.25); }
.hb-reasons { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; font-size: 14px; }
.hb-reasons li { position: relative; padding-left: 22px; }
.hb-reasons li::before { content: '✓'; position: absolute; left: 2px; color: #7fd6b4; font-weight: 800; }
.hb-outgoing { margin-top: 18px; }

@media (prefers-reduced-motion: reduce) { .hb-nudge { animation: none; } .hb-slot { transition: none; } }
.hb-member__name .hb-muted { font-weight: 400; }
.hb-partners .hb-block + .hb-profile-line, .hb-partners .hb-block + .hb-fieldset { margin-top: 22px; }

/* ================================================================ materials: links and files */

.hb-matadd { display: grid; gap: 12px; padding: 16px; margin-bottom: 16px; border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, rgba(214, 232, 227, 0.13)); }
.hb-matadd .hb-segment { justify-self: start; }
.hb-matadd__form { display: grid; gap: 10px; animation: hb-in 0.35s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-pick { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; max-height: 260px; overflow-y: auto; }
.hb-pick button { width: 100%; display: grid; grid-template-columns: 26px minmax(0, 1fr) auto; align-items: center; gap: 10px; padding: 8px 10px; border: 0; border-radius: 10px; background: transparent; color: inherit; font: inherit; font-size: 14.5px; text-align: left; cursor: pointer; }
.hb-pick button:hover, .hb-pick button:focus-visible { background: rgba(238, 242, 238, 0.07); }
.hb-pick__name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 700; }
.hb-material__open { margin-left: auto; color: var(--color-muted, #a8bcb9); font-size: 16px; transition: transform 0.3s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-material__link:hover .hb-material__open { transform: translate(2px, -2px); }
.hb-material__icon--document { background: rgba(140, 170, 255, 0.16); }
.hb-material__icon--image { background: rgba(127, 214, 180, 0.16); }
.hb-material__icon--video { background: rgba(190, 150, 255, 0.16); }
.hb-material__icon--audio { background: rgba(255, 213, 74, 0.16); }
.hb-material__icon--text { background: rgba(127, 214, 180, 0.12); }
.hb-material__link.is-missing { opacity: 0.65; cursor: default; }
@media (prefers-reduced-motion: reduce) { .hb-matadd__form { animation: none; } .hb-material__open { transition: none; } }
__MAT_EOF__
echo "wrote apps/web/src/components/Hub/hub.css"

cat > .materials-patch.mjs <<'__MAT_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Materials with uploads — edits to files that stay otherwise untouched.
 * Every anchor must be found exactly once; otherwise nothing is written and
 * the installer stops.
 */

const plan = [
  {
    file: 'server/src/app.js',
    marker: 'filesRoutes',
    edits: [
      {
        name: 'import the files routes',
        regex: /^import\s+scheduledRoomsRoutes\s+from\s+['"]([^'"]*)scheduledRooms\.routes\.js['"];?[ \t]*\r?\n/m,
        replace: (m, dir) => `${m}import filesRoutes from '${dir}files.routes.js';\n`,
      },
      {
        name: 'mount them under /files',
        regex: /^([ \t]*)app\.use\(\s*['"]\/scheduled-rooms['"],\s*scheduledRoomsRoutes\s*\);[^\n]*\r?\n/m,
        replace: (m, indent) => `${m}${indent}app.use('/files', filesRoutes); // Files and Media\n`,
      },
    ],
  },
  {
    file: 'packages/core-client/src/index.ts',
    marker: 'filesApi',
    edits: [
      {
        name: 'export the files API',
        find: "export * from './api/hubApi.js';\n",
        replace: "export * from './api/hubApi.js';\nexport * from './api/filesApi.js';\n",
      },
    ],
  },
  {
    file: 'apps/web/vite.config.ts',
    marker: "'/s3'",
    edits: [
      {
        name: 'development: uploads to local MinIO through the dev server',
        find:
          "        '/socket.io': {\n" +
          '          target: devApiTarget,\n' +
          '          ws: true,\n' +
          '          changeOrigin: true,\n' +
          '        },\n',
        replace:
          "        '/socket.io': {\n" +
          '          target: devApiTarget,\n' +
          '          ws: true,\n' +
          '          changeOrigin: true,\n' +
          '        },\n' +
          '        /**\n' +
          '         * Files: signed upload URLs point at local MinIO (localhost:9000), which a\n' +
          '         * browser outside this machine cannot reach. The page sends them here\n' +
          "         * instead; the Host header is rewritten to MinIO's, so the signature holds.\n" +
          '         * Set VITE_DEV_S3_TARGET to the same address as S3_ENDPOINT.\n' +
          '         */\n' +
          "        '/s3': {\n" +
          "          target: env.VITE_DEV_S3_TARGET || 'http://localhost:9000',\n" +
          '          changeOrigin: true,\n' +
          "          rewrite: (path) => path.replace(/^\\/s3(?=\\/|$)/, '') || '/',\n" +
          '        },\n',
      },
    ],
  },
];

const count = (src, edit) => {
  if (edit.regex) {
    const global = new RegExp(edit.regex.source, edit.regex.flags.includes('g') ? edit.regex.flags : `${edit.regex.flags}g`);
    return [...src.matchAll(global)].length;
  }
  return src.split(edit.find).length - 1;
};
const apply = (src, edit) => (edit.regex ? src.replace(edit.regex, edit.replace) : src.replace(edit.find, () => edit.replace));

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed in any patched file.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = count(src, edit);
    const expected = edit.count ?? 1;
    if (n !== expected) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor ${expected}×, found ${n}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = apply(src, edit);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__MAT_EOF__
node .materials-patch.mjs
rm -f .materials-patch.mjs

# Development: the browser uploads to local MinIO through the Vite dev server
# (/s3). The proxy must target the same address the API signs for (S3_ENDPOINT).
S3_ENDPOINT_VALUE=$(grep -E '^S3_ENDPOINT=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
if [ -n "$S3_ENDPOINT_VALUE" ] && echo "$S3_ENDPOINT_VALUE" | grep -qE '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)(:[0-9]+)?/?$'; then
  touch apps/web/.env.local
  grep -v '^VITE_DEV_S3_TARGET=' apps/web/.env.local > apps/web/.env.local.tmp || true
  echo "VITE_DEV_S3_TARGET=${S3_ENDPOINT_VALUE%/}" >> apps/web/.env.local.tmp
  mv apps/web/.env.local.tmp apps/web/.env.local
  echo "dev uploads go through Vite to ${S3_ENDPOINT_VALUE%/} (apps/web/.env.local)"
elif [ -n "$S3_ENDPOINT_VALUE" ]; then
  echo "note: S3_ENDPOINT is $S3_ENDPOINT_VALUE — not a local address, so uploads go there directly"
  echo "      (that storage must allow PUT from the app's address: CORS)."
fi

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo "A file did not pass its check (see above). Undo with: bash materials-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs server/test/hub/*.check.mjs server/test/files/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs \
  apps/web/src/components/Landing/__checks__/*.check.mjs apps/web/src/components/Auth/__checks__/*.check.mjs \
  apps/web/src/components/Hub/__checks__/*.check.mjs apps/web/src/components/Files/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .materials-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .materials-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .materials-test.log
else
  cat .materials-test.log
  rm -f .materials-test.log
  echo "The rule checks failed (see above). Undo with: bash materials-install.sh --restore" >&2
  exit 1
fi

echo "--- database"
if SERVICE_ROLE=api npm run db:migrate; then
  touch server/src/server.js
  echo
  echo "Materials with uploads are installed and migration 029 applied."
  echo "The API restarts on its own; Vite restarts because its config changed."
  echo "Reload the browser tabs with Ctrl+Shift+R, then open a space → Materials."
  AV_MODE=$(grep -E '^ANTIVIRUS_MODE=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  if [ "${AV_MODE:-disabled}" = "clamav" ]; then
    echo "Note: ANTIVIRUS_MODE=clamav — uploads are scanned by ClamAV, so it has to run:"
    echo "      npm run dev:infra:full   (starts it with the other containers; the first start takes a few minutes)."
  fi
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh or npm run dev:infra), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  exit 1
fi