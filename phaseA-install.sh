#!/usr/bin/env bash
# phaseA-install.sh — Settings, Phase A.
#
# Run from the project folder (the one containing server/, packages/ and apps/):
#   bash phaseA-install.sh
#
# Writes 18 files, patches 6 more, keeps a backup of every file it touches in
# .phaseA-backup/<timestamp>/, checks all of them, applies migration 021 and
# restarts the API.
# Undo: bash phaseA-install.sh --restore   (back to the state before the first install;
#       the preferences column added by 021 stays — it is unused without these files)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi
if [ ! -f apps/web/src/components/Chat/ChatRooms.jsx ] || ! grep -q "reactionsEnabled" server/src/classroom/Room.js; then
  echo "Parts 1–4 of the chat rework have to be installed first." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/021_profile_preferences.sql
  server/src/settings/preferences.js
  server/src/identity/Profile.js
  server/src/routes/profile.routes.js
  server/src/messaging/ConversationService.js
  packages/core-client/src/api/profileApi.ts
  apps/web/src/lib/preferences.js
  apps/web/src/pages/AppLayout.jsx
  apps/web/src/pages/SettingsPage.jsx
  apps/web/src/components/Settings/fields.jsx
  apps/web/src/components/Settings/settingsIndex.js
  apps/web/src/components/Settings/ProfileSettings.jsx
  apps/web/src/components/Settings/PrivacySettings.jsx
  apps/web/src/components/Settings/RegionSettings.jsx
  apps/web/src/components/Settings/LessonSettings.jsx
  apps/web/src/components/Settings/AppearanceSettings.jsx
  apps/web/src/components/Settings/TeachingSettings.jsx
  apps/web/src/components/Settings/settings.css
  apps/web/src/main.jsx
  apps/web/src/pages/ClassroomPage.jsx
  apps/web/src/components/Chat/ChatRooms.jsx
  server/src/classroom/Room.js
  server/src/classroom/RoomManager.js
  packages/core-client/src/state/useClassroom.ts
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .phaseA-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/021_profile_preferences.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  echo "Restored from $FIRST. The migration file 021 stays, because the database already has it."
  exit 0
fi

BACKUP=".phaseA-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/021_profile_preferences.sql <<'__PA_EOF__'
-- 021_profile_preferences.sql
--
-- Account-wide preferences that follow a person to every device: appearance,
-- date and time format, how they join a lesson, and — for teachers — the
-- defaults their new lessons start with.
--
-- One jsonb column rather than a column per setting: these are read together,
-- written one at a time, and change shape as the product grows. They carry no
-- constraint the database has to enforce; the server validates every key
-- (server/src/settings/preferences.js) before it is stored.
--
-- Additive only.

alter table profiles add column if not exists preferences jsonb not null default '{}'::jsonb;
__PA_EOF__
echo "wrote server/src/db/migrations/021_profile_preferences.sql"

mkdir -p server/src/settings
cat > server/src/settings/preferences.js <<'__PA_EOF__'
// classroom-app/server/src/settings/preferences.js
/**
 * Account preferences  (Settings, Phase A)
 *
 * The one definition of what a preference may be. Stored in
 * profiles.preferences (021) as a jsonb object of sections; every write is
 * validated here, merged into what is stored, and the full result returned
 * with defaults filled in — so a client never has to know a default.
 *
 *   appearance    fontScale · reduceMotion
 *   region        dateFormat · timeFormat          (language and time zone
 *                                                    live on the user row)
 *   lesson        joinMicrophone · joinCamera · noiseSuppression ·
 *                 echoCancellation · dataSaver
 *   roomDefaults  reactionsEnabled · learnersJoinMuted
 *                                                   teachers and owners only
 *
 * Waiting room and "learners may share their screen" are deliberately not
 * lesson defaults yet: the join flow has no admit step (a waiting room would
 * turn people away, the host included), and the screen-share rule is not
 * enforced in one place the default could rely on.
 *
 * Device choices (which camera, which microphone) are not here on purpose:
 * device ids differ per computer, so the browser keeps them.
 */

import { z } from 'zod';

const appearance = z.object({
  fontScale: z.enum(['small', 'default', 'large', 'x-large']),
  reduceMotion: z.boolean(),
});

const region = z.object({
  dateFormat: z.enum(['auto', 'day-month-year', 'month-day-year', 'year-month-day']),
  timeFormat: z.enum(['auto', '24h', '12h']),
});

const lesson = z.object({
  joinMicrophone: z.enum(['off', 'on']),
  joinCamera: z.enum(['on', 'off']),
  noiseSuppression: z.boolean(),
  echoCancellation: z.boolean(),
  dataSaver: z.boolean(),
});

const roomDefaults = z.object({
  reactionsEnabled: z.boolean(),
  learnersJoinMuted: z.boolean(),
});

export const DEFAULT_PREFERENCES = Object.freeze({
  appearance: { fontScale: 'default', reduceMotion: false },
  region: { dateFormat: 'auto', timeFormat: 'auto' },
  lesson: {
    joinMicrophone: 'off',
    joinCamera: 'on',
    noiseSuppression: true,
    echoCancellation: true,
    dataSaver: false,
  },
  roomDefaults: {
    reactionsEnabled: true,
    learnersJoinMuted: false,
  },
});

const SECTIONS = { appearance, region, lesson, roomDefaults };

/** A patch: any section, any subset of its keys. Unknown keys are refused. */
export const PreferencesPatchSchema = z
  .object({
    appearance: appearance.partial().strict().optional(),
    region: region.partial().strict().optional(),
    lesson: lesson.partial().strict().optional(),
    roomDefaults: roomDefaults.partial().strict().optional(),
  })
  .strict();

/** Stored values over defaults; anything stored that is no longer valid falls back. */
export const withDefaults = (stored = {}) => {
  const result = {};
  for (const [name, schema] of Object.entries(SECTIONS)) {
    const merged = { ...DEFAULT_PREFERENCES[name], ...(stored?.[name] ?? {}) };
    const parsed = schema.safeParse(merged);
    result[name] = parsed.success ? parsed.data : { ...DEFAULT_PREFERENCES[name] };
  }
  return result;
};

/** Merges a validated patch into stored preferences, section by section. */
export const mergePatch = (stored = {}, patch = {}) => {
  const next = { ...(stored ?? {}) };
  for (const [name, values] of Object.entries(patch)) {
    if (values) next[name] = { ...(next[name] ?? {}), ...values };
  }
  return next;
};

export const TEACHING_ROLES = new Set(['teacher', 'owner']);

export default { DEFAULT_PREFERENCES, PreferencesPatchSchema, withDefaults, mergePatch, TEACHING_ROLES };
__PA_EOF__
echo "wrote server/src/settings/preferences.js"

mkdir -p server/src/identity
cat > server/src/identity/Profile.js <<'__PA_EOF__'
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
__PA_EOF__
echo "wrote server/src/identity/Profile.js"

mkdir -p server/src/routes
cat > server/src/routes/profile.routes.js <<'__PA_EOF__'
/**
 * profile.routes — own profile · privacy · other people · blocking (F6)
 *
 * Mounted under /profiles (app.js), so every path here is relative to it:
 * '/me' is GET /profiles/me. (The previous version repeated the prefix, which
 * made every route answer at /profiles/profiles/… and the client's calls 404.)
 *
 * A profile read is filtered by the viewer, and `canMessage` comes back
 * computed by ConversationService.canMessage — the same rule the send path
 * enforces — so the Message button and the send always agree. `roomId` in the
 * query lets that rule count a shared live lesson as shared context.
 *
 * Both the contract's paths (profileApi: PATCH /me/privacy, POST /me/blocks,
 * DELETE /me/blocks/:userId) and the older ones (PUT /me/privacy,
 * PUT|DELETE /:userId/block) are served, so no client breaks while it moves.
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Profile from '../identity/Profile.js';
import * as ConversationService from '../messaging/ConversationService.js';
import * as ChatModerationService from '../messaging/ChatModerationService.js';
import * as UploadService from '../media/UploadService.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, tenantOf, q, notFound, badRequest, forbidden } from './_helpers.js';

const router = Router();
router.use(requireAuth);

const userIdParam = z.object({ userId: z.string().uuid() });

/** Errors the profile domain raises with a code, as the HTTP answers clients understand. */
const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      case 'conflict':
        throw Object.assign(badRequest(error.message), { status: 409 });
      default:
        throw error;
    }
  }
};

const TIME_ZONES = new Set(Intl.supportedValuesOf('timeZone'));

/* ------------------------------------------------------------------ *
 * Own profile
 * ------------------------------------------------------------------ */

router.get(
  '/me',
  route(async (req) => {
    const own = await Profile.getOwn(req.user.id);
    if (!own) throw notFound('No profile for this account');
    return own;
  }),
);

router.patch(
  '/me',
  validate({
    body: z.object({
      displayName: z.string().trim().min(1).max(80).optional(),
      // Lower-case letters, digits and underscores: what @mentions can match.
      handle: z.string().trim().toLowerCase().regex(/^[a-z0-9_]{3,32}$/, 'use 3–32 lowercase letters, digits or _').optional(),
      bio: z.string().max(2000).nullish(),
      headline: z.string().max(140).nullish(),
      avatarAssetId: z.string().uuid().nullish(),
      links: z.array(z.object({ label: z.string().max(40), url: z.string().url() })).max(5).optional(),
      locale: z.string().regex(/^[a-z]{2}(-[A-Z]{2})?$/, 'a language code such as en or de-DE').optional(),
      timeZone: z.string().max(64).refine((zone) => TIME_ZONES.has(zone), 'not a known time zone').optional(),
    }),
  }),
  route(
    asHttp(async (req) => {
      const { avatarAssetId, ...patch } = req.body;
      if (avatarAssetId) await Profile.setAvatar({ userId: req.user.id, assetId: avatarAssetId });
      return Profile.update({ userId: req.user.id, patch });
    }),
  ),
);

/**
 * Account preferences: appearance, date and time format, how lessons start
 * for me, and (teachers) my lesson defaults. PATCH takes any section with any
 * subset of its keys and returns the full set with defaults filled in.
 */
router.get(
  '/me/preferences',
  route(async (req) => Profile.getPreferences(req.user.id)),
);

router.patch(
  '/me/preferences',
  route(asHttp(async (req) => Profile.updatePreferences({ userId: req.user.id, patch: req.body }))),
);

/**
 * Who may message me, and what others see. "Receive private messages: off" is
 * dmPolicy 'nobody'; teachers of the tenant can still reach the person.
 */
const privacyBody = z.object({
  dmPolicy: z.enum(['anyone', 'shared-context', 'shared-only', 'shared', 'nobody']).optional(),
  visibility: z.enum(['tenant', 'shared-only', 'shared', 'private']).optional(),
  showPresence: z.boolean().optional(),
  sendReadReceipts: z.boolean().optional(),
  readReceipts: z.boolean().optional(),
});

const updatePrivacy = route(async (req) => Profile.updatePrivacy({ userId: req.user.id, patch: req.body }));
router.patch('/me/privacy', validate({ body: privacyBody }), updatePrivacy);
router.put('/me/privacy', validate({ body: privacyBody }), updatePrivacy);

router.get(
  '/me/privacy',
  route(async (req) => (await Profile.getOwn(req.user.id))?.privacy ?? null),
);

/** Avatar upload goes through the media presign flow like any other asset. */
router.post(
  '/me/avatar',
  validate({
    body: z.object({
      filename: z.string().min(1).max(255),
      contentType: z.enum(['image/jpeg', 'image/png', 'image/webp']),
      sizeBytes: z.number().int().min(1).max(10 * 1024 * 1024),
    }),
  }),
  route(async (req, res) => {
    res.status(201);
    return UploadService.createUpload({
      ownerId: req.user.id,
      purpose: 'avatar',
      fileName: req.body.filename,
      contentType: req.body.contentType,
      sizeBytes: req.body.sizeBytes,
    });
  }),
);

router.put(
  '/me/avatar',
  validate({ body: z.object({ assetId: z.string().uuid() }) }),
  route(async (req) => Profile.setAvatar({ userId: req.user.id, assetId: req.body.assetId })),
);

/* ------------------------------------------------------------------ *
 * Blocking (account-wide)
 * ------------------------------------------------------------------ */

router.get(
  '/me/blocks',
  validate({ query: z.object({ cursor: z.string().optional(), limit: z.coerce.number().int().min(1).max(100).optional() }) }),
  route(async (req) =>
    Profile.listBlocks({ userId: req.user.id, cursor: q(req).cursor ?? null, limit: q(req).limit ?? 25 }),
  ),
);

const block = async (req, blockedUserId, reason) => {
  if (blockedUserId === req.user.id) throw badRequest('You cannot block yourself');
  // Mutual in effect: neither side can message the other afterwards.
  return Profile.block({ userId: req.user.id, blockedUserId, reason: reason ?? null });
};

router.post(
  '/me/blocks',
  validate({ body: z.object({ userId: z.string().uuid(), reason: z.string().max(500).optional() }).passthrough() }),
  route(async (req, res) => {
    res.status(201);
    return block(req, req.body.userId, req.body.reason);
  }),
);

router.delete(
  '/me/blocks/:userId',
  validate({ params: userIdParam }),
  route(async (req) => {
    await Profile.unblock({ userId: req.user.id, blockedUserId: req.params.userId });
    return null;
  }),
);

