// classroom-app/server/src/identity/Profile.js
/**
 * Profiles  (F6)
 *
 * What a person shows to other people, and who is allowed to contact them.
 *
 * Separate from User.js because the two are read by different things at
 * different rates: the account is read by the auth path, the profile every time
 * anybody renders an avatar.
 *
 * Storage (009_profiles.sql): privacy lives in named columns, not in a jsonb
 * blob, because visibility and dm_policy carry check constraints —
 *
 *   dm_policy            anyone | shared-only | nobody
 *   visibility           tenant | shared-only | private
 *   show_presence        boolean
 *   show_read_receipts   boolean
 *
 * The contract spells the middle DM setting 'shared-context'; it is mapped at
 * this boundary in both directions. Display name and email live on `users`,
 * the avatar is `profiles.avatar_asset_id`. Blocks are `blocks(user_id,
 * blocked_id)`.
 *
 * Whether someone may message someone else is decided in exactly one place,
 * messaging/ConversationService.canMessage. profile.routes asks it and puts the
 * answer on the public profile, so the button and the send always agree.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'profiles' });

export const DM_POLICIES = ['anyone', 'shared-context', 'nobody'];

const TO_CONTRACT = { anyone: 'anyone', 'shared-only': 'shared-context', nobody: 'nobody' };
const TO_DB = { anyone: 'anyone', 'shared-context': 'shared-only', shared: 'shared-only', 'shared-only': 'shared-only', nobody: 'nobody' };

/** Privacy fields the contract has that the table does not store: fixed values. */
const FIXED_PRIVACY = { showEmail: 'nobody', showCourses: 'members', discoverable: true };

