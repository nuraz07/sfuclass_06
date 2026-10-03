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
import * as Library from './libraryRules.js';

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

export const list = async ({ viewer, q = null, kind = null, sort = Library.DEFAULT_SORT }) => {
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
      ORDER BY ${Library.orderBy(sort)} LIMIT 500`,
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

/**
 * Where one of my files is a material: the spaces, so Media can show it and
 * say before a delete what the delete also removes. Only the owner asks;
 * only the owner can have added it (HubExtras.addMaterial).
 */
export const usage = async ({ viewer, fileId }) => {
  const row = await ownFile(viewer, fileId);
  const { rows } = await pool.query(
    `SELECT m.id AS material_id, m.created_at AS added_at, s.id AS space_id, s.name AS space_name,
            to_jsonb(s) ->> 'emoji' AS space_emoji
       FROM space_materials m
       JOIN spaces s ON s.id = m.space_id
      WHERE m.file_id = $1 AND m.deleted_at IS NULL
      ORDER BY lower(s.name), m.created_at`,
    [row.id],
  );
  return { items: rows.map(Library.toUsage) };
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
               WHERE m.file_id = f.id AND m.deleted_at IS NULL AND (sm.user_id IS NOT NULL OR s.access = 'open'))
            OR EXISTS (
              -- Messages (032): a file sent in a chat, for everyone still in that chat.
              SELECT 1 FROM message_files mf
                JOIN messages msg ON msg.message_id = mf.message_id AND msg.deleted_at IS NULL
                JOIN conversation_participants cp ON cp.conversation_id = msg.conversation_id AND cp.user_id = $2 AND cp.left_at IS NULL
               WHERE mf.file_id = f.id)
            OR EXISTS (
              -- Community (033): a file sent in a space chat, for whoever can read that chat.
              SELECT 1 FROM space_message_files smf
                JOIN space_messages sm2 ON sm2.id = smf.message_id AND sm2.deleted_at IS NULL
                JOIN spaces s2 ON s2.id = sm2.space_id AND s2.tenant_id = $3
                LEFT JOIN space_memberships ms2 ON ms2.space_id = s2.id AND ms2.user_id = $2
               WHERE smf.file_id = f.id AND (ms2.user_id IS NOT NULL OR s2.access = 'open')))`,
    [fileId, viewer.userId, viewer.tenantId],
  );
  return rows.length > 0;
};

export const linkFor = async ({ viewer, fileId }) => {
  if (!(await canView({ viewer, fileId }))) fail('not_found', 'No such file');
  return { url: openPath(fileId) };
};

/** The storage answered that the object is not there (as opposed to not answering). */
const isMissingObject = (cause) =>
  ['NoSuchKey', 'NotFound'].includes(cause?.name) || cause?.Code === 'NoSuchKey' || cause?.$metadata?.httpStatusCode === 404;

/**
 * A file whose bytes are gone from storage (for example after the storage
 * was replaced) leaves the library and stops counting against the quota.
 * The row stays, with the reason; materials pointing at it show it as gone.
 */
const markMissing = async (row) => {
  await pool.query(
    `UPDATE files SET status = 'rejected', reject_reason = 'The stored file is missing.', updated_at = now()
      WHERE id = $1 AND status = 'ready'`,
    [row.id],
  );
  log.warn({ fileId: row.id, bucket: row.bucket, key: row.object_key }, 'stored object missing; file marked unavailable');
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
  let body;
  try {
    body = await Store.stream({ bucket: row.bucket, key: row.object_key, range });
  } catch (cause) {
    if (isMissingObject(cause)) {
      await markMissing(row);
      fail('not_found', 'This file is no longer in storage. Upload it again.');
    }
    log.error({ err: cause, fileId: row.id }, 'storage unavailable while opening a file');
    fail('unavailable', 'The file storage is not reachable right now. Try again in a moment.');
  }
  return { status: range ? 206 : 200, headers, body };
};

export default { limits, openPath, toView, createUpload, completeUpload, list, usage, rename, remove, canView, linkFor, open };