router.put(
  '/:userId/block',
  validate({ params: userIdParam, body: z.object({ reason: z.string().max(500).optional() }).default({}) }),
  route(async (req) => block(req, req.params.userId, req.body?.reason)),
);

router.delete(
  '/:userId/block',
  validate({ params: userIdParam }),
  route(async (req) => {
    await Profile.unblock({ userId: req.user.id, blockedUserId: req.params.userId });
    return null;
  }),
);

/* ------------------------------------------------------------------ *
 * Other people
 * ------------------------------------------------------------------ */

/** Mention autocomplete and people search. */
const searchQuery = z.object({
  q: z.string().min(2).max(80),
  scopeId: z.string().uuid().optional(),
  spaceId: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(25).optional(),
});

const search = route(async (req) =>
  Profile.search({
    q: q(req).q,
    viewerId: req.user.id,
    scopeId: q(req).scopeId ?? q(req).spaceId ?? null,
    limit: q(req).limit ?? 10,
  }),
);

router.get('/search', rateLimit({ key: 'profile:search', points: 60, durationSec: 60, by: ['user'] }), validate({ query: searchQuery }), search);
router.get('/', rateLimit({ key: 'profile:search', points: 60, durationSec: 60, by: ['user'] }), validate({ query: searchQuery }), search);

/**
 * Someone else's profile, as this viewer may see it. `canMessage` and the
 * reason are computed by the same rule the send path enforces.
 */
router.get(
  '/:userId',
  rateLimit({ key: 'profile:read', points: 300, durationSec: 300, by: ['user'] }),
  validate({ params: userIdParam, query: z.object({ roomId: z.string().uuid().optional() }).passthrough() }),
  route(async (req) => {
    const profile = await Profile.getPublic({ userId: req.params.userId, viewerId: req.user.id });
    if (!profile) throw notFound('No such profile');

    const roomId = q(req).roomId ?? null;
    const messaging = await ConversationService.canMessage({
      fromUserId: req.user.id,
      toUserId: req.params.userId,
      roomId,
    });

    // Teachers count as sharing a course with the people they teach, as in
    // the "View as" preview in Settings.
    const shares =
      req.params.userId === req.user.id ||
      ['teacher', 'owner'].includes(req.user.role) ||
      (await ConversationService.sharesContext({ userA: req.user.id, userB: req.params.userId, roomId }));

    return {
      ...Profile.applyVisibility(profile, { sharesContext: shares }),
      canMessage: messaging.allowed,
      cannotMessageReason: messaging.allowed ? null : messaging.reason ?? null,
    };
  }),
);

/* ------------------------------------------------------------------ *
 * Reporting
 * ------------------------------------------------------------------ */

router.post(
  '/:userId/report',
  rateLimit({ key: 'profile:report', points: 20, durationSec: 3600, by: ['user'] }),
  validate({
    params: userIdParam,
    body: z.object({
      reason: z.enum(['spam', 'abuse', 'harassment', 'impersonation', 'nsfw', 'other']),
      note: z.string().max(2000).optional(),
      messageIds: z.array(z.string().uuid()).max(20).default([]),
    }),
  }),
  route(async (req, res) => {
    res.status(202);
    return ChatModerationService.reportUser({
      reporterId: req.user.id,
      reportedId: req.params.userId,
      tenantId: tenantOf(req),
      ...req.body,
    });
  }),
);

export default router;
__PA_EOF__
echo "wrote server/src/routes/profile.routes.js"

mkdir -p server/src/messaging
cat > server/src/messaging/ConversationService.js <<'__PA_EOF__'
// classroom-app/server/src/messaging/ConversationService.js
/**
 * Conversations  (F6)
 *
 * Opening a private chat resolves here. `openDirect` is idempotent: it returns
 * the existing conversation or creates one, and the database's unique key on
 * the participant pair settles two clicks at the same moment.
 *
 * Before it creates anything it answers a question only the server can answer:
 * may these two people talk? That needs the target's DM setting, both block
 * lists, the sender's role and whether they share a course, a space or the
 * live room they are in right now.
 *
 * The rules (canMessage):
 *
 *   blocked either way      no — outranks everything, teachers included
 *   (account or this lesson)
 *   sender is a teacher     yes — a course must be able to reach its people,
 *   or owner                even someone who switched private messages off
 *   DM setting 'anyone'     yes
 *   DM setting 'nobody'     no  ("receive private messages: off")
 *   DM setting 'shared'     yes when they share a course, a space, or the
 *   (the default)           live room the request came from
 *
 * Per-person state — mute with an end time, "deleted for me" — is written
 * here through Participant, never shared between the two sides.
 */

import { randomUUID } from 'node:crypto';
import { ApiError } from '@classroom/contracts';
import { env } from '../config/env.js';
import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Conversation from './models/Conversation.js';
import * as Participant from './models/Participant.js';
import * as Block from './models/Block.js';

const log = logger.child({ component: 'conversations' });

const MAX_GROUP = 50;
const TEACHING_ROLES = new Set(['teacher', 'owner']);

/** The contract says 'shared-context', the table says 'shared-only'. Same setting. */
export const toDbPolicy = (policy) =>
  policy === 'shared-context' || policy === 'shared' ? 'shared-only' : policy;

// ---------------------------------------------------------------------------
// Shared context
// ---------------------------------------------------------------------------

/** A course or a space in common. Missing tables in a partial schema count as "no". */
const sharesCourseOrSpace = async (userA, userB) => {
  try {
    const { rows } = await pool.query(
      `SELECT 1 FROM (
         SELECT course_id AS id FROM enrollments WHERE user_id = $1 AND status = 'active'
         INTERSECT
         SELECT course_id AS id FROM enrollments WHERE user_id = $2 AND status = 'active'
         UNION ALL
         SELECT space_id AS id FROM space_memberships WHERE user_id = $1
         INTERSECT
         SELECT space_id AS id FROM space_memberships WHERE user_id = $2
       ) shared LIMIT 1`,
      [userA, userB],
    );
    return rows.length > 0;
  } catch (cause) {
    log.warn({ err: cause }, 'shared-context lookup failed; treating as no shared context');
    return false;
  }
};

/**
 * Both are in the same live room right now. Rooms live in the SFU process;
 * in development that is this process. Where it is not, the answer is "no" and
 * the course/space rule still applies.
 */
const sharesLiveRoom = async (userA, userB, roomId) => {
  if (!roomId) return false;
  try {
    const RoomManager = await import('../classroom/RoomManager.js');
    const room = RoomManager.getRoom(roomId);
    return Boolean(room?.findPeerByUser?.(userA) && room?.findPeerByUser?.(userB));
  } catch {
    return false;
  }
};

/**
 * Whether two people share a course, a space or the live lesson `roomId`.
 * Used for "who may message me" here and for "who may see my profile" in
 * profile.routes, so both settings mean the same thing by "shared".
 */
export const sharesContext = async ({ userA, userB, roomId = null }) =>
  (await sharesLiveRoom(userA, userB, roomId)) || (await sharesCourseOrSpace(userA, userB));

// ---------------------------------------------------------------------------
// Permission
// ---------------------------------------------------------------------------

/**
 * The single source of truth for "may A message B". Used here, and by
 * profile.routes to fill `canMessage`, so the button and the send agree.
 *
 * @returns {Promise<{ allowed: boolean, code?: string, reason?: string }>}
 */
export const canMessage = async ({ fromUserId, toUserId, roomId = null }) => {
  if (!fromUserId || !toUserId || fromUserId === toUserId) {
    return { allowed: false, code: 'validation_failed', reason: 'You cannot message yourself.' };
  }

  const { blocked } = await Block.areBlocked(fromUserId, toUserId);
  if (blocked) {
    // Same answer whichever direction the block runs: telling someone they
    // have been blocked is information the blocker did not choose to share.
    return { allowed: false, code: 'blocked_by_user', reason: 'You cannot message this person.' };
  }

  // A block made in a live lesson counts the same while that lesson runs.
  const { isBlockedEitherWay: blockedInSession } = await import('./SessionBlocks.js');
  if (await blockedInSession(fromUserId, toUserId)) {
    return { allowed: false, code: 'blocked_by_user', reason: 'You cannot message this person right now.' };
  }

  const { rows } = await pool.query(
    `SELECT u.id, u.tenant_id, u.role, p.dm_policy
       FROM users u
       LEFT JOIN profiles p ON p.user_id = u.id
      WHERE u.id = ANY($1::uuid[]) AND u.deleted_at IS NULL`,
    [[fromUserId, toUserId]],
  );
  const sender = rows.find((row) => row.id === fromUserId);
  const target = rows.find((row) => row.id === toUserId);

  if (!sender || !target || sender.tenant_id !== target.tenant_id) {
    return { allowed: false, code: 'not_found', reason: 'This person could not be found.' };
  }

  if (TEACHING_ROLES.has(sender.role)) return { allowed: true, reason: 'teacher' };

  const policy = target.dm_policy ?? toDbPolicy(env.CHAT_DEFAULT_DM_POLICY ?? 'shared-only');

  if (policy === 'anyone') return { allowed: true };
  if (policy === 'nobody') {
    return { allowed: false, code: 'dm_not_allowed', reason: 'This person does not accept private messages.' };
  }

  if ((await sharesLiveRoom(fromUserId, toUserId, roomId)) || (await sharesCourseOrSpace(fromUserId, toUserId))) {
    return { allowed: true };
  }
  return {
    allowed: false,
    code: 'dm_not_allowed',
    reason: 'This person only accepts private messages from people they share a course or lesson with.',
  };
};

// ---------------------------------------------------------------------------
// Shaping
// ---------------------------------------------------------------------------

/** One conversation as `viewerId` sees it: their mute, their unread count, their preview. */
const hydrate = async ({ row, viewerId, created = false }) => {
  const participants = await Participant.listForConversation(row.conversation_id);
  const viewer = participants.find((participant) => participant.user_id === viewerId) ?? row;

  return {
    ...Conversation.toConversation(row, {
      participants: participants.map(Participant.toParticipant),
      muted: Participant.isMutedNow(viewer),
      mutedUntil: Participant.isMutedNow(viewer) ? viewer.muted_until ?? null : null,
      unreadCount: Number(row.unread_count ?? 0),
      lastMessagePreview: row.last_message_preview ?? null,
    }),
    created,
  };
};

/** The viewer's own row for one conversation (unread, preview), hidden or not. */
const rowFor = async ({ conversationId, userId }) => {
  const page = await Conversation.listForUser({ userId, conversationId, limit: 1 });
  return page.rows[0] ?? null;
};

// ---------------------------------------------------------------------------
// Open or create
// ---------------------------------------------------------------------------

/**
 * Idempotent. The person who opens the chat sees it immediately; the other
 * person sees it once the first message arrives (Conversation.create hides it
 * for them, Conversation.touch reveals it).
 *
 * Reopening a chat you deleted brings it back into your list with history
 * still starting where you deleted it.
 */
export const openDirect = async ({ fromUserId, toUserId, tenantId, roomId = null }) => {
  const existing = await Conversation.findDirectBetween({ tenantId, userA: fromUserId, userB: toUserId });
  if (existing) {
    await Participant.reveal({ conversationId: existing.conversation_id, userId: fromUserId });
    const row = await rowFor({ conversationId: existing.conversation_id, userId: fromUserId });
    return hydrate({ row: row ?? existing, viewerId: fromUserId });
  }

  const permission = await canMessage({ fromUserId, toUserId, roomId });
  if (!permission.allowed) {
    throw new ApiError(permission.code ?? 'forbidden', {
      detail: permission.reason ?? 'You cannot message this person.',
    });
  }

  try {
    const created = await Conversation.create({
      conversationId: randomUUID(),
      tenantId,
      kind: 'direct',
      createdBy: fromUserId,
      participantIds: [fromUserId, toUserId],
      hiddenFor: [toUserId],
    });

    log.info({ conversationId: created.conversation_id }, 'direct conversation opened');
    const row = await rowFor({ conversationId: created.conversation_id, userId: fromUserId });
    const conversation = await hydrate({ row: row ?? created, viewerId: fromUserId, created: true });

    // The opener's other tabs and devices add it to their list too.
    const { notifyConversationCreated } = await import('./chatGateway.js');
    notifyConversationCreated({ conversation, userIds: [fromUserId] });

    return conversation;
  } catch (cause) {
    // Unique violation on the participant pair: the other person opened it a
    // moment ago. Theirs is as good as ours.
    if (cause?.code === '23505') {
      const raced = await Conversation.findDirectBetween({ tenantId, userA: fromUserId, userB: toUserId });
      if (raced) {
        await Participant.reveal({ conversationId: raced.conversation_id, userId: fromUserId });
        const row = await rowFor({ conversationId: raced.conversation_id, userId: fromUserId });
        return hydrate({ row: row ?? raced, viewerId: fromUserId });
      }
    }
    throw cause;
  }
};