const DEFAULT_NOTIFICATIONS = {
  dmPush: true,
  dmEmail: false,
  mentionPush: true,
  communityDigest: true,
  lessonReminders: true,
  quietHours: null,
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

const privacyOf = (row) => ({
  ...FIXED_PRIVACY,
  dmPolicy: TO_CONTRACT[row.dm_policy] ?? 'shared-context',
  showPresence: row.show_presence !== false,
  sendReadReceipts: row.show_read_receipts !== false,
  visibility: row.visibility ?? 'tenant',
});

const rowToPublic = (row) => ({
  userId: row.user_id,
  displayName: row.display_name,
  handle: row.handle,
  avatarUrl: null,
  headline: row.headline ?? null,
  bio: row.bio ?? null,
  links: row.links ?? [],
  role: row.role,
  presence: 'offline', // filled in from Redis by the caller
  lastSeenAt: iso(row.last_seen_at),
  canMessage: false, // computed per viewer by profile.routes
  isBlockedByViewer: false,
  sharedSpaceCount: 0,
  joinedAt: iso(row.created_at),
});

const rowToOwn = (row) => ({
  ...rowToPublic(row),
  canMessage: undefined,
  isBlockedByViewer: undefined,
  sharedSpaceCount: undefined,
  email: row.email,
  emailVerified: Boolean(row.email_verified),
  locale: row.locale,
  timeZone: row.time_zone,
  privacy: privacyOf(row),
  notifications: { ...DEFAULT_NOTIFICATIONS },
  createdAt: iso(row.created_at),
  updatedAt: iso(row.updated_at ?? row.created_at),
});

const SELECT = `
  SELECT p.*, u.email, (u.email_verified_at IS NOT NULL) AS email_verified, u.display_name,
         u.role, u.locale, u.time_zone, u.created_at, u.last_seen_at
    FROM profiles p JOIN users u ON u.id = p.user_id
`;

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

export const getOwn = async (userId) => {
  const { rows } = await pool.query(`${SELECT} WHERE p.user_id = $1`, [userId]);
  return rows[0] ? rowToOwn(rows[0]) : null;
};

/**
 * The public view for one viewer: block state and shared spaces in one query.
 * `canMessage` is left false here; profile.routes fills it from
 * ConversationService.canMessage.
 */
export const getPublic = async ({ userId, viewerId }) => {
  const { rows } = await pool.query(
    `${SELECT}
      WHERE p.user_id = $1 AND u.deleted_at IS NULL`,
    [userId],
  );
  const row = rows[0];
  if (!row) return null;

  const { rows: ctx } = await pool.query(
    `SELECT EXISTS (SELECT 1 FROM blocks b WHERE b.user_id = $2 AND b.blocked_id = $1) AS blocked_by_viewer`,
    [userId, viewerId],
  );

  let sharedSpaces = 0;
  try {
    const { rows: shared } = await pool.query(
      `SELECT count(*)::int AS n
         FROM space_memberships a
         JOIN space_memberships b ON b.space_id = a.space_id
        WHERE a.user_id = $1 AND b.user_id = $2`,
      [viewerId, userId],
    );
    sharedSpaces = shared[0]?.n ?? 0;
  } catch (cause) {
    log.warn({ err: cause }, 'shared space count unavailable');
  }

  return {
    ...rowToPublic(row),
    // Read by applyVisibility() and removed there; never sent as is.
    visibility: row.visibility ?? 'tenant',
    isBlockedByViewer: Boolean(ctx[0]?.blocked_by_viewer),
    sharedSpaceCount: sharedSpaces,
    // Presence is hidden when they have switched it off, never inflated.
    presence: 'offline',
  };
};

/**
 * What a viewer may see of a profile, by the owner's "Who can see your
 * profile" setting:
 *
 *   tenant        everyone in the organisation sees headline, bio and links
 *   shared-only   only people who share a course, space or live lesson with
 *                 them (and teachers); everyone else sees the name only
 *   private       the name only, for everyone
 *
 * The name, role and the Message button stay visible in every case.
 */
export const applyVisibility = (profile, { sharesContext = false } = {}) => {
  const { visibility = 'tenant', ...rest } = profile;
  const full = visibility === 'tenant' || (visibility === 'shared-only' && sharesContext);
  return full ? rest : { ...rest, headline: null, bio: null, links: [] };
};

export const getByHandle = async ({ handle, viewerId }) => {
  const { rows } = await pool.query(`SELECT user_id FROM profiles WHERE handle = lower($1)`, [handle]);
  return rows[0] ? getPublic({ userId: rows[0].user_id, viewerId }) : null;
};

/**
 * Mention autocomplete. Never returns someone the viewer is blocked with in
 * either direction.
 */
export const search = async ({ q, viewerId, scopeId = null, limit = 10 }) => {
  const { rows } = await pool.query(
    `SELECT p.user_id, p.handle, u.display_name
       FROM profiles p JOIN users u ON u.id = p.user_id
      WHERE u.status = 'active'
        AND u.deleted_at IS NULL
        AND p.user_id <> $2
        AND u.tenant_id = (SELECT tenant_id FROM users WHERE id = $2)
        AND (p.handle ILIKE $1 || '%' OR u.display_name ILIKE '%' || $1 || '%')
        AND NOT EXISTS (SELECT 1 FROM blocks b
                         WHERE (b.user_id = $2 AND b.blocked_id = p.user_id)
                            OR (b.user_id = p.user_id AND b.blocked_id = $2))
        AND ($3::uuid IS NULL OR EXISTS (
              SELECT 1 FROM space_memberships m
               WHERE m.space_id = $3 AND m.user_id = p.user_id))
      ORDER BY (p.handle ILIKE $1 || '%') DESC, u.display_name ASC
      LIMIT $4`,
    [q, viewerId, scopeId, limit],
  );

  return {
    items: rows.map((row) => ({
      userId: row.user_id,
      handle: row.handle,
      displayName: row.display_name,
      avatarUrl: null,
      presence: 'offline',
    })),
  };
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

export const createForUser = async ({ userId, displayName }) => {
  const handle = await uniqueHandle(displayName);
  await pool.query(
    `INSERT INTO profiles (user_id, handle) VALUES ($1, $2) ON CONFLICT (user_id) DO NOTHING`,
    [userId, handle],
  );
  return getOwn(userId);
};

const slugifyHandle = (name) =>
  String(name ?? '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9_]/g, '')
    .slice(0, 24) || 'user';

const uniqueHandle = async (displayName) => {
  const base = slugifyHandle(displayName);
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const candidate = attempt === 0 ? base : `${base}${Math.floor(Math.random() * 9_000) + 1_000}`;
    const { rows } = await pool.query(`SELECT 1 FROM profiles WHERE handle = $1`, [candidate]);
    if (rows.length === 0) return candidate;
  }
  return `${base}${Date.now().toString(36)}`;
};

export const update = async ({ userId, patch }) => {
  // display_name, locale and time zone live on the user row; the rest on the profile.
  if (patch.displayName !== undefined) {
    const Users = await import('./User.js');
    await Users.update({ userId, patch: { displayName: patch.displayName } });
  }
  if (patch.locale !== undefined || patch.timeZone !== undefined) {
    await pool.query(
      `UPDATE users SET locale = coalesce($2, locale), time_zone = coalesce($3, time_zone), updated_at = now()
        WHERE id = $1`,
      [userId, patch.locale ?? null, patch.timeZone ?? null],
    );
  }

  const columns = { handle: 'handle', headline: 'headline', bio: 'bio', links: 'links' };
  const sets = [];
  const params = [];

  for (const [key, column] of Object.entries(columns)) {
    if (patch[key] === undefined) continue;
    const value = key === 'handle' ? String(patch[key]).toLowerCase() : patch[key];
    params.push(key === 'links' ? JSON.stringify(value) : value);
    sets.push(`${column} = $${params.length}${key === 'links' ? '::jsonb' : ''}`);
  }

  if (patch.handle !== undefined) {
    const { rows } = await pool.query(
      `SELECT 1 FROM profiles WHERE handle = lower($1) AND user_id <> $2`,
      [patch.handle, userId],
    );
    if (rows.length > 0) throw Object.assign(new Error('that handle is taken'), { code: 'conflict' });
  }

  if (sets.length > 0) {
    params.push(userId);
    await pool.query(
      `UPDATE profiles SET ${sets.join(', ')}, updated_at = now() WHERE user_id = $${params.length}`,
      params,
    );
  }

  return getOwn(userId);
};

/**
 * Writes the privacy columns. Accepts the contract's names (dmPolicy,
 * showPresence, sendReadReceipts, visibility) and returns the full privacy
 * block. "Receive private messages: off" is dmPolicy 'nobody'.
 */
export const updatePrivacy = async ({ userId, patch }) => {
  const sets = [];
  const params = [];
  const set = (column, value) => {
    params.push(value);
    sets.push(`${column} = $${params.length}`);
  };

  if (patch.dmPolicy !== undefined) {
    const policy = TO_DB[patch.dmPolicy];
    if (!policy) throw Object.assign(new Error('unknown DM setting'), { code: 'validation_failed' });
    set('dm_policy', policy);
  }
  if (patch.visibility !== undefined) set('visibility', patch.visibility === 'shared' ? 'shared-only' : patch.visibility);
  if (patch.showPresence !== undefined) set('show_presence', Boolean(patch.showPresence));
  if (patch.sendReadReceipts !== undefined) set('show_read_receipts', Boolean(patch.sendReadReceipts));
  if (patch.readReceipts !== undefined) set('show_read_receipts', Boolean(patch.readReceipts));

  if (sets.length > 0) {
    params.push(userId);
    await pool.query(
      `UPDATE profiles SET ${sets.join(', ')}, updated_at = now() WHERE user_id = $${params.length}`,
      params,
    );
  }

  const own = await getOwn(userId);
  return own?.privacy ?? null;
};

/** Notification preferences have no storage yet; the defaults are returned unchanged. */
export const updateNotifications = async () => ({ ...DEFAULT_NOTIFICATIONS });

export const setAvatar = async ({ userId, assetId }) => {
  const { getAssetsForOwner } = await import('../media/UploadService.js');
  const [asset] = await getAssetsForOwner({ assetIds: [assetId], userId });

  if (!asset) throw Object.assign(new Error('unknown image'), { code: 'not_found' });
  if (asset.status !== 'ready') {
    throw Object.assign(new Error('that image is still processing'), { code: 'asset_not_ready' });
  }

  await pool.query(`UPDATE profiles SET avatar_asset_id = $2, updated_at = now() WHERE user_id = $1`, [userId, assetId]);
  return getOwn(userId);
};

// ---------------------------------------------------------------------------
// Preferences (021) — definition and validation in settings/preferences.js
// ---------------------------------------------------------------------------

export const getPreferences = async (userId) => {
  const { withDefaults } = await import('../settings/preferences.js');
  const { rows } = await pool.query(`SELECT preferences FROM profiles WHERE user_id = $1`, [userId]);
  return withDefaults(rows[0]?.preferences ?? {});
};

/**
 * Validates and merges one change. Room defaults are for teachers and owners
 * only: they decide how that person's lessons start.
 */
export const updatePreferences = async ({ userId, patch }) => {
  const { PreferencesPatchSchema, mergePatch, withDefaults, TEACHING_ROLES } = await import('../settings/preferences.js');

  const parsed = PreferencesPatchSchema.safeParse(patch ?? {});
  if (!parsed.success) {
    throw Object.assign(new Error('Unknown or invalid preference.'), { code: 'validation_failed' });
  }

  if (parsed.data.roomDefaults) {
    const { rows } = await pool.query(`SELECT role FROM users WHERE id = $1`, [userId]);
    if (!TEACHING_ROLES.has(rows[0]?.role)) {
      throw Object.assign(new Error('Only teachers can set lesson defaults.'), { code: 'forbidden' });
    }
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `SELECT preferences FROM profiles WHERE user_id = $1 FOR UPDATE`,
      [userId],
    );
    if (!rows[0]) throw Object.assign(new Error('No profile for this account.'), { code: 'not_found' });
    const next = mergePatch(rows[0].preferences ?? {}, parsed.data);
    await client.query(
      `UPDATE profiles SET preferences = $2::jsonb, updated_at = now() WHERE user_id = $1`,
      [userId, JSON.stringify(next)],
    );
    await client.query('COMMIT');
    return withDefaults(next);
  } catch (cause) {
    await client.query('ROLLBACK');
    throw cause;
  } finally {
    client.release();
  }
};

// ---------------------------------------------------------------------------
// Blocking (account-wide; the per-lesson block lives with the room)
// ---------------------------------------------------------------------------

/**
 * Mutual in effect: neither can message the other afterwards. Only the blocker
 * sees it in a list — telling somebody they have been blocked is how a block
 * becomes an escalation.
 */
export const block = async ({ userId, blockedUserId, reason = null }) => {
  if (userId === blockedUserId) {
    throw Object.assign(new Error('you cannot block yourself'), { code: 'validation_failed' });
  }

  await pool.query(
    `INSERT INTO blocks (user_id, blocked_id, reason)
     VALUES ($1, $2, $3) ON CONFLICT (user_id, blocked_id) DO NOTHING`,
    [userId, blockedUserId, reason],
  );

  log.info({ userId, blockedUserId }, 'user blocked');
  const { rows } = await pool.query(
    `SELECT b.blocked_id, b.reason, b.created_at, u.display_name
       FROM blocks b JOIN users u ON u.id = b.blocked_id
      WHERE b.user_id = $1 AND b.blocked_id = $2`,
    [userId, blockedUserId],
  );
  return toBlock(rows[0]);
};

export const unblock = async ({ userId, blockedUserId }) => {
  const { rowCount } = await pool.query(
    `DELETE FROM blocks WHERE user_id = $1 AND blocked_id = $2`,
    [userId, blockedUserId],
  );
  return rowCount > 0;
};

const toBlock = (row) => ({
  blockedUserId: row.blocked_id,
  blockedAt: iso(row.created_at),
  reason: row.reason ?? null,
  profile: { userId: row.blocked_id, displayName: row.display_name, avatarUrl: null },
});

export const listBlocks = async ({ userId, cursor = null, limit = 25 }) => {
  const params = [userId];
  let where = 'b.user_id = $1';

  if (cursor) {
    const [at, id] = Buffer.from(cursor, 'base64url').toString().split('|');
    params.push(at, id);
    where += ` AND (b.created_at, b.blocked_id) < ($2::timestamptz, $3::uuid)`;
  }
  params.push(limit + 1);

  const { rows } = await pool.query(
    `SELECT b.blocked_id, b.reason, b.created_at, u.display_name
       FROM blocks b JOIN users u ON u.id = b.blocked_id
      WHERE ${where} ORDER BY b.created_at DESC, b.blocked_id DESC LIMIT $${params.length}`,
    params,
  );

  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);
  const last = page.at(-1);

  return {
    items: page.map(toBlock),
    hasMore,
    nextCursor:
      hasMore && last
        ? Buffer.from(`${new Date(last.created_at).toISOString()}|${last.blocked_id}`).toString('base64url')
        : null,
  };
};