export const createGroup = async ({ createdBy, participantIds, title = null, tenantId }) => {
  const unique = [...new Set([createdBy, ...participantIds])];

  if (unique.length < 3) {
    throw new ApiError('validation_failed', {
      detail: 'A group needs at least three people. Use a private message for two.',
    });
  }
  if (unique.length > MAX_GROUP) {
    throw new ApiError('validation_failed', { detail: `A group holds at most ${MAX_GROUP} people.` });
  }

  for (const userId of unique) {
    if (userId === createdBy) continue;
    const permission = await canMessage({ fromUserId: createdBy, toUserId: userId });
    if (!permission.allowed) {
      throw new ApiError(permission.code ?? 'forbidden', {
        detail: 'One of the people you selected cannot be added.',
      });
    }
  }

  const created = await Conversation.create({
    conversationId: randomUUID(),
    tenantId,
    kind: 'group',
    title,
    createdBy,
    participantIds: unique,
  });

  const row = await rowFor({ conversationId: created.conversation_id, userId: createdBy });
  return hydrate({ row: row ?? created, viewerId: createdBy, created: true });
};

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

export const assertParticipant = async ({ conversationId, userId }) => {
  if (!(await Participant.isParticipant({ conversationId, userId }))) {
    // 404, not 403: whether a conversation exists is not the caller's business.
    throw new ApiError('not_found', { detail: 'Conversation not found.' });
  }
};

export const getById = async ({ conversationId, viewerId }) => {
  await assertParticipant({ conversationId, userId: viewerId });
  const row = await rowFor({ conversationId, userId: viewerId });
  if (!row) throw new ApiError('not_found', { detail: 'Conversation not found.' });
  return hydrate({ row, viewerId });
};

/** The viewer's visible conversations, newest activity first. */
export const list = async ({ userId, cursor = null, limit = 25 }) => {
  const page = await Conversation.listForUser({ userId, cursor, limit });
  const items = await Promise.all(page.rows.map((row) => hydrate({ row, viewerId: userId })));
  return { items, nextCursor: page.nextCursor, hasMore: page.hasMore };
};

// ---------------------------------------------------------------------------
// Per-person state
// ---------------------------------------------------------------------------

/**
 * Mute for a while or until turned back on. `until` must lie in the future;
 * `muted: false` ends any mute.
 */
export const setMuted = async ({ conversationId, userId, muted, until = null }) => {
  await assertParticipant({ conversationId, userId });

  if (muted && until && new Date(until).getTime() <= Date.now()) {
    throw new ApiError('validation_failed', { detail: 'A mute has to end in the future.' });
  }

  await Participant.setMuted({ conversationId, userId, muted: Boolean(muted), until: muted ? until : null });
  return getById({ conversationId, viewerId: userId });
};

/**
 * "Delete for me". Only this person's view changes: the thread leaves their
 * list and their history restarts now. The other side keeps everything, and a
 * new message brings the thread back for this person without the old ones.
 */
export const deleteForMe = async ({ conversationId, userId }) => {
  await assertParticipant({ conversationId, userId });
  await Participant.hide({ conversationId, userId });

  const { clear } = await import('./UnreadService.js');
  await clear({ userId, target: { kind: 'conversation', conversationId } }).catch(() => undefined);

  return { conversationId, deleted: true };
};

/** Leaving a group removes you; "leaving" a direct chat is deleting it for yourself. */
export const leave = async ({ conversationId, userId }) => {
  const row = await Conversation.findById(conversationId);
  if (!row) return false;

  if (row.kind === 'direct') {
    await deleteForMe({ conversationId, userId });
    return true;
  }

  await Participant.remove({ conversationId, userId });
  return true;
};

// ---------------------------------------------------------------------------
// Live list updates
// ---------------------------------------------------------------------------

/**
 * A message landed in a conversation. Every participant's list gets the
 * updated row — their own unread count, their own preview — on their personal
 * socket room, so a thread appears and a badge moves without a reload.
 */
export const announceActivity = async ({ conversationId }) => {
  const { notifyConversationUpdated } = await import('./chatGateway.js');
  const participants = await Participant.listForConversation(conversationId);

  await Promise.all(
    participants.map(async ({ user_id: userId }) => {
      const row = await rowFor({ conversationId, userId });
      if (!row || row.hidden_at) return;
      notifyConversationUpdated({ userId, conversation: await hydrate({ row, viewerId: userId }) });
    }),
  );
};

export default {
  canMessage, sharesContext, openDirect, createGroup, getById, list, setMuted, deleteForMe, leave,
  assertParticipant, announceActivity, toDbPolicy,
};
__PA_EOF__
echo "wrote server/src/messaging/ConversationService.js"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/profileApi.ts <<'__PA_EOF__'
/**
 * Profile API  (F6)
 *
 * Paths are the server's (server/src/routes/profile.routes.js, mounted under
 * /profiles). Responses are validated with the view schemas below: they accept
 * the server's role and handle spellings as they are, and keep the per-viewer
 * fields the UI needs (`canMessage`, `cannotMessageReason`).
 *
 * `canMessage` is computed by the server with the same rule the send path
 * enforces, and must be treated as authoritative. Passing `roomId` lets that
 * rule count "we are in the same lesson right now" as shared context.
 *
 * DM setting, in the contract's words:
 *   'anyone' | 'shared-context' | 'nobody'
 * "Receive private messages: off" is 'nobody'; teachers can still write.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

export const PublicProfileViewSchema = z
  .object({
    userId: z.string(),
    displayName: z.string(),
    handle: z.string().nullable().default(null),
    avatarUrl: z.string().nullable().default(null),
    role: z.string().nullable().default(null),
    canMessage: z.boolean().default(false),
    cannotMessageReason: z.string().nullable().default(null),
    isBlockedByViewer: z.boolean().default(false),
  })
  .passthrough();
export type PublicProfileView = z.infer<typeof PublicProfileViewSchema>;

export const PrivacyViewSchema = z
  .object({
    dmPolicy: z.enum(['anyone', 'shared-context', 'nobody']).default('shared-context'),
    visibility: z.enum(['tenant', 'shared-only', 'private']).default('tenant'),
    showPresence: z.boolean().default(true),
    sendReadReceipts: z.boolean().default(true),
  })
  .passthrough();
export type PrivacyView = z.infer<typeof PrivacyViewSchema>;

export const OwnProfileViewSchema = z
  .object({
    userId: z.string(),
    displayName: z.string(),
    email: z.string(),
    handle: z.string().nullable().default(null),
    headline: z.string().nullable().default(null),
    bio: z.string().nullable().default(null),
    links: z.array(z.object({ label: z.string(), url: z.string() })).default([]),
    role: z.string().nullable().default(null),
    locale: z.string().nullable().default(null),
    timeZone: z.string().nullable().default(null),
    privacy: PrivacyViewSchema,
  })
  .passthrough();

/** Account preferences (server/src/settings/preferences.js); defaults are filled in by the server. */
export const PreferencesViewSchema = z
  .object({
    appearance: z.object({ fontScale: z.string(), reduceMotion: z.boolean() }).passthrough(),
    region: z.object({ dateFormat: z.string(), timeFormat: z.string() }).passthrough(),
    lesson: z
      .object({
        joinMicrophone: z.string(),
        joinCamera: z.string(),
        noiseSuppression: z.boolean(),
        echoCancellation: z.boolean(),
        dataSaver: z.boolean(),
      })
      .passthrough(),
    roomDefaults: z.object({ reactionsEnabled: z.boolean(), learnersJoinMuted: z.boolean() }).passthrough(),
  })
  .passthrough();
export type PreferencesView = z.infer<typeof PreferencesViewSchema>;
export type OwnProfileView = z.infer<typeof OwnProfileViewSchema>;

export const BlockViewSchema = z
  .object({
    blockedUserId: z.string(),
    blockedAt: z.string().nullable().default(null),
    reason: z.string().nullable().default(null),
    profile: z.object({ userId: z.string(), displayName: z.string(), avatarUrl: z.string().nullable().default(null) }),
  })
  .passthrough();
export type BlockView = z.infer<typeof BlockViewSchema>;

const BlockPageSchema = z.object({
  items: z.array(BlockViewSchema),
  hasMore: z.boolean().default(false),
  nextCursor: z.string().nullable().default(null),
});

const SuggestionListSchema = z.object({
  items: z.array(
    z
      .object({
        userId: z.string(),
        displayName: z.string(),
        handle: z.string().nullable().default(null),
        avatarUrl: z.string().nullable().default(null),
      })
      .passthrough(),
  ),
});

export interface ProfileApi {
  getOwn(signal?: AbortSignal): Promise<OwnProfileView>;
  get(userId: string, options?: { roomId?: string | null; signal?: AbortSignal }): Promise<PublicProfileView>;
  update(input: Record<string, unknown>): Promise<OwnProfileView>;
  getPrivacy(signal?: AbortSignal): Promise<PrivacyView>;
  getPreferences(signal?: AbortSignal): Promise<PreferencesView>;
  /** Any section, any subset of its keys; returns the full set. */
  updatePreferences(patch: Record<string, Record<string, unknown>>): Promise<PreferencesView>;
  updatePrivacy(input: Partial<PrivacyView>): Promise<PrivacyView>;
  search(
    query: { q: string; scopeId?: string; limit?: number },
    signal?: AbortSignal,
  ): Promise<z.infer<typeof SuggestionListSchema>>;
  listBlocks(query?: { cursor?: string; limit?: number }, signal?: AbortSignal): Promise<z.infer<typeof BlockPageSchema>>;
  block(input: { userId: string; reason?: string }): Promise<BlockView>;
  unblock(userId: string): Promise<void>;

  // Kept for existing callers. Notification settings have no storage on the
  // server yet; reports and presence are served by other parts of the product.
  getByHandle(handle: string, signal?: AbortSignal): Promise<PublicProfileView>;
  updateNotifications(input: Record<string, unknown>): Promise<unknown>;
  setAvatar(assetId: string): Promise<OwnProfileView>;
  report(input: { userId: string; reason: string; detail?: string }): Promise<unknown>;
}

export const createProfileApi = (http: HttpClient): ProfileApi => ({
  getOwn: (signal) => http.get('/profiles/me', { schema: OwnProfileViewSchema, signal }),

  get: (userId, options = {}) =>
    http.get(`/profiles/${encodeURIComponent(userId)}`, {
      schema: PublicProfileViewSchema,
      query: options.roomId ? { roomId: options.roomId } : undefined,
      signal: options.signal,
    }),

  update: (input) => http.patch('/profiles/me', input, { schema: OwnProfileViewSchema }),

  getPrivacy: (signal) => http.get('/profiles/me/privacy', { schema: PrivacyViewSchema, signal }),

  getPreferences: (signal) => http.get('/profiles/me/preferences', { schema: PreferencesViewSchema, signal }),

  updatePreferences: (patch) =>
    http.patch('/profiles/me/preferences', patch, { schema: PreferencesViewSchema }),

  updatePrivacy: (input) =>
    http.patch('/profiles/me/privacy', input, { schema: PrivacyViewSchema }),

  search: (query, signal) =>
    http.get('/profiles/search', {
      schema: SuggestionListSchema,
      query: { q: query.q, scopeId: query.scopeId, limit: query.limit },
      signal,
      // Typed into a mention box: a stale response is worthless.
      retry: { attempts: 1 },
      timeoutMs: 5_000,
    }),

  listBlocks: (query = {}, signal) =>
    http.get('/profiles/me/blocks', {
      schema: BlockPageSchema,
      query: { cursor: query.cursor, limit: query.limit },
      signal,
    }),

  /** Account-wide. Blocking for one lesson is chatApi.blockInSession(). */
  block: (input) => http.post('/profiles/me/blocks', input, { schema: BlockViewSchema }),

  unblock: async (userId) => {
    await http.delete(`/profiles/me/blocks/${encodeURIComponent(userId)}`);
  },

  getByHandle: (handle, signal) =>
    http.get(`/profiles/by-handle/${encodeURIComponent(handle)}`, { schema: PublicProfileViewSchema, signal }),

  updateNotifications: (input) => http.patch('/profiles/me/notifications', input),

  setAvatar: (assetId) => http.put('/profiles/me/avatar', { assetId }, { schema: OwnProfileViewSchema }),

  report: (input) =>
    http.post(`/profiles/${encodeURIComponent(input.userId)}/report`, {
      reason: input.reason,
      note: input.detail,
    }),
});
__PA_EOF__
echo "wrote packages/core-client/src/api/profileApi.ts"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/preferences.js <<'__PA_EOF__'
/**
 * Preferences on this device  (Settings, Phase A)
 *
 * The account's preferences live on the server (GET/PATCH
 * /profiles/me/preferences). This module keeps a copy in localStorage so they
 * apply from the first frame — the font size before the page paints, the
 * microphone state before a lesson is joined — and refreshes that copy
 * whenever the server answers (PreferencesSync in AppLayout, and every save
 * in Settings).
 *
 * Device choices (camera, microphone, speaker) are stored here only: device
 * ids differ from computer to computer.
 */

const CACHE_KEY = 'classroom:preferences';
const DEVICE_KEY = 'classroom:devices';
const LOCALE_KEY = 'classroom:locale';

export const DEFAULT_PREFERENCES = Object.freeze({
  appearance: { fontScale: 'default', reduceMotion: false },
  region: { dateFormat: 'auto', timeFormat: 'auto' },
  lesson: {
    joinMicrophone: 'off',
    joinCamera: 'on',
    noiseSuppression: true,
    echoCancellation: true,
    dataSaver: false,
  },
  roomDefaults: { reactionsEnabled: true, learnersJoinMuted: false },
});

const storage = () => {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
};

const readJson = (key) => {
  try {
    return JSON.parse(storage()?.getItem(key) ?? 'null');
  } catch {
    return null;
  }
};

const writeJson = (key, value) => {
  try {
    storage()?.setItem(key, JSON.stringify(value));
  } catch {
    // Private mode or a full quota: the preferences still apply for this page.
  }
};

const merge = (stored) => {
  const result = {};
  for (const [section, defaults] of Object.entries(DEFAULT_PREFERENCES)) {
    result[section] = { ...defaults, ...(stored?.[section] ?? {}) };
  }
  return result;
};

export const cachedPreferences = () => merge(readJson(CACHE_KEY));

/** Stores the server's answer on this device and applies what applies at once. */
export const cachePreferences = (preferences) => {
  const merged = merge(preferences);
  writeJson(CACHE_KEY, merged);
  applyAppearance(merged.appearance);
  return merged;
};

export const cacheLocale = (locale) => {
  if (locale) writeJson(LOCALE_KEY, locale);
};
const cachedLocale = () => readJson(LOCALE_KEY) ?? undefined;

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

export const FONT_SCALES = { small: '93.75%', default: '100%', large: '112.5%', 'x-large': '125%' };

const MOTION_STYLE_ID = 'classroom-reduce-motion';
const MOTION_CSS = `
:root[data-reduce-motion="true"] *,
:root[data-reduce-motion="true"] *::before,
:root[data-reduce-motion="true"] *::after {
  animation-duration: 0.01ms !important;
  animation-iteration-count: 1 !important;
  transition-duration: 0.01ms !important;
  scroll-behavior: auto !important;
}`;

export const applyAppearance = (appearance = DEFAULT_PREFERENCES.appearance) => {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  root.style.fontSize = FONT_SCALES[appearance.fontScale] ?? '100%';
  root.dataset.reduceMotion = appearance.reduceMotion ? 'true' : 'false';
  if (!document.getElementById(MOTION_STYLE_ID)) {
    const style = document.createElement('style');
    style.id = MOTION_STYLE_ID;
    style.textContent = MOTION_CSS;
    document.head.appendChild(style);
  }
};

/** Called once in main.jsx, before the first render. */
export const applyCachedAppearance = () => applyAppearance(cachedPreferences().appearance);

// ---------------------------------------------------------------------------
// Date and time
// ---------------------------------------------------------------------------

const pad = (n) => String(n).padStart(2, '0');

export const formatTime = (value, region = cachedPreferences().region) => {
  const date = value instanceof Date ? value : new Date(value);
  const options = { hour: '2-digit', minute: '2-digit' };
  if (region.timeFormat === '24h') options.hourCycle = 'h23';
  if (region.timeFormat === '12h') options.hourCycle = 'h12';
  return new Intl.DateTimeFormat(cachedLocale(), options).format(date);
};

export const formatDate = (value, region = cachedPreferences().region) => {
  const date = value instanceof Date ? value : new Date(value);
  const d = pad(date.getDate());
  const m = pad(date.getMonth() + 1);
  const y = date.getFullYear();
  switch (region.dateFormat) {
    case 'day-month-year':
      return `${d}.${m}.${y}`;
    case 'month-day-year':
      return `${m}/${d}/${y}`;
    case 'year-month-day':
      return `${y}-${m}-${d}`;
    default:
      return new Intl.DateTimeFormat(cachedLocale(), { day: 'numeric', month: 'short', year: 'numeric' }).format(date);
  }
};

// ---------------------------------------------------------------------------
// Lessons: how to join, which devices
// ---------------------------------------------------------------------------

export const readDevices = () => ({ cameraId: null, microphoneId: null, speakerId: null, ...(readJson(DEVICE_KEY) ?? {}) });
export const writeDevices = (patch) => {
  const next = { ...readDevices(), ...patch };
  writeJson(DEVICE_KEY, next);
  return next;
};

/** Microphone and camera state when a lesson is joined, from Settings → Lessons. */
export const lessonJoinDefaults = () => {
  const { lesson } = cachedPreferences();
  return { startMuted: lesson.joinMicrophone !== 'on', startCameraOff: lesson.joinCamera === 'off' };
};

/** getUserMedia constraints for this device and these preferences. */
export const mediaConstraints = (request = { audio: true, video: true }) => {
  const { lesson } = cachedPreferences();
  const devices = readDevices();
  const base = (value) => (value && typeof value === 'object' ? value : {});

  const audio = request.audio
    ? {
        ...base(request.audio),
        noiseSuppression: lesson.noiseSuppression,
        echoCancellation: lesson.echoCancellation,
        autoGainControl: true,
        // `ideal`, not `exact`: an unplugged device falls back instead of failing.
        ...(devices.microphoneId ? { deviceId: { ideal: devices.microphoneId } } : {}),
      }
    : false;

  const video = request.video
    ? {
        ...base(request.video),
        ...(lesson.dataSaver
          ? { width: { ideal: 640 }, height: { ideal: 360 }, frameRate: { ideal: 15 } }
          : { width: { ideal: 1280 }, height: { ideal: 720 } }),
        ...(devices.cameraId ? { deviceId: { ideal: devices.cameraId } } : {}),
      }
    : false;

  return { audio, video };
};

/**
 * The same device adapter, with every capture using the chosen devices and
 * the audio processing from Settings. A Proxy rather than a copy: the adapter
 * keeps its identity for everything else, and this wrapper is created once per
 * adapter, so the lesson does not rejoin because a setting changed.
 */