/** The check a send path can call. One query, either direction. */
export const isBlockedEitherWay = async ({ a, b }) => {
  const { rows } = await pool.query(
    `SELECT 1 FROM blocks
      WHERE (user_id = $1 AND blocked_id = $2)
         OR (user_id = $2 AND blocked_id = $1) LIMIT 1`,
    [a, b],
  );
  return rows.length > 0;
};

/**
 * The v6 pure rule, kept for callers that still import it. The rule that is
 * actually enforced is ConversationService.canMessage.
 */
export const canMessage = ({
  viewerId,
  targetId,
  dmPolicy = 'shared-context',
  blockedEitherWay = false,
  sharedContext = false,
  viewerIsModerator = false,
}) => {
  if (viewerId === targetId) return { allowed: false, reason: 'self' };
  if (blockedEitherWay) return { allowed: false, reason: 'blocked' };
  if (viewerIsModerator) return { allowed: true, reason: 'moderator' };
  if (dmPolicy === 'nobody') return { allowed: false, reason: 'dm_not_allowed' };
  if (dmPolicy === 'anyone') return { allowed: true };
  return sharedContext ? { allowed: true } : { allowed: false, reason: 'no_shared_context' };
};

export default {
  canMessage, getOwn, getPublic, getByHandle, search, createForUser, update,
  updatePrivacy, updateNotifications, setAvatar, block, unblock,
  getPreferences, updatePreferences,
  listBlocks, isBlockedEitherWay,
};