export const withMediaPreferences = (adapter) => {
  if (!adapter) return adapter;
  return new Proxy(adapter, {
    get(target, property) {
      if (property === 'getUserMedia') {
        return async (request) => {
          const mediaDevices = globalThis.navigator?.mediaDevices;
          if (!mediaDevices?.getUserMedia) return target.getUserMedia(request);
          try {
            return await mediaDevices.getUserMedia(mediaConstraints(request));
          } catch (cause) {
            // A setting the device cannot meet must never keep someone out of
            // a lesson: capture the way the adapter would have.
            if (cause?.name === 'OverconstrainedError' || cause?.name === 'NotFoundError') {
              return target.getUserMedia(request);
            }
            throw cause;
          }
        };
      }
      // The target as receiver: getters that use private fields must see the real object.
      const value = Reflect.get(target, property);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
};
__PA_EOF__
echo "wrote apps/web/src/lib/preferences.js"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/AppLayout.jsx <<'__PA_EOF__'
import { useEffect, useMemo } from 'react';
import { NavLink, Outlet } from 'react-router-dom';
import { createProfileApi, useCore } from '@classroom/core-client';
import ErrorBoundary from '../components/system/ErrorBoundary.jsx';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';

/**
 * The shell every page except the classroom renders inside.
 *
 * The boundary sits around <Outlet/> rather than around the whole layout, so a
 * page that throws loses the page and keeps the navigation — a user who can
 * still click away from a broken screen is not stuck.
 */
export default function AppLayout() {
  return (
    <div className="app">
      <PreferencesSync />
      <header className="app__bar">
        <span className="app__brand">Classroom</span>
        <nav className="app__nav">
          <NavLink to="/" end>
            Dashboard
          </NavLink>
          <NavLink to="/community">Community</NavLink>
          <NavLink to="/messages">Messages</NavLink>
          <NavLink to="/media">Media</NavLink>
          <NavLink to="/settings">Settings</NavLink>
        </nav>
      </header>

      <main className="app__content">
        <ErrorBoundary area="page">
          <Outlet />
        </ErrorBoundary>
      </main>
    </div>
  );
}

/**
 * Brings this device's copy of the account preferences up to date once per
 * sign-in, so a change made on another device (font size, how lessons start)
 * applies here too. Renders nothing; a failure leaves the cached copy in use.
 */
function PreferencesSync() {
  const { http, status } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    let cancelled = false;
    Promise.all([profiles.getPreferences(), profiles.getOwn()])
      .then(([preferences, own]) => {
        if (cancelled) return;
        cachePreferences(preferences);
        cacheLocale(own.locale);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [profiles, status]);

  return null;
}
__PA_EOF__
echo "wrote apps/web/src/pages/AppLayout.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/SettingsPage.jsx <<'__PA_EOF__'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createProfileApi, useCore } from '@classroom/core-client';

import ProfileSettings from '../components/Settings/ProfileSettings.jsx';
import PrivacySettings from '../components/Settings/PrivacySettings.jsx';
import RegionSettings from '../components/Settings/RegionSettings.jsx';
import LessonSettings from '../components/Settings/LessonSettings.jsx';
import AppearanceSettings from '../components/Settings/AppearanceSettings.jsx';
import TeachingSettings from '../components/Settings/TeachingSettings.jsx';
import { searchSettings } from '../components/Settings/settingsIndex.js';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';
import '../components/Settings/settings.css';

/**
 * Settings  (Phase A)
 *
 * One tab per topic, each with its own address (/settings/<tab>), a search
 * across every setting, and no Save button: every change is saved the moment
 * it is made and can be undone from the notice that confirms it.
 *
 *   profile     how others see you, and a preview of exactly that
 *   privacy     check-up, private messages, visibility, blocked people
 *   region      language, time zone, date and time format
 *   lessons     how you join, sound processing, device test
 *   appearance  text size, motion
 *   teaching    how your lessons start (teachers and owners only)
 */

const ALL_TABS = [
  { id: 'profile', label: 'Profile' },
  { id: 'privacy', label: 'Privacy' },
  { id: 'region', label: 'Language & region' },
  { id: 'lessons', label: 'Lessons' },
  { id: 'appearance', label: 'Appearance' },
  { id: 'teaching', label: 'Teaching', roles: ['teacher', 'owner'] },
];

const pick = (source, keys) => Object.fromEntries(keys.map((key) => [key, source?.[key] ?? null]));

export default function SettingsPage() {
  const { http } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const { tab: tabParam } = useParams();
  const navigate = useNavigate();

  const [own, setOwn] = useState(null);
  const [privacy, setPrivacy] = useState(null);
  const [preferences, setPreferences] = useState(null);
  const [blocks, setBlocks] = useState([]);
  const [loadError, setLoadError] = useState(false);
  const [notice, setNotice] = useState(null);
  const [query, setQuery] = useState('');
  const [highlight, setHighlight] = useState(null);
  const noticeTimer = useRef(null);

  const load = useCallback(async () => {
    setLoadError(false);
    try {
      const [ownProfile, ownPrivacy, ownPreferences, ownBlocks] = await Promise.all([
        profiles.getOwn(),
        profiles.getPrivacy(),
        profiles.getPreferences(),
        profiles.listBlocks({ limit: 100 }),
      ]);
      setOwn(ownProfile);
      setPrivacy(ownPrivacy);
      setPreferences(cachePreferences(ownPreferences));
      setBlocks(ownBlocks.items);
      cacheLocale(ownProfile.locale);
    } catch {
      setLoadError(true);
    }
  }, [profiles]);

  useEffect(() => {
    load();
    return () => window.clearTimeout(noticeTimer.current);
  }, [load]);

  const tabs = useMemo(
    () => ALL_TABS.filter((tab) => !tab.roles || tab.roles.includes(own?.role)),
    [own?.role],
  );
  const tab = tabs.some((t) => t.id === tabParam) ? tabParam : 'profile';

  /* ---- saving, with undo ---- */

  const announce = useCallback((text, undo = null, error = false) => {
    window.clearTimeout(noticeTimer.current);
    setNotice({ text, undo, error });
    noticeTimer.current = window.setTimeout(() => setNotice(null), undo ? 8_000 : 4_000);
  }, []);

  const failed = useCallback(
    (cause) => {
      announce(cause?.detail ?? cause?.message ?? 'That change was not saved. Try again.', null, true);
      throw cause;
    },
    [announce],
  );

  const saveProfile = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(own, Object.keys(patch));
      try {
        const next = await profiles.update(patch);
        setOwn(next);
        if (patch.locale) cacheLocale(next.locale);
        announce(
          `${label} saved.`,
          undoable ? () => saveProfile(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        failed(cause);
      }
    },
    [own, profiles, announce, failed],
  );

  const savePrivacy = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(privacy, Object.keys(patch));
      setPrivacy((current) => ({ ...current, ...patch }));
      try {
        setPrivacy(await profiles.updatePrivacy(patch));
        announce(
          `${label} saved.`,
          undoable ? () => savePrivacy(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        setPrivacy((current) => ({ ...current, ...before }));
        failed(cause);
      }
    },
    [privacy, profiles, announce, failed],
  );

  const savePreferences = useCallback(
    async (section, patch, label, { undoable = true } = {}) => {
      const before = pick(preferences?.[section], Object.keys(patch));
      setPreferences((current) => ({ ...current, [section]: { ...current[section], ...patch } }));
      try {
        const next = await profiles.updatePreferences({ [section]: patch });
        setPreferences(cachePreferences(next));
        announce(
          `${label} saved.`,
          undoable
            ? () => savePreferences(section, before, label, { undoable: false }).then(() => announce(`${label} restored.`))
            : null,
        );
      } catch (cause) {
        setPreferences((current) => ({ ...current, [section]: { ...current[section], ...before } }));
        failed(cause);
      }
    },
    [preferences, profiles, announce, failed],
  );

  const unblock = useCallback(
    async (block) => {
      try {
        await profiles.unblock(block.blockedUserId);
        setBlocks((current) => current.filter((b) => b.blockedUserId !== block.blockedUserId));
        announce(`${block.profile.displayName} is no longer blocked.`, async () => {
          await profiles.block({ userId: block.blockedUserId });
          setBlocks((current) => [block, ...current]);
          announce(`${block.profile.displayName} is blocked again.`);
        });
      } catch (cause) {
        announce(cause?.detail ?? 'That person could not be unblocked.', null, true);
      }
    },
    [profiles, announce],
  );

  /* ---- navigation and search ---- */

  const jumpTo = useCallback(
    (tabId, anchor) => {
      setQuery('');
      navigate(`/settings/${tabId}`);
      setHighlight(anchor);
    },
    [navigate],
  );

  useEffect(() => {
    if (!highlight) return undefined;
    const frame = requestAnimationFrame(() => {
      const el = document.getElementById(`setting-${highlight}`);
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      el?.classList.add('st-flash');
    });
    const timer = window.setTimeout(() => {
      document.getElementById(`setting-${highlight}`)?.classList.remove('st-flash');
      setHighlight(null);
    }, 1_600);
    return () => {
      cancelAnimationFrame(frame);
      window.clearTimeout(timer);
    };
  }, [highlight, tab]);

  const results = useMemo(() => searchSettings(query, tabs), [query, tabs]);

  /* ---- render ---- */

  if (loadError) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-error">Your settings could not be loaded.</p>
        <button type="button" className="btn" onClick={load}>
          Try again
        </button>
      </section>
    );
  }

  if (!own || !privacy || !preferences) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-hint">Loading your settings…</p>
      </section>
    );
  }

  const tabProps = { own, privacy, preferences, blocks, saveProfile, savePrivacy, savePreferences, unblock };

  return (
    <section className="page st-page">
      <header className="st-header">
        <h1>Settings</h1>
        <input
          className="st-search"
          type="search"
          placeholder="Search settings, e.g. microphone or blocked"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          aria-label="Search settings"
        />
      </header>

      <div className="st-layout">
        <nav className="st-nav" aria-label="Settings sections">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              className={t.id === tab && !query ? 'st-nav__item is-active' : 'st-nav__item'}
              aria-current={t.id === tab && !query ? 'page' : undefined}
              onClick={() => {
                setQuery('');
                navigate(`/settings/${t.id}`);
              }}
            >
              {t.label}
            </button>
          ))}
        </nav>

        <div className="st-content">
          {query.trim() ? (
            <div className="st-results" aria-live="polite">
              {results.length === 0 ? <p className="st-hint">No setting matches “{query}”.</p> : null}
              {results.map((entry) => (
                <button key={`${entry.tab}-${entry.anchor}`} type="button" className="st-result" onClick={() => jumpTo(entry.tab, entry.anchor)}>
                  <span className="st-result__label">{entry.label}</span>
                  <span className="st-hint">{tabs.find((t) => t.id === entry.tab)?.label}</span>
                </button>
              ))}
            </div>
          ) : (
            <>
              {tab === 'profile' && <ProfileSettings {...tabProps} />}
              {tab === 'privacy' && <PrivacySettings {...tabProps} onJump={(anchor) => jumpTo('privacy', anchor)} />}
              {tab === 'region' && <RegionSettings {...tabProps} />}
              {tab === 'lessons' && <LessonSettings {...tabProps} />}
              {tab === 'appearance' && <AppearanceSettings {...tabProps} />}
              {tab === 'teaching' && <TeachingSettings {...tabProps} />}
            </>
          )}
        </div>
      </div>

      {notice ? (
        <div className={notice.error ? 'st-notice st-notice--error' : 'st-notice'} role="status" aria-live="polite">
          <span>{notice.text}</span>
          {notice.undo ? (
            <button
              type="button"
              className="st-notice__undo"
              onClick={() => {
                const undo = notice.undo;
                setNotice(null);
                undo().catch(() => undefined);
              }}
            >
              Undo
            </button>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
__PA_EOF__
echo "wrote apps/web/src/pages/SettingsPage.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/fields.jsx <<'__PA_EOF__'
import { useEffect, useId, useState } from 'react';

/**
 * Small building blocks shared by every settings tab. Each control saves on
 * its own — a switch when flipped, a text field when it loses focus or Enter
 * is pressed — so there is no Save button to forget.
 */

export function Section({ id, title, hint, children }) {
  return (
    <section className="st-section" id={id ? `setting-${id}` : undefined}>
      <h2 className="st-section__title">{title}</h2>
      {hint ? <p className="st-hint">{hint}</p> : null}
      <div className="st-section__body">{children}</div>
    </section>
  );
}

export function Toggle({ id, label, hint, checked, disabled, onChange }) {
  const inputId = useId();
  return (
    <div className="st-row" id={id ? `setting-${id}` : undefined}>
      <label className="st-toggle" htmlFor={inputId}>
        <span className="st-toggle__text">
          <span className="st-label">{label}</span>
          {hint ? <span className="st-hint">{hint}</span> : null}
        </span>
        <input
          id={inputId}
          type="checkbox"
          role="switch"
          className="st-switch"
          checked={Boolean(checked)}
          disabled={disabled}
          // Errors are reported by the page's notice; nothing to handle here.
          onChange={(event) => Promise.resolve(onChange(event.target.checked)).catch(() => undefined)}
        />
      </label>
    </div>
  );
}

export function Choice({ id, label, hint, value, options, disabled, onChange }) {
  const name = useId();
  return (
    <fieldset className="st-row st-choice" id={id ? `setting-${id}` : undefined}>
      <legend className="st-label">{label}</legend>
      {hint ? <p className="st-hint">{hint}</p> : null}
      <div className="st-choice__options">
        {options.map((option) => (
          <label key={option.value} className="st-choice__option" data-selected={value === option.value}>
            <input
              type="radio"
              name={name}
              value={option.value}
              checked={value === option.value}
              disabled={disabled}
              onChange={() => Promise.resolve(onChange(option.value)).catch(() => undefined)}
            />
            <span>
              <span className="st-choice__title">{option.title}</span>
              {option.hint ? <span className="st-hint">{option.hint}</span> : null}
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

/** A text field that saves when it loses focus or Enter is pressed, and only if it changed. */
export function TextField({ id, label, hint, value, placeholder, maxLength, multiline = false, prefix, onSave }) {
  const inputId = useId();
  const [draft, setDraft] = useState(value ?? '');
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => setDraft(value ?? ''), [value]);

  const commit = async () => {
    const next = draft.trim();
    if (next === (value ?? '').trim()) return;
    setBusy(true);
    setError(null);
    try {
      await onSave(next);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not saved.');
    } finally {
      setBusy(false);
    }
  };

  const Input = multiline ? 'textarea' : 'input';

  return (
    <div className="st-row" id={id ? `setting-${id}` : undefined}>
      <label className="st-label" htmlFor={inputId}>
        {label}
      </label>
      {hint ? <p className="st-hint">{hint}</p> : null}
      <div className="st-input">
        {prefix ? <span className="st-input__prefix">{prefix}</span> : null}
        <Input
          id={inputId}
          className="st-input__field"
          value={draft}
          placeholder={placeholder}
          maxLength={maxLength}
          rows={multiline ? 4 : undefined}
          disabled={busy}
          aria-invalid={Boolean(error)}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={commit}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !multiline) event.currentTarget.blur();
            if (event.key === 'Escape') {
              setDraft(value ?? '');
              setError(null);
            }
          }}
        />
      </div>
      {multiline && maxLength ? (
        <p className="st-hint st-count">
          {draft.length} / {maxLength}
        </p>
      ) : null}
      {error ? <p className="st-error">{error}</p> : null}
    </div>
  );
}
__PA_EOF__
echo "wrote apps/web/src/components/Settings/fields.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/settingsIndex.js <<'__PA_EOF__'
/**
 * Everything the settings search can find. `anchor` is the id of the element
 * on the tab (`setting-<anchor>`); keywords are the words people actually type.
 */
export const SETTINGS_INDEX = [
  { tab: 'profile', anchor: 'display-name', label: 'Display name', keywords: 'name full name rename' },
  { tab: 'profile', anchor: 'handle', label: 'Handle for @mentions', keywords: 'username handle mention @' },
  { tab: 'profile', anchor: 'headline', label: 'Headline', keywords: 'title tagline headline' },
  { tab: 'profile', anchor: 'bio', label: 'About me', keywords: 'bio about description' },
  { tab: 'profile', anchor: 'links', label: 'Links', keywords: 'website link url portfolio' },
  { tab: 'profile', anchor: 'view-as', label: 'View your profile as someone else', keywords: 'preview view as how others see' },
  { tab: 'privacy', anchor: 'checkup', label: 'Privacy check-up', keywords: 'overview summary privacy' },
  { tab: 'privacy', anchor: 'dm', label: 'Who can send you private messages', keywords: 'dm direct message private chat receive messages' },
  { tab: 'privacy', anchor: 'visibility', label: 'Who can see your profile', keywords: 'visibility profile hidden private' },
  { tab: 'privacy', anchor: 'presence', label: 'Show when I am online', keywords: 'online status presence' },
  { tab: 'privacy', anchor: 'receipts', label: 'Read receipts', keywords: 'read seen receipts' },
  { tab: 'privacy', anchor: 'blocked', label: 'Blocked people', keywords: 'block unblock blocked' },
  { tab: 'region', anchor: 'language', label: 'Language', keywords: 'language locale' },
  { tab: 'region', anchor: 'timezone', label: 'Time zone', keywords: 'time zone timezone clock' },
  { tab: 'region', anchor: 'date-format', label: 'Date format', keywords: 'date format day month year' },
  { tab: 'region', anchor: 'time-format', label: 'Time format', keywords: 'time 24 12 hour am pm' },
  { tab: 'lessons', anchor: 'join', label: 'Microphone and camera when joining', keywords: 'join muted mic microphone camera video start' },
  { tab: 'lessons', anchor: 'audio', label: 'Noise suppression and echo cancellation', keywords: 'noise echo audio sound' },
  { tab: 'lessons', anchor: 'data-saver', label: 'Data saver', keywords: 'data saver bandwidth mobile quality' },
  { tab: 'lessons', anchor: 'devices', label: 'Camera, microphone and speaker test', keywords: 'device test camera webcam microphone mic speaker headset sound' },
  { tab: 'appearance', anchor: 'font-size', label: 'Text size', keywords: 'font text size bigger smaller zoom' },
  { tab: 'appearance', anchor: 'motion', label: 'Reduce motion', keywords: 'motion animation reduce' },
  { tab: 'teaching', anchor: 'reactions', label: 'Reactions in your lessons', keywords: 'emoji reactions lesson default' },
  { tab: 'teaching', anchor: 'join-muted', label: 'Learners join muted', keywords: 'muted join learners microphone default' },
];

export const searchSettings = (query, tabs) => {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];
  const allowed = new Set(tabs.map((t) => t.id));
  return SETTINGS_INDEX.filter(
    (entry) =>
      allowed.has(entry.tab) &&
      words.every((word) => `${entry.label} ${entry.keywords}`.toLowerCase().includes(word)),
  );
};
__PA_EOF__
echo "wrote apps/web/src/components/Settings/settingsIndex.js"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/ProfileSettings.jsx <<'__PA_EOF__'
import { useState } from 'react';
import { Section, TextField } from './fields.jsx';

/**
 * Profile: how you appear to others, and a preview of exactly that.
 *
 * "View as" applies the same rules the server applies when someone opens your
 * profile card (profile.routes → Profile.applyVisibility, and
 * ConversationService.canMessage for the Message button), to your current
 * settings — so what it shows is what they get.
 */

const VIEWERS = [
  { id: 'classmate', label: 'A classmate', hint: 'someone who shares a course, space or lesson with you' },
  { id: 'teacher', label: 'A teacher', hint: 'a teacher in your organisation' },
  { id: 'other', label: 'Someone else', hint: 'anyone else in your organisation' },
];

export const previewFor = (viewer, { privacy }) => {
  const shares = viewer === 'classmate' || viewer === 'teacher';
  const visibility = privacy.visibility ?? 'tenant';
  const seesDetails = visibility === 'tenant' || (visibility === 'shared-only' && shares);

  let canMessage;
  if (viewer === 'teacher') canMessage = true;
  else if (privacy.dmPolicy === 'anyone') canMessage = true;
  else if (privacy.dmPolicy === 'nobody') canMessage = false;
  else canMessage = viewer === 'classmate';

  return { seesDetails, canMessage, seesOnline: privacy.showPresence !== false };
};

function ViewAsPreview({ own, privacy }) {
  const [viewer, setViewer] = useState('classmate');
  const view = previewFor(viewer, { privacy });

  return (
    <Section id="view-as" title="View your profile as someone else" hint="Exactly what they see when they click your name.">
      <div className="st-segmented" role="tablist" aria-label="Viewer">
        {VIEWERS.map((v) => (
          <button
            key={v.id}
            type="button"
            role="tab"
            aria-selected={viewer === v.id}
            className={viewer === v.id ? 'st-segmented__item is-active' : 'st-segmented__item'}
            onClick={() => setViewer(v.id)}
            title={v.hint}
          >
            {v.label}
          </button>
        ))}
      </div>

      <div className="st-card" aria-live="polite">
        <div className="st-card__identity">
          <span className="st-avatar" aria-hidden="true">
            {(own.displayName ?? '?').charAt(0).toUpperCase()}
          </span>
          <div>
            <p className="st-card__name">{own.displayName}</p>
            <p className="st-hint">
              {own.handle ? `@${own.handle} · ` : ''}
              {own.role}
              {view.seesOnline ? ' · online status shown' : ' · online status hidden'}
            </p>
          </div>
        </div>

        {view.seesDetails ? (
          <>
            {own.headline ? <p className="st-card__headline">{own.headline}</p> : null}
            {own.bio ? <p className="st-card__bio">{own.bio}</p> : null}
            {own.links?.length ? (
              <ul className="st-card__links">
                {own.links.map((link) => (
                  <li key={link.url}>{link.label}</li>
                ))}
              </ul>
            ) : null}
            {!own.headline && !own.bio && !own.links?.length ? (
              <p className="st-hint">Nothing else to show yet — add a headline or something about you.</p>
            ) : null}
          </>
        ) : (
          <p className="st-hint">Only your name is shown. Headline, about and links are hidden from them.</p>
        )}

        <p className={view.canMessage ? 'st-card__verdict' : 'st-card__verdict st-card__verdict--no'}>
          {view.canMessage ? 'They can send you a private message.' : 'They cannot send you a private message.'}
        </p>
      </div>
    </Section>
  );
}

export default function ProfileSettings({ own, privacy, saveProfile }) {
  const links = own.links ?? [];

  const saveLinks = (next) => saveProfile({ links: next }, 'Links');

  return (
    <>
      <Section title="How others see you" hint="Changes are saved when you leave a field.">
        <TextField
          id="display-name"
          label="Display name"
          value={own.displayName}
          maxLength={80}
          onSave={(value) => {
            if (!value) throw new Error('A name cannot be empty.');
            return saveProfile({ displayName: value }, 'Display name');
          }}
        />
        <TextField
          id="handle"
          label="Handle"
          hint="Used for @mentions. 3–32 lowercase letters, digits or underscores."
          prefix="@"
          value={own.handle}
          maxLength={32}
          onSave={(value) => saveProfile({ handle: value.toLowerCase() }, 'Handle')}
        />
        <TextField
          id="headline"
          label="Headline"
          hint="One line under your name, e.g. “Maths teacher” or “Studying biology”."
          value={own.headline}
          maxLength={140}
          onSave={(value) => saveProfile({ headline: value || null }, 'Headline')}
        />
        <TextField
          id="bio"
          label="About me"
          value={own.bio}
          maxLength={2000}
          multiline
          onSave={(value) => saveProfile({ bio: value || null }, 'About me')}
        />
      </Section>

      <Section id="links" title="Links" hint="Up to five, e.g. a portfolio or a course website.">
        {links.map((link, index) => (
          <div key={`${link.url}-${index}`} className="st-link">
            <span className="st-link__label">{link.label}</span>
            <span className="st-link__url">{link.url}</span>
            <button
              type="button"
              className="btn btn--tiny"
              onClick={() => saveLinks(links.filter((_, i) => i !== index)).catch(() => undefined)}
            >
              Remove
            </button>
          </div>
        ))}
        {links.length < 5 ? <AddLink onAdd={(link) => saveLinks([...links, link])} /> : null}
      </Section>

      <ViewAsPreview own={own} privacy={privacy} />
    </>
  );
}

function AddLink({ onAdd }) {
  const [label, setLabel] = useState('');
  const [url, setUrl] = useState('');
  const [error, setError] = useState(null);

  const add = async (event) => {
    event.preventDefault();
    setError(null);
    let normalised = url.trim();
    if (normalised && !/^https?:\/\//i.test(normalised)) normalised = `https://${normalised}`;
    try {
      // eslint-disable-next-line no-new
      new URL(normalised);
    } catch {
      setError('That does not look like a web address.');
      return;
    }
    try {
      await onAdd({ label: label.trim() || new URL(normalised).hostname, url: normalised });
      setLabel('');
      setUrl('');
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not saved.');
    }
  };

  return (
    <form className="st-link-form" onSubmit={add}>
      <input className="st-input__field" placeholder="Label (optional)" value={label} maxLength={40} onChange={(e) => setLabel(e.target.value)} aria-label="Link label" />
      <input className="st-input__field" placeholder="https://…" value={url} onChange={(e) => setUrl(e.target.value)} aria-label="Link address" />
      <button type="submit" className="btn btn--tiny" disabled={!url.trim()}>
        Add link
      </button>
      {error ? <p className="st-error">{error}</p> : null}
    </form>
  );
}
__PA_EOF__
echo "wrote apps/web/src/components/Settings/ProfileSettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/PrivacySettings.jsx <<'__PA_EOF__'
import { Choice, Section, Toggle } from './fields.jsx';
import { formatDate } from '../../lib/preferences.js';

/**
 * Privacy: a plain-language summary first, then every setting it summarises.
 * Every line of the check-up is a consequence of one setting below and links
 * to it.
 */

const DM_OPTIONS = [
  { value: 'anyone', title: 'Anyone in your organisation' },
  {
    value: 'shared-context',
    title: 'People you share a course, space or lesson with',
    hint: 'Recommended. Classmates and the people in a running lesson with you.',
  },
  { value: 'nobody', title: 'Nobody', hint: 'Chats you already have keep working.' },
];

const VISIBILITY_OPTIONS = [
  { value: 'tenant', title: 'Everyone in your organisation', hint: 'Headline, about and links are on your profile card.' },
  { value: 'shared-only', title: 'People you share a course, space or lesson with', hint: 'Everyone else sees your name only.' },
  { value: 'private', title: 'Only your name', hint: 'Nobody sees your headline, about or links.' },
];

export const checkupLines = (privacy, blockCount) => [
  {
    anchor: 'dm',
    text:
      privacy.dmPolicy === 'anyone'
        ? 'Anyone in your organisation can start a private chat with you.'
        : privacy.dmPolicy === 'nobody'
          ? 'Nobody can start a new private chat with you — except teachers.'
          : 'People you share a course, space or lesson with can start a private chat with you.',
  },
  {
    anchor: 'visibility',
    text:
      privacy.visibility === 'private'
        ? 'Others see only your name.'
        : privacy.visibility === 'shared-only'
          ? 'Only people you share something with see your headline, about and links.'
          : 'Everyone in your organisation sees your headline, about and links.',
  },
  {
    anchor: 'presence',
    text: privacy.showPresence !== false ? 'Others can see when you are online.' : 'Your online status is hidden.',
  },
  {
    anchor: 'receipts',
    text:
      privacy.sendReadReceipts !== false
        ? 'People see when you have read their messages.'
        : 'Read receipts are off — both ways.',
  },
  {
    anchor: 'blocked',
    text: blockCount === 0 ? 'You have not blocked anyone.' : `You have blocked ${blockCount} ${blockCount === 1 ? 'person' : 'people'}.`,
  },
];

export default function PrivacySettings({ privacy, blocks, savePrivacy, unblock, onJump }) {
  return (
    <>
      <Section id="checkup" title="Privacy check-up" hint="Where you stand right now. Click a line to change it.">
        <ul className="st-checkup">
          {checkupLines(privacy, blocks.length).map((line) => (
            <li key={line.anchor}>
              <button type="button" className="st-checkup__line" onClick={() => onJump(line.anchor)}>
                {line.text}
              </button>
            </li>
          ))}
        </ul>
      </Section>

      <Section title="Private messages">
        <Choice
          id="dm"
          label="Who can send you private messages"
          hint="Teachers can always reach you, so a course can contact its participants. A block — for your account or for one lesson — stops everyone, teachers included."
          value={privacy.dmPolicy}
          options={DM_OPTIONS}
          onChange={(value) => savePrivacy({ dmPolicy: value }, 'Private messages')}
        />
      </Section>

      <Section title="Your profile">
        <Choice
          id="visibility"
          label="Who can see your profile"
          hint="Your name and role are always shown, so people know who they are talking to."
          value={privacy.visibility ?? 'tenant'}
          options={VISIBILITY_OPTIONS}
          onChange={(value) => savePrivacy({ visibility: value }, 'Profile visibility')}
        />
        <Toggle
          id="presence"
          label="Show when I am online"
          hint="Off: you appear offline to others wherever online status is shown."
          checked={privacy.showPresence !== false}
          onChange={(value) => savePrivacy({ showPresence: value }, 'Online status')}
        />
        <Toggle
          id="receipts"
          label="Send read receipts"
          hint="Off means you also stop seeing whether others have read your messages."
          checked={privacy.sendReadReceipts !== false}
          onChange={(value) => savePrivacy({ sendReadReceipts: value }, 'Read receipts')}
        />
      </Section>

      <Section
        id="blocked"
        title="Blocked people"
        hint="Blocked people cannot write to you and you cannot write to them. Blocks made only for one lesson end with that lesson and are not listed here."
      >
        {blocks.length === 0 ? <p className="st-hint">You have not blocked anyone.</p> : null}
        {blocks.map((block) => (
          <div key={block.blockedUserId} className="st-link">
            <span className="st-link__label">{block.profile.displayName}</span>
            <span className="st-link__url">{block.blockedAt ? `since ${formatDate(block.blockedAt)}` : ''}</span>
            <button type="button" className="btn btn--tiny" onClick={() => unblock(block)}>
              Unblock
            </button>
          </div>
        ))}
      </Section>
    </>
  );
}
__PA_EOF__
echo "wrote apps/web/src/components/Settings/PrivacySettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/RegionSettings.jsx <<'__PA_EOF__'
import { useMemo, useState } from 'react';
import { Choice, Section } from './fields.jsx';
import { formatDate, formatTime } from '../../lib/preferences.js';

/**
 * Language & region. Language and time zone are stored on the account; date
 * and time format with the other preferences. Every option shows today's date
 * or the current time in that format, so nobody has to guess what "YYYY-MM-DD"
 * means.
 */

const LANGUAGES = [
  ['en', 'English'],
  ['de', 'Deutsch'],
  ['fr', 'Français'],
  ['es', 'Español'],
  ['it', 'Italiano'],
  ['nl', 'Nederlands'],
  ['pl', 'Polski'],
  ['pt', 'Português'],
  ['tr', 'Türkçe'],
];

const zones = () => {
  try {
    return Intl.supportedValuesOf('timeZone');
  } catch {
    return ['UTC'];
  }
};

export default function RegionSettings({ own, preferences, saveProfile, savePreferences }) {
  const now = new Date();
  const deviceZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const allZones = useMemo(zones, []);
  const [filter, setFilter] = useState('');
  const shownZones = useMemo(() => {
    const needle = filter.trim().toLowerCase().replace(/\s+/g, '_');
    const list = needle ? allZones.filter((z) => z.toLowerCase().includes(needle)) : allZones;
    return list.includes(own.timeZone) || !own.timeZone ? list : [own.timeZone, ...list];
  }, [allZones, filter, own.timeZone]);

  const region = preferences.region;

  return (
    <>
      <Section id="language" title="Language" hint="Sets how dates, times and numbers are written. The app's own texts are in English for now.">
        <select
          className="st-select"
          value={(own.locale ?? 'en').slice(0, 2)}
          onChange={(event) => saveProfile({ locale: event.target.value }, 'Language').catch(() => undefined)}
          aria-label="Language"
        >
          {LANGUAGES.map(([code, name]) => (
            <option key={code} value={code}>
              {name}
            </option>
          ))}
        </select>
      </Section>

      <Section id="timezone" title="Time zone" hint="Lesson times and reminders are shown in this time zone.">
        <div className="st-inline">
          <input
            className="st-input__field"
            type="search"
            placeholder="Filter, e.g. Berlin"
            value={filter}
            onChange={(event) => setFilter(event.target.value)}
            aria-label="Filter time zones"
          />
          <select
            className="st-select"
            value={own.timeZone ?? ''}
            onChange={(event) => saveProfile({ timeZone: event.target.value }, 'Time zone').catch(() => undefined)}
            aria-label="Time zone"
          >
            {shownZones.map((zone) => (
              <option key={zone} value={zone}>
                {zone.replace(/_/g, ' ')}
              </option>
            ))}
          </select>
        </div>
        {deviceZone && deviceZone !== own.timeZone ? (
          <button type="button" className="btn btn--tiny" onClick={() => saveProfile({ timeZone: deviceZone }, 'Time zone').catch(() => undefined)}>
            Use this device’s time zone ({deviceZone.replace(/_/g, ' ')})
          </button>
        ) : null}
      </Section>

      <Section title="Formats">
        <Choice
          id="date-format"
          label="Date format"
          value={region.dateFormat}
          options={[
            { value: 'auto', title: `From your language — ${formatDate(now, { ...region, dateFormat: 'auto' })}` },
            { value: 'day-month-year', title: `Day.Month.Year — ${formatDate(now, { ...region, dateFormat: 'day-month-year' })}` },
            { value: 'month-day-year', title: `Month/Day/Year — ${formatDate(now, { ...region, dateFormat: 'month-day-year' })}` },
            { value: 'year-month-day', title: `Year-Month-Day — ${formatDate(now, { ...region, dateFormat: 'year-month-day' })}` },
          ]}
          onChange={(value) => savePreferences('region', { dateFormat: value }, 'Date format')}
        />
        <Choice
          id="time-format"
          label="Time format"
          value={region.timeFormat}
          options={[
            { value: 'auto', title: `From your language — ${formatTime(now, { ...region, timeFormat: 'auto' })}` },
            { value: '24h', title: `24-hour — ${formatTime(now, { ...region, timeFormat: '24h' })}` },
            { value: '12h', title: `12-hour — ${formatTime(now, { ...region, timeFormat: '12h' })}` },
          ]}
          onChange={(value) => savePreferences('region', { timeFormat: value }, 'Time format')}
        />
      </Section>
    </>
  );
}
__PA_EOF__
echo "wrote apps/web/src/components/Settings/RegionSettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/LessonSettings.jsx <<'__PA_EOF__'
import { useCallback, useEffect, useRef, useState } from 'react';
import { Choice, Section, Toggle } from './fields.jsx';
import { mediaConstraints, readDevices, writeDevices } from '../../lib/preferences.js';

/**
 * Lessons: how you join, how your audio is processed, and a test of camera,
 * microphone and speaker with the exact settings a lesson will use
 * (lib/preferences.mediaConstraints) — so a test that works here means the
 * lesson will work the same way.
 */
export default function LessonSettings({ preferences, savePreferences }) {
  const lesson = preferences.lesson;
  return (
    <>
      <Section id="join" title="When you join a lesson">
        <Choice
          label="Microphone"
          value={lesson.joinMicrophone}
          options={[
            { value: 'off', title: 'Off — I unmute when I want to speak', hint: 'Recommended.' },
            { value: 'on', title: 'On' },
          ]}
          onChange={(value) => savePreferences('lesson', { joinMicrophone: value }, 'Microphone when joining')}
        />
        <Choice
          label="Camera"
          value={lesson.joinCamera}
          options={[
            { value: 'on', title: 'On' },
            { value: 'off', title: 'Off — I start it when I want to' },
          ]}
          onChange={(value) => savePreferences('lesson', { joinCamera: value }, 'Camera when joining')}
        />
        <p className="st-hint">
          If the teacher has set their lesson to start with everyone muted, your microphone starts off either way.
        </p>
      </Section>

      <Section id="audio" title="Sound">
        <Toggle
          label="Noise suppression"
          hint="Filters out keyboard, fan and street noise."
          checked={lesson.noiseSuppression}
          onChange={(value) => savePreferences('lesson', { noiseSuppression: value }, 'Noise suppression')}
        />
        <Toggle
          label="Echo cancellation"
          hint="Keep this on unless you use a headset and a professional microphone."
          checked={lesson.echoCancellation}
          onChange={(value) => savePreferences('lesson', { echoCancellation: value }, 'Echo cancellation')}
        />
      </Section>

      <Section title="Connection">
        <Toggle
          id="data-saver"
          label="Data saver"
          hint="Sends your video in lower quality (360p, 15 frames per second). Good on mobile data or a weak connection."
          checked={lesson.dataSaver}
          onChange={(value) => savePreferences('lesson', { dataSaver: value }, 'Data saver')}
        />
      </Section>

      <DeviceTest lesson={lesson} />
    </>
  );
}

const canPickSpeaker = () =>
  typeof HTMLMediaElement !== 'undefined' && typeof HTMLMediaElement.prototype.setSinkId === 'function';

function DeviceTest({ lesson }) {
  const [devices, setDevices] = useState({ cameras: [], microphones: [], speakers: [] });
  const [chosen, setChosen] = useState(readDevices);
  const [running, setRunning] = useState(false);
  const [level, setLevel] = useState(0);
  const [error, setError] = useState(null);

  const videoRef = useRef(null);
  const streamRef = useRef(null);
  const audioRef = useRef({ context: null, frame: 0 });

  const listDevices = useCallback(async () => {
    const all = await navigator.mediaDevices.enumerateDevices();
    const named = (kind, fallback) =>
      all.filter((d) => d.kind === kind).map((d, i) => ({ id: d.deviceId, label: d.label || `${fallback} ${i + 1}` }));
    setDevices({
      cameras: named('videoinput', 'Camera'),
      microphones: named('audioinput', 'Microphone'),
      speakers: named('audiooutput', 'Speaker'),
    });
  }, []);

  const stop = useCallback(() => {
    cancelAnimationFrame(audioRef.current.frame);
    audioRef.current.context?.close().catch(() => undefined);
    audioRef.current = { context: null, frame: 0 };
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    setLevel(0);
    setRunning(false);
  }, []);

  const start = useCallback(async () => {
    stop();
    setError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia(mediaConstraints({ audio: true, video: true }));
      streamRef.current = stream;
      if (videoRef.current) videoRef.current.srcObject = stream;

      const AudioContextClass = window.AudioContext ?? window.webkitAudioContext;
      if (AudioContextClass && stream.getAudioTracks().length) {
        const context = new AudioContextClass();
        const analyser = context.createAnalyser();
        analyser.fftSize = 512;
        context.createMediaStreamSource(stream).connect(analyser);
        const data = new Uint8Array(analyser.fftSize);
        const tick = () => {
          analyser.getByteTimeDomainData(data);
          let peak = 0;
          for (const value of data) peak = Math.max(peak, Math.abs(value - 128));
          setLevel(Math.min(1, peak / 64));
          audioRef.current.frame = requestAnimationFrame(tick);
        };
        audioRef.current = { context, frame: requestAnimationFrame(tick) };
      }

      setRunning(true);
      await listDevices(); // labels are only available after permission
    } catch (cause) {
      setError(
        cause?.name === 'NotAllowedError'
          ? 'The browser was not allowed to use your camera and microphone. Allow it in the address bar and try again.'
          : cause?.name === 'NotFoundError'
            ? 'No camera or microphone was found.'
            : 'The test could not start. Check that no other app is using your camera.',
      );
      stop();
    }
  }, [listDevices, stop]);

  useEffect(() => {
    if (navigator.mediaDevices?.enumerateDevices) listDevices().catch(() => undefined);
    return stop;
  }, [listDevices, stop]);

  // Settings that change the capture restart a running test with them.
  const restartKey = `${chosen.cameraId}|${chosen.microphoneId}|${lesson.noiseSuppression}|${lesson.echoCancellation}|${lesson.dataSaver}`;
  const firstRun = useRef(true);
  useEffect(() => {
    if (firstRun.current) {
      firstRun.current = false;
      return;
    }
    if (running) start();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [restartKey]);

  const choose = (patch) => setChosen(writeDevices(patch));

  const playTone = async () => {
    const AudioContextClass = window.AudioContext ?? window.webkitAudioContext;
    if (!AudioContextClass) return;
    const context = new AudioContextClass();
    const oscillator = context.createOscillator();
    const gain = context.createGain();
    oscillator.frequency.value = 523.25;
    gain.gain.setValueAtTime(0.0001, context.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.2, context.currentTime + 0.05);
    gain.gain.exponentialRampToValueAtTime(0.0001, context.currentTime + 0.9);
    oscillator.connect(gain);

    if (chosen.speakerId && canPickSpeaker()) {
      const destination = context.createMediaStreamDestination();
      gain.connect(destination);
      const audio = new Audio();
      audio.srcObject = destination.stream;
      await audio.setSinkId(chosen.speakerId).catch(() => undefined);
      await audio.play().catch(() => undefined);
    } else {
      gain.connect(context.destination);
    }
    oscillator.start();
    oscillator.stop(context.currentTime + 1);
    oscillator.onended = () => context.close().catch(() => undefined);
  };

  const noDevices = !navigator.mediaDevices?.getUserMedia;

  return (
    <Section
      id="devices"
      title="Camera, microphone and speaker"
      hint="Camera and microphone choices are remembered on this device and used in your lessons, with the sound settings above. Lessons play sound through your system's default output."
    >
      {noDevices ? <p className="st-error">This browser cannot use a camera or microphone.</p> : null}

      <div className="st-devices">
        <video ref={videoRef} className="st-devices__preview" autoPlay playsInline muted aria-label="Camera preview" />

        <div className="st-devices__controls">
          <label className="st-label">
            Camera
            <select className="st-select" value={chosen.cameraId ?? ''} onChange={(e) => choose({ cameraId: e.target.value || null })}>
              <option value="">Default</option>
              {devices.cameras.map((d) => (
                <option key={d.id} value={d.id}>{d.label}</option>
              ))}
            </select>
          </label>

          <label className="st-label">
            Microphone
            <select className="st-select" value={chosen.microphoneId ?? ''} onChange={(e) => choose({ microphoneId: e.target.value || null })}>
              <option value="">Default</option>
              {devices.microphones.map((d) => (
                <option key={d.id} value={d.id}>{d.label}</option>
              ))}
            </select>
          </label>

          <div className="st-meter" role="meter" aria-label="Microphone level" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(level * 100)}>
            <span className="st-meter__bar" style={{ width: `${Math.round(level * 100)}%` }} />
          </div>
          <p className="st-hint">{running ? 'Speak: the bar should move.' : 'Start the test to see your camera and microphone level.'}</p>

          {canPickSpeaker() ? (
            <label className="st-label">
              Speaker for the test sound
              <select className="st-select" value={chosen.speakerId ?? ''} onChange={(e) => choose({ speakerId: e.target.value || null })}>
                <option value="">Default</option>
                {devices.speakers.map((d) => (
                  <option key={d.id} value={d.id}>{d.label}</option>
                ))}
              </select>
            </label>
          ) : null}

          <div className="st-inline">
            <button type="button" className="btn" onClick={running ? stop : start} disabled={noDevices}>
              {running ? 'Stop test' : 'Start test'}
            </button>
            <button type="button" className="btn btn--tiny" onClick={playTone}>
              Play test sound
            </button>
          </div>
          {error ? <p className="st-error">{error}</p> : null}
        </div>
      </div>
    </Section>
  );
}
__PA_EOF__
echo "wrote apps/web/src/components/Settings/LessonSettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/AppearanceSettings.jsx <<'__PA_EOF__'
import { Choice, Section, Toggle } from './fields.jsx';

/** Appearance: text size and motion. Applied at once and on every device you sign in on. */
export default function AppearanceSettings({ preferences, savePreferences }) {
  const appearance = preferences.appearance;
  return (
    <>
      <Section title="Reading">
        <Choice
          id="font-size"
          label="Text size"
          value={appearance.fontScale}
          options={[
            { value: 'small', title: 'Small' },
            { value: 'default', title: 'Default' },
            { value: 'large', title: 'Large' },
            { value: 'x-large', title: 'Extra large' },
          ]}
          onChange={(value) => savePreferences('appearance', { fontScale: value }, 'Text size')}
        />
        <p className="st-sample">The quick brown fox jumps over the lazy dog — this is how text reads now.</p>
      </Section>

      <Section title="Motion">
        <Toggle
          id="motion"
          label="Reduce motion"
          hint="Turns off animations and transitions, including flying reactions in a lesson."
          checked={appearance.reduceMotion}
          onChange={(value) => savePreferences('appearance', { reduceMotion: value }, 'Reduce motion')}
        />
      </Section>
    </>
  );
}
__PA_EOF__
echo "wrote apps/web/src/components/Settings/AppearanceSettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/TeachingSettings.jsx <<'__PA_EOF__'
import { Section, Toggle } from './fields.jsx';

/**
 * Teaching: how lessons you open start. Applied by the server when a lesson
 * is created with you as its host; a lesson that is already running keeps its
 * settings (change those in the lesson itself).
 */
export default function TeachingSettings({ preferences, savePreferences }) {
  const defaults = preferences.roomDefaults;
  return (
    <Section title="Your lessons start with" hint="Applies to lessons you open from now on.">
      <Toggle
        id="reactions"
        label="Emoji reactions on"
        hint="Off: only you can react until you switch reactions on in the lesson."
        checked={defaults.reactionsEnabled}
        onChange={(value) => savePreferences('roomDefaults', { reactionsEnabled: value }, 'Reactions default')}
      />
      <Toggle
        id="join-muted"
        label="Learners join with their microphone off"
        hint="They can unmute themselves. Helpful from about ten participants on."
        checked={defaults.learnersJoinMuted}
        onChange={(value) => savePreferences('roomDefaults', { learnersJoinMuted: value }, 'Join muted default')}
      />
    </Section>
  );
}
__PA_EOF__
echo "wrote apps/web/src/components/Settings/TeachingSettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/settings.css <<'__PA_EOF__'
/* Settings — see pages/SettingsPage.jsx */

.st-page { max-width: 980px; }
.st-header { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; justify-content: space-between; }
.st-header h1 { margin: 0; }
.st-search { flex: 0 1 340px; min-width: 200px; padding: 8px 12px; border-radius: 8px; border: 1px solid rgba(127,127,127,.4); font: inherit; background: transparent; color: inherit; }

.st-layout { display: grid; grid-template-columns: 200px 1fr; gap: 28px; margin-top: 18px; align-items: start; }
.st-nav { position: sticky; top: 12px; display: flex; flex-direction: column; gap: 2px; }
.st-nav__item { text-align: start; padding: 8px 12px; border: 0; border-radius: 8px; background: transparent; color: inherit; font: inherit; cursor: pointer; }
.st-nav__item:hover, .st-nav__item:focus-visible { background: rgba(127,127,127,.12); }
.st-nav__item.is-active { background: rgba(37,99,235,.14); font-weight: 700; }

@media (max-width: 720px) {
  .st-layout { grid-template-columns: 1fr; gap: 12px; }
  .st-nav { position: static; flex-direction: row; overflow-x: auto; }
  .st-nav__item { white-space: nowrap; }
}

.st-content { display: flex; flex-direction: column; gap: 26px; min-width: 0; }
.st-section { display: flex; flex-direction: column; gap: 10px; border-radius: 10px; transition: box-shadow .3s; }
.st-section__title { margin: 0; font-size: 1.1rem; }
.st-section__body { display: flex; flex-direction: column; gap: 16px; }

.st-row { display: flex; flex-direction: column; gap: 6px; border: 0; margin: 0; padding: 0; border-radius: 8px; transition: box-shadow .3s; }
.st-flash { box-shadow: 0 0 0 3px rgba(37,99,235,.45); }
.st-label { font-weight: 600; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.st-hint { margin: 0; font-size: .85rem; opacity: .72; font-weight: 400; }
.st-error { margin: 0; font-size: .85rem; color: #b91c1c; }
.st-count { text-align: end; }

.st-toggle { display: flex; align-items: center; justify-content: space-between; gap: 16px; cursor: pointer; }
.st-toggle__text { display: flex; flex-direction: column; gap: 2px; }
.st-switch { appearance: none; flex: 0 0 auto; width: 42px; height: 24px; border-radius: 12px; background: rgba(127,127,127,.45); position: relative; cursor: pointer; transition: background .2s; }
.st-switch::after { content: ''; position: absolute; top: 3px; left: 3px; width: 18px; height: 18px; border-radius: 50%; background: #fff; transition: transform .2s; }
.st-switch:checked { background: #2563eb; }
.st-switch:checked::after { transform: translateX(18px); }
.st-switch:focus-visible { outline: 2px solid #2563eb; outline-offset: 2px; }

.st-choice__options { display: flex; flex-direction: column; gap: 6px; }
.st-choice__option { display: flex; gap: 10px; align-items: flex-start; padding: 10px 12px; border-radius: 8px; border: 1px solid rgba(127,127,127,.3); cursor: pointer; }
.st-choice__option[data-selected="true"] { border-color: #2563eb; background: rgba(37,99,235,.08); }
.st-choice__option input { margin-top: 3px; }
.st-choice__title { display: block; }

.st-input { display: flex; align-items: stretch; }
.st-input__prefix { display: grid; place-items: center; padding: 0 10px; border: 1px solid rgba(127,127,127,.4); border-inline-end: 0; border-radius: 8px 0 0 8px; opacity: .8; }
.st-input__prefix + .st-input__field { border-radius: 0 8px 8px 0; }
.st-input__field, .st-select { flex: 1 1 auto; min-width: 0; padding: 8px 10px; border-radius: 8px; border: 1px solid rgba(127,127,127,.4); font: inherit; background: transparent; color: inherit; }
.st-input__field[aria-invalid="true"] { border-color: #b91c1c; }
.st-select { max-width: 420px; }
.st-inline { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }

.st-link { display: grid; grid-template-columns: minmax(80px, 160px) 1fr auto; gap: 10px; align-items: center; }
.st-link__url { font-size: .85rem; opacity: .75; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.st-link-form { display: grid; grid-template-columns: minmax(80px, 160px) 1fr auto; gap: 8px; }
.st-link-form .st-error { grid-column: 1 / -1; }

.st-segmented { display: inline-flex; gap: 2px; padding: 3px; border-radius: 10px; background: rgba(127,127,127,.14); align-self: flex-start; }
.st-segmented__item { padding: 6px 12px; border: 0; border-radius: 8px; background: transparent; color: inherit; font: inherit; cursor: pointer; }
.st-segmented__item.is-active { background: var(--color-surface, #fff); box-shadow: 0 1px 3px rgba(0,0,0,.15); font-weight: 600; }

.st-card { display: flex; flex-direction: column; gap: 8px; padding: 16px; border-radius: 12px; border: 1px solid rgba(127,127,127,.3); max-width: 420px; }
.st-card__identity { display: flex; gap: 12px; align-items: center; }
.st-avatar { width: 44px; height: 44px; border-radius: 50%; display: grid; place-items: center; background: rgba(127,127,127,.22); font-weight: 700; font-size: 1.1rem; }
.st-card__name { margin: 0; font-weight: 700; }
.st-card__headline { margin: 0; font-weight: 600; }
.st-card__bio { margin: 0; white-space: pre-wrap; }
.st-card__links { margin: 0; padding-inline-start: 18px; }
.st-card__verdict { margin: 4px 0 0; font-size: .9rem; color: #15803d; }
.st-card__verdict--no { color: #b91c1c; }

.st-checkup { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.st-checkup__line { width: 100%; text-align: start; padding: 8px 12px; border: 0; border-radius: 8px; background: rgba(127,127,127,.1); color: inherit; font: inherit; cursor: pointer; }
.st-checkup__line:hover, .st-checkup__line:focus-visible { background: rgba(37,99,235,.12); }

.st-sample { margin: 0; padding: 10px 12px; border-radius: 8px; background: rgba(127,127,127,.1); }

.st-devices { display: grid; grid-template-columns: minmax(200px, 320px) 1fr; gap: 16px; align-items: start; }
@media (max-width: 720px) { .st-devices { grid-template-columns: 1fr; } }
.st-devices__preview { width: 100%; aspect-ratio: 16 / 9; border-radius: 10px; background: #111; object-fit: cover; transform: scaleX(-1); }
.st-devices__controls { display: flex; flex-direction: column; gap: 10px; }
.st-meter { height: 8px; border-radius: 4px; background: rgba(127,127,127,.25); overflow: hidden; }
.st-meter__bar { display: block; height: 100%; background: #16a34a; transition: width 60ms linear; }

.st-results { display: flex; flex-direction: column; gap: 4px; }
.st-result { display: flex; justify-content: space-between; gap: 12px; padding: 10px 12px; border: 0; border-radius: 8px; background: rgba(127,127,127,.1); color: inherit; font: inherit; text-align: start; cursor: pointer; }
.st-result:hover, .st-result:focus-visible { background: rgba(37,99,235,.12); }
.st-result__label { font-weight: 600; }

.st-notice { position: fixed; inset-inline-start: 50%; bottom: 24px; transform: translateX(-50%); z-index: 50; display: flex; align-items: center; gap: 14px; padding: 10px 16px; border-radius: 10px; background: #111827; color: #fff; box-shadow: 0 8px 24px rgba(0,0,0,.25); }
.st-notice--error { background: #991b1b; }
.st-notice__undo { border: 0; background: transparent; color: #93c5fd; font: inherit; font-weight: 700; cursor: pointer; }
__PA_EOF__
echo "wrote apps/web/src/components/Settings/settings.css"

cat > .phaseA-patch.mjs <<'__PA_EOF__'
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'apps/web/src/main.jsx',
    marker: 'applyCachedAppearance',
    edits: [
      {
        name: 'text size and motion apply before the first paint',
        find: "import './app.css';\n",
        replace:
          "import './app.css';\n" +
          "import { applyCachedAppearance } from './lib/preferences.js';\n" +
          '\n' +
          '// This device\'s copy of the account preferences; AppLayout refreshes it.\n' +
          'applyCachedAppearance();\n',
      },
    ],
  },
  {
    file: 'apps/web/src/pages/ClassroomPage.jsx',
    marker: 'withMediaPreferences',
    edits: [
      {
        name: 'import',
        find: "import VideoTile from '../components/Classroom/VideoTile.jsx';\n",
        replace:
          "import VideoTile from '../components/Classroom/VideoTile.jsx';\n" +
          "import { lessonJoinDefaults, withMediaPreferences } from '../lib/preferences.js';\n",
      },
      {
        name: 'chosen devices and sound settings for every capture',
        find: '  const { sfu, deviceAdapter, screenShareAdapter } = useSfuClient();\n',
        replace:
          '  const { sfu, deviceAdapter: baseDeviceAdapter, screenShareAdapter } = useSfuClient();\n' +
          '  // Settings → Lessons: chosen camera and microphone, noise suppression, data\n' +
          '  // saver. Wrapped once per adapter, so a setting never makes the lesson rejoin.\n' +
          '  const deviceAdapter = useMemo(() => withMediaPreferences(baseDeviceAdapter), [baseDeviceAdapter]);\n',
      },
      {
        name: 'join state from Settings, read once per page',
        find: '  const classroomOptions = useMemo(\n',
        replace:
          '  // Settings → Lessons → "When you join a lesson". Read once: changing it\n' +
          '  // mid-lesson must not rebuild the session.\n' +
          '  const joinDefaults = useMemo(() => lessonJoinDefaults(), []);\n' +
          '\n' +
          '  const classroomOptions = useMemo(\n',
      },
      {
        name: 'use it',
        find: '      startMuted: true,\n      startCameraOff: false,\n',
        replace: '      startMuted: joinDefaults.startMuted,\n      startCameraOff: joinDefaults.startCameraOff,\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/Chat/ChatRooms.jsx',
    marker: 'lib/preferences.js',
    edits: [
      {
        name: 'import the date and time formats from Settings',
        find: "import './chatRooms.css';\n",
        replace: "import './chatRooms.css';\nimport { formatDate, formatTime } from '../../lib/preferences.js';\n",
      },
      {
        name: 'drop the fixed formatters',
        find:
          "const time = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });\n" +
          "const day = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' });\n",
        replace: '',
      },
      {
        name: 'times in the chat list follow Settings → Language & region',
        find: '  return date.toDateString() === new Date().toDateString() ? time.format(date) : day.format(date);\n',
        replace: '  return date.toDateString() === new Date().toDateString() ? formatTime(date) : formatDate(date);\n',
      },
    ],
  },
  {
    file: 'server/src/classroom/Room.js',
    marker: 'startMuted: Boolean(this.settings.startMuted)',
    edits: [
      {
        name: 'room state tells joiners whether the lesson starts muted',
        find: '      reactionsEnabled: this.settings.reactionsEnabled !== false,\n',
        replace:
          '      reactionsEnabled: this.settings.reactionsEnabled !== false,\n' +
          '      startMuted: Boolean(this.settings.startMuted),\n',
      },
    ],
  },
  {
    file: 'server/src/classroom/RoomManager.js',
    marker: 'roomDefaults',
    edits: [
      {
        name: "the host's lesson defaults apply when the room is created",
        find: '  await room.startAudioLevelObserver();\n  rooms.set(roomId, room);\n',
        replace:
          '  await room.startAudioLevelObserver();\n' +
          '\n' +
          "  // The host's lesson defaults (Settings → Teaching). A lookup that fails\n" +
          '  // leaves the mode defaults: a lesson must start either way.\n' +
          '  if (hostUserId) {\n' +
          '    try {\n' +
          "      const { getPreferences } = await import('../identity/Profile.js');\n" +
          '      const { roomDefaults } = await getPreferences(hostUserId);\n' +
          '      room.settings.reactionsEnabled = roomDefaults.reactionsEnabled;\n' +
          '      room.settings.startMuted = roomDefaults.learnersJoinMuted;\n' +
          '    } catch (cause) {\n' +
          "      log.warn({ err: cause, roomId }, 'host lesson defaults unavailable; using mode defaults');\n" +
          '    }\n' +
          '  }\n' +
          '\n' +
          '  rooms.set(roomId, room);\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/state/useClassroom.ts',
    marker: 'roomPolicyRef',
    edits: [
      {
        name: 'remember whether the room starts learners muted',
        find: '  const joinedRef = useRef(false);\n',
        replace:
          '  const joinedRef = useRef(false);\n' +
          "  /** From the room state: the host's \"learners join muted\". Hosts and cohosts are exempt. */\n" +
          '  const roomPolicyRef = useRef({ startMuted: false });\n',
      },
      {
        name: 'read it from the room state',
        find: '        setScreenShare(state.screenShare);\n',
        replace:
          '        setScreenShare(state.screenShare);\n' +
          '        roomPolicyRef.current = {\n' +
          '          startMuted:\n' +
          '            Boolean((state as { startMuted?: boolean }).startMuted) &&\n' +
          "            state.selfRole !== 'host' &&\n" +
          "            state.selfRole !== 'cohost',\n" +
          '        };\n',
      },
      {
        name: 'join muted when either the person or the room says so',
        find: '        if (startMuted) await sfu.setMicrophoneEnabled(false);\n',
        replace:
          '        if (startMuted || roomPolicyRef.current.startMuted) {\n' +
          '          await sfu.setMicrophoneEnabled(false);\n' +
          '          setMicrophoneEnabled(false);\n' +
          '        }\n',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const count = src.split(edit.find).length - 1;
    if (count !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.replace(edit.find, edit.replace);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__PA_EOF__
node .phaseA-patch.mjs
rm -f .phaseA-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
for f in "${TOUCHED[@]}"; do
  case "$f" in
    *.js) node --check "$f" && echo "ok  $f" ;;
    *.ts) if [ -n "$ESBUILD" ]; then "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null && echo "ok  $f"; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null && echo "ok  $f"; else echo "--  $f (no esbuild to check)"; fi ;;
    *) [ -f "$f" ] && echo "ok  $f" ;;
  esac
done

echo "--- database"
if SERVICE_ROLE=api npm run db:migrate; then
  # node --watch waits for a file change after a failed start; this is one.
  touch server/src/server.js
  echo
  echo "Phase A installed and migration 021 applied. The API restarts on its own;"
  echo "reload the browser tabs with Ctrl+Shift+R."
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  exit 1
fi