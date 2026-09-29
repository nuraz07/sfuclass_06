#!/usr/bin/env bash
# community-install.sh — Community, part 1.
#
# Spaces (class, topic, study group) with open / ask-to-join / invite-only
# access, owners and moderators, threads and questions with accepted answers,
# "me too", anonymous questions, private member lists, blocks respected
# everywhere, reports and posting pauses — plus Home, Questions and Discover.
#
# A new module under /hub; the older /community code is left untouched.
# Run from the project folder:  bash community-install.sh
# Writes 19 files, patches 2 more, backup in .community-backup/<timestamp>/.
# Undo:                         bash community-install.sh --restore
#   (the columns and tables added by 026 stay — they are unused without these files)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/026_community_hub.sql
  server/src/hub/hubRules.js
  server/src/hub/HubService.js
  server/src/routes/hub.routes.js
  server/test/hub/hubRules.check.mjs
  packages/core-client/src/api/hubApi.ts
  apps/web/src/pages/CommunityPage.jsx
  apps/web/src/components/Hub/hubModel.js
  apps/web/src/components/Hub/ThreadRow.jsx
  apps/web/src/components/Hub/ReportButton.jsx
  apps/web/src/components/Hub/SpaceRail.jsx
  apps/web/src/components/Hub/HubHome.jsx
  apps/web/src/components/Hub/HubQuestions.jsx
  apps/web/src/components/Hub/HubDiscover.jsx
  apps/web/src/components/Hub/NewSpaceForm.jsx
  apps/web/src/components/Hub/SpaceView.jsx
  apps/web/src/components/Hub/HubThread.jsx
  apps/web/src/components/Hub/hub.css
  apps/web/src/components/Hub/__checks__/hubModel.check.mjs
  server/src/app.js
  packages/core-client/src/index.ts
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .community-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/026_community_hub.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  echo "Restored from $FIRST. The migration file 026 stays, because the database already has it."
  exit 0
fi

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need server/src/db/migrations/004_community.sql "create table if not exists spaces" "community tables"
need server/src/db/migrations/004_community.sql "create table if not exists threads" "community tables"
need server/src/community/NotificationService.js "export const notifyMany" "Settings Phase B"
need apps/web/src/components/Settings/notificationsModel.js "relativeTime" "Settings Phase B"
need apps/web/src/lib/userEvents.js "onUserEvent" "Settings Phase B"
need server/src/routes/_helpers.js "conflict" "routes"
need server/src/app.js "scheduledRoomsRoutes" "the rooms feature"
need apps/web/src/main.jsx "community/threads/:threadId" "the community routes in main.jsx"
if ! grep -rqs "space_memberships" server/src/db/migrations/; then
  MISSING+=("no migration creates or renames to space_memberships (expected from 016)")
fi
if ls server/src/db/migrations/026_*.sql 2>/dev/null | grep -qv 026_community_hub.sql; then
  MISSING+=("another migration 026 exists: $(ls server/src/db/migrations/026_*.sql | tr '\n' ' ')")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what the community expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".community-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/026_community_hub.sql <<'__CM_EOF__'
-- 026_community_hub.sql  (Community, part 1)
--
-- The community builds on the tables that already exist — spaces,
-- space_memberships, threads, posts — and adds only what they lack.
--
--   spaces            kind         'class' (a course or class) · 'topic' · 'study' (a small group with an end)
--                     access       'open' (anyone in the organisation joins) ·
--                                  'request' (ask, a moderator admits) · 'invite' (invisible to non-members)
--                     member_list  'members' (members see each other) · 'moderators' (only moderators see the list)
--                     join_question  asked when someone requests to join
--                     ends_at      a study group archives itself after this
--                     emoji, tags  how it looks and is found in Discover
--   space_memberships last_seen_at (what is new for you), timeout_until (a moderator's pause)
--   threads           kind 'discussion' · 'question', anonymous, answered_post_id, metoo_count
--   thread_metoo      "I have the same question"
--   space_join_requests, space_reports
--
-- spaces.visibility is left as it was; `access` is what the community uses.
-- Additive only.

alter table spaces add column if not exists kind          text    not null default 'topic';
alter table spaces add column if not exists access        text    not null default 'open';
alter table spaces add column if not exists member_list   text    not null default 'members';
alter table spaces add column if not exists join_question text;
alter table spaces add column if not exists ends_at       timestamptz;
alter table spaces add column if not exists emoji         text;
alter table spaces add column if not exists tags          text[]  not null default '{}';

alter table space_memberships add column if not exists last_seen_at  timestamptz;
alter table space_memberships add column if not exists timeout_until timestamptz;

alter table threads add column if not exists kind             text    not null default 'discussion';
alter table threads add column if not exists anonymous        boolean not null default false;
alter table threads add column if not exists answered_post_id uuid    references posts (id) on delete set null;
alter table threads add column if not exists metoo_count      integer not null default 0;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'spaces_kind_check') then
    alter table spaces add constraint spaces_kind_check check (kind in ('class', 'topic', 'study'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'spaces_access_check') then
    alter table spaces add constraint spaces_access_check check (access in ('open', 'request', 'invite'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'spaces_member_list_check') then
    alter table spaces add constraint spaces_member_list_check check (member_list in ('members', 'moderators'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'threads_kind_check') then
    alter table threads add constraint threads_kind_check check (kind in ('discussion', 'question'));
  end if;
end $$;

create table if not exists thread_metoo (
  thread_id  uuid        not null references threads (id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (thread_id, user_id)
);

create table if not exists space_join_requests (
  space_id   uuid        not null references spaces (id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  answer     text,
  status     text        not null default 'pending',
  decided_by uuid        references users (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (space_id, user_id),
  constraint space_join_requests_status_check check (status in ('pending', 'approved', 'declined'))
);

create table if not exists space_reports (
  id          uuid        primary key default gen_random_uuid(),
  space_id    uuid        not null references spaces (id) on delete cascade,
  target_type text        not null,
  target_id   uuid        not null,
  reporter_id uuid        not null references users (id) on delete cascade,
  reason      text        not null,
  note        text,
  status      text        not null default 'open',
  resolved_by uuid        references users (id) on delete set null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint space_reports_target_check check (target_type in ('thread', 'post', 'user')),
  constraint space_reports_status_check check (status in ('open', 'removed', 'dismissed'))
);

create index if not exists spaces_hub_discover_idx on spaces (tenant_id, access, created_at desc) where archived_at is null;
create index if not exists threads_hub_questions_idx on threads (space_id, kind, last_post_at desc) where deleted_at is null;
create index if not exists space_reports_open_idx on space_reports (space_id, created_at desc) where status = 'open';
__CM_EOF__
echo "wrote server/src/db/migrations/026_community_hub.sql"

mkdir -p server/src/hub
cat > server/src/hub/hubRules.js <<'__CM_EOF__'
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
  })
  .strict();

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
  isModerator, hasEnded, viewOf, postingBlockedBecause, canCreateKind, memberListVisible, authorView,
  canMarkAnswer, canRemove, roomForMember, excerpt,
};
__CM_EOF__
echo "wrote server/src/hub/hubRules.js"

mkdir -p server/src/hub
cat > server/src/hub/HubService.js <<'__CM_EOF__'
// classroom-app/server/src/hub/HubService.js
/**
 * Community  (Community, part 1)
 *
 * Spaces, membership and admission, threads and replies, questions with
 * answers and "me too", reports — all scoped to the viewer's organisation,
 * and all filtered through hub/hubRules.js.
 *
 * Built on the tables that already exist (spaces, space_memberships, threads,
 * posts, blocks) plus migration 026. Older migrations added columns this code
 * does not know about (a slug, an owner): rows are written with the columns
 * the database actually has, looked up once, so an extra NOT NULL column with
 * an obvious value is filled and an unknown one is left alone.
 *
 * Privacy: people are shown by name and role only. Blocks work both ways —
 * nobody sees posts from someone they blocked or who blocked them.
 */

import { randomUUID } from 'node:crypto';
import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Rules from './hubRules.js';

const log = logger.child({ component: 'community-hub' });

const fail = (code, message) => {
  throw Object.assign(new Error(message), { code });
};
const iso = (value) => (value ? new Date(value).toISOString() : null);

// ---------------------------------------------------------------------------
// Writing rows with the columns that exist
// ---------------------------------------------------------------------------

const columnCache = new Map();
const columnsOf = async (table, client = pool) => {
  if (!columnCache.has(table)) {
    const { rows } = await client.query(
      `SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1`,
      [table],
    );
    columnCache.set(table, new Set(rows.map((row) => row.column_name)));
  }
  return columnCache.get(table);
};

const insertRow = async (client, table, values, conflict = '') => {
  const present = await columnsOf(table, client);
  const keys = Object.keys(values).filter((key) => present.has(key) && values[key] !== undefined);
  const params = keys.map((key) => values[key]);
  const { rows } = await client.query(
    `INSERT INTO ${table} (${keys.join(', ')}) VALUES (${keys.map((_, i) => `$${i + 1}`).join(', ')}) ${conflict} RETURNING *`,
    params,
  );
  return rows[0] ?? null;
};

const inTransaction = async (fn) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }
};

const slugFor = (name) =>
  `${String(name)
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-')
    .slice(0, 60) || 'space'}-${randomUUID().slice(0, 6)}`;

// ---------------------------------------------------------------------------
// People
// ---------------------------------------------------------------------------

/** The signed-in person, as the community needs them. */
export const viewerOf = async (userId) => {
  const { rows } = await pool.query(
    `SELECT id, tenant_id, role, display_name FROM users WHERE id = $1 AND deleted_at IS NULL`,
    [userId],
  );
  if (!rows[0]) fail('not_found', 'No such account');
  return { userId: rows[0].id, tenantId: rows[0].tenant_id, role: rows[0].role, displayName: rows[0].display_name };
};

/** Nobody sees content from someone they blocked, or who blocked them. */
const NOT_BLOCKED = (authorColumn, viewerParam) => `NOT EXISTS (
  SELECT 1 FROM blocks b
   WHERE (b.user_id = ${viewerParam} AND b.blocked_id = ${authorColumn})
      OR (b.user_id = ${authorColumn} AND b.blocked_id = ${viewerParam}))`;

const notify = async (payload) => {
  try {
    const { notifyMany } = await import('../community/NotificationService.js');
    await notifyMany(payload);
  } catch (cause) {
    log.warn({ err: cause, type: payload.type }, 'community notification not queued');
  }
};

// ---------------------------------------------------------------------------
// Spaces
// ---------------------------------------------------------------------------

const toSpace = (row) => ({
  spaceId: row.id,
  name: row.name,
  description: row.description ?? null,
  kind: row.kind ?? 'topic',
  access: row.access ?? 'open',
  memberList: row.member_list ?? 'members',
  joinQuestion: row.join_question ?? null,
  endsAt: iso(row.ends_at),
  emoji: row.emoji ?? null,
  tags: row.tags ?? [],
  courseId: row.course_id ?? null,
  archivedAt: iso(row.archived_at),
  createdAt: iso(row.created_at),
});

const membershipOf = async (spaceId, userId, client = pool) => {
  const { rows } = await client.query(
    `SELECT role, joined_at, last_seen_at, timeout_until FROM space_memberships WHERE space_id = $1 AND user_id = $2`,
    [spaceId, userId],
  );
  const row = rows[0];
  return row
    ? { role: row.role, joinedAt: iso(row.joined_at), lastSeenAt: iso(row.last_seen_at), timeoutUntil: iso(row.timeout_until) }
    : null;
};

/** The space and the viewer's membership, or 404 when the viewer may not know it exists. */
const loadSpace = async (viewer, spaceId, client = pool) => {
  const { rows } = await client.query(`SELECT * FROM spaces WHERE id = $1 AND tenant_id = $2`, [spaceId, viewer.tenantId]);
  if (!rows[0]) fail('not_found', 'No such space');
  const space = toSpace(rows[0]);
  const membership = await membershipOf(spaceId, viewer.userId, client);
  if (Rules.viewOf(space, membership) === 'hidden') fail('not_found', 'No such space');
  return { space, membership };
};

const SPACE_LIST_SQL = (where, order) => `
  SELECT s.*,
         m.role AS my_role, m.joined_at AS my_joined_at, m.last_seen_at AS my_last_seen,
         jr.status AS my_request,
         (SELECT count(*)::int FROM space_memberships sm WHERE sm.space_id = s.id) AS member_count,
         (SELECT count(*)::int FROM threads t
           WHERE t.space_id = s.id AND t.deleted_at IS NULL
             AND m.user_id IS NOT NULL
             AND t.last_post_at > coalesce(m.last_seen_at, m.joined_at)) AS new_activity,
         (SELECT count(*)::int FROM threads t
           WHERE t.space_id = s.id AND t.deleted_at IS NULL AND t.kind = 'question' AND t.answered_post_id IS NULL) AS open_questions,
         (SELECT max(t.last_post_at) FROM threads t WHERE t.space_id = s.id AND t.deleted_at IS NULL) AS last_activity
    FROM spaces s
    LEFT JOIN space_memberships m ON m.space_id = s.id AND m.user_id = $1
    LEFT JOIN space_join_requests jr ON jr.space_id = s.id AND jr.user_id = $1
   WHERE s.tenant_id = $2 AND s.archived_at IS NULL AND ${where}
   ORDER BY ${order}
   LIMIT 100`;

const toListedSpace = (row) => ({
  ...toSpace(row),
  memberCount: row.member_count ?? 0,
  newActivity: row.new_activity ?? 0,
  openQuestions: row.open_questions ?? 0,
  lastActivityAt: iso(row.last_activity),
  myRole: row.my_role ?? null,
  myRequest: row.my_request ?? null,
  ended: Rules.hasEnded(toSpace(row)),
});

/** "mine": spaces I am in, most active first. "discover": open and request spaces I am not in. */
export const listSpaces = async ({ viewer, scope = 'mine', q = null, kind = null }) => {
  const params = [viewer.userId, viewer.tenantId];
  const filters = [scope === 'mine' ? 'm.user_id IS NOT NULL' : `m.user_id IS NULL AND s.access <> 'invite'`];
  if (q) {
    params.push(q);
    filters.push(`(s.name ILIKE '%' || $${params.length} || '%' OR s.description ILIKE '%' || $${params.length} || '%' OR lower($${params.length}) = ANY(s.tags))`);
  }
  if (kind) {
    params.push(kind);
    filters.push(`s.kind = $${params.length}`);
  }
  const order = scope === 'mine' ? 'last_activity DESC NULLS LAST, s.name' : 'member_count DESC, s.created_at DESC';
  const { rows } = await pool.query(SPACE_LIST_SQL(filters.join(' AND '), order), params);
  return { items: rows.map(toListedSpace) };
};

export const getSpace = async ({ viewer, spaceId }) => {
  const { space, membership } = await loadSpace(viewer, spaceId);
  const { rows } = await pool.query(SPACE_LIST_SQL('s.id = $3', 's.id'), [viewer.userId, viewer.tenantId, spaceId]);
  const listed = toListedSpace(rows[0]);
  const view = Rules.viewOf(space, membership);
  if (membership) {
    await pool
      .query(`UPDATE space_memberships SET last_seen_at = now() WHERE space_id = $1 AND user_id = $2`, [spaceId, viewer.userId])
      .catch(() => undefined);
  }
  return {
    ...listed,
    view,
    me: {
      role: membership?.role ?? null,
      moderator: Rules.isModerator(membership),
      postingBlocked: Rules.postingBlockedBecause(space, membership),
      timeoutUntil: membership?.timeoutUntil ?? null,
      request: listed.myRequest,
    },
  };
};

export const createSpace = async ({ viewer, input }) => {
  if (!Rules.canCreateKind(input.kind, viewer.role)) fail('forbidden', 'Only teachers can create class spaces.');
  const spaceId = await inTransaction(async (client) => {
    const row = await insertRow(client, 'spaces', {
      tenant_id: viewer.tenantId,
      name: input.name,
      description: input.description ?? null,
      kind: input.kind,
      access: input.access,
      member_list: input.memberList,
      join_question: input.access === 'request' ? input.joinQuestion ?? null : null,
      ends_at: input.endsAt ?? null,
      emoji: input.emoji ?? null,
      tags: input.tags ?? [],
      created_by: viewer.userId,
      owner_id: viewer.userId,
      slug: slugFor(input.name),
    });
    await insertRow(client, 'space_memberships', {
      space_id: row.id,
      user_id: viewer.userId,
      role: 'owner',
      tenant_id: viewer.tenantId,
      last_seen_at: new Date(),
    });
    return row.id;
  });
  log.info({ spaceId, kind: input.kind, userId: viewer.userId }, 'space created');
  return getSpace({ viewer, spaceId });
};

export const updateSpace = async ({ viewer, spaceId, patch }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators can change the space.');
  const map = {
    name: 'name', description: 'description', access: 'access', memberList: 'member_list',
    joinQuestion: 'join_question', endsAt: 'ends_at', emoji: 'emoji', tags: 'tags',
  };
  const sets = [];
  const params = [spaceId];
  for (const [key, column] of Object.entries(map)) {
    if (patch[key] === undefined) continue;
    params.push(patch[key]);
    sets.push(`${column} = $${params.length}`);
  }
  if (sets.length) await pool.query(`UPDATE spaces SET ${sets.join(', ')}, updated_at = now() WHERE id = $1`, params);
  return getSpace({ viewer, spaceId });
};

export const archiveSpace = async ({ viewer, spaceId }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (membership?.role !== 'owner') fail('forbidden', 'Only the owner can archive the space.');
  await pool.query(`UPDATE spaces SET archived_at = now(), updated_at = now() WHERE id = $1`, [spaceId]);
  return { archived: true };
};

// ---------------------------------------------------------------------------
// Membership and admission
// ---------------------------------------------------------------------------

const memberCount = async (spaceId, client = pool) =>
  (await client.query(`SELECT count(*)::int AS n FROM space_memberships WHERE space_id = $1`, [spaceId])).rows[0].n;

const addMember = async (client, { spaceId, userId, tenantId, role = 'member' }) =>
  insertRow(
    client,
    'space_memberships',
    { space_id: spaceId, user_id: userId, role, tenant_id: tenantId, last_seen_at: new Date(0) },
    'ON CONFLICT (space_id, user_id) DO NOTHING',
  );

const moderatorIds = async (spaceId) =>
  (await pool.query(`SELECT user_id FROM space_memberships WHERE space_id = $1 AND role IN ('owner', 'moderator')`, [spaceId]))
    .rows.map((row) => row.user_id);

/** Open: you are in. Request: a moderator decides. Invite: only by invitation. */
export const join = async ({ viewer, spaceId, answer = null }) => {
  const { space, membership } = await loadSpace(viewer, spaceId);
  if (membership) return getSpace({ viewer, spaceId });
  if (Rules.hasEnded(space)) fail('forbidden', 'This space has ended.');

  if (space.courseId) {
    const { rows } = await pool.query(
      `SELECT 1 FROM enrollments WHERE course_id = $1 AND user_id = $2 AND status IN ('active', 'completed')`,
      [space.courseId, viewer.userId],
    ).catch(() => ({ rows: [] }));
    if (rows.length === 0) fail('forbidden', 'Enrol in the course to join its space.');
  }
  if (!Rules.roomForMember(space, await memberCount(spaceId))) {
    fail('forbidden', `Study groups hold up to ${Rules.MAX_STUDY_GROUP} people, and this one is full.`);
  }

  if (space.access === 'open' || space.courseId) {
    await inTransaction((client) => addMember(client, { spaceId, userId: viewer.userId, tenantId: viewer.tenantId }));
    return getSpace({ viewer, spaceId });
  }
  if (space.access === 'request') {
    await pool.query(
      `INSERT INTO space_join_requests (space_id, user_id, answer, status)
       VALUES ($1, $2, $3, 'pending')
       ON CONFLICT (space_id, user_id) DO UPDATE SET answer = EXCLUDED.answer, status = 'pending', created_at = now(),
                                                    decided_by = NULL, decided_at = NULL`,
      [spaceId, viewer.userId, answer ? String(answer).slice(0, 500) : null],
    );
    await notify({
      userIds: await moderatorIds(spaceId),
      type: 'space.join_request',
      title: `${viewer.displayName} asks to join ${space.name}`,
      body: answer ? String(answer).slice(0, 140) : null,
      href: `/community/spaces/${spaceId}?tab=members`,
      actorId: viewer.userId,
      data: { spaceId },
      dedupeKey: `space.join_request:${spaceId}:${viewer.userId}`,
    });
    return getSpace({ viewer, spaceId });
  }
  fail('forbidden', 'This space is by invitation only.');
};

export const leave = async ({ viewer, spaceId }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!membership) return { left: true };
  if (membership.role === 'owner') {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n FROM space_memberships WHERE space_id = $1 AND role = 'owner'`,
      [spaceId],
    );
    if (rows[0].n <= 1) fail('forbidden', 'You own this space. Make someone else an owner first, or archive it.');
  }
  await pool.query(`DELETE FROM space_memberships WHERE space_id = $1 AND user_id = $2`, [spaceId, viewer.userId]);
  return { left: true };
};

export const listRequests = async ({ viewer, spaceId }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators see requests.');
  const { rows } = await pool.query(
    `SELECT r.user_id, r.answer, r.created_at, u.display_name
       FROM space_join_requests r JOIN users u ON u.id = r.user_id
      WHERE r.space_id = $1 AND r.status = 'pending' ORDER BY r.created_at`,
    [spaceId],
  );
  return { items: rows.map((row) => ({ userId: row.user_id, displayName: row.display_name, answer: row.answer, at: iso(row.created_at) })) };
};

export const decideRequest = async ({ viewer, spaceId, userId, approve }) => {
  const { space, membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators decide requests.');
  await inTransaction(async (client) => {
    const { rowCount } = await client.query(
      `UPDATE space_join_requests SET status = $3, decided_by = $4, decided_at = now()
        WHERE space_id = $1 AND user_id = $2 AND status = 'pending'`,
      [spaceId, userId, approve ? 'approved' : 'declined', viewer.userId],
    );
    if (rowCount === 0) fail('not_found', 'No open request from this person.');
    if (approve) {
      if (!Rules.roomForMember(space, await memberCount(spaceId, client))) fail('forbidden', 'This study group is full.');
      await addMember(client, { spaceId, userId, tenantId: viewer.tenantId });
    }
  });
  if (approve) {
    await notify({
      userIds: [userId],
      type: 'space.join_approved',
      title: `You are in: ${space.name}`,
      href: `/community/spaces/${spaceId}`,
      actorId: viewer.userId,
      data: { spaceId },
    });
  }
  return { decided: true };
};

/** Adds people from the same organisation. They are told. */
export const invite = async ({ viewer, spaceId, userIds }) => {
  const { space, membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators can add people.');
  const { rows } = await pool.query(
    `SELECT id FROM users WHERE id = ANY($1::uuid[]) AND tenant_id = $2 AND deleted_at IS NULL`,
    [userIds, viewer.tenantId],
  );
  const ids = rows.map((row) => row.id);
  let added = 0;
  await inTransaction(async (client) => {
    for (const userId of ids) {
      if (!Rules.roomForMember(space, await memberCount(spaceId, client))) break;
      if (await addMember(client, { spaceId, userId, tenantId: viewer.tenantId })) added += 1;
    }
  });
  await notify({
    userIds: ids.filter((id) => id !== viewer.userId),
    type: 'space.invite',
    title: `You were added to ${space.name}`,
    href: `/community/spaces/${spaceId}`,
    actorId: viewer.userId,
    data: { spaceId },
  });
  return { added };
};

/**
 * The member list — names and roles only, never contact details. When the
 * space shows its list to moderators only, others see the count and the
 * moderators (so they know whom to ask).
 */
export const listMembers = async ({ viewer, spaceId }) => {
  const { space, membership } = await loadSpace(viewer, spaceId);
  const visible = Rules.memberListVisible(space, membership);
  const { rows } = await pool.query(
    `SELECT m.user_id, m.role, m.joined_at, m.timeout_until, u.display_name
       FROM space_memberships m JOIN users u ON u.id = m.user_id
      WHERE m.space_id = $1 AND u.deleted_at IS NULL
        ${visible ? '' : `AND m.role IN ('owner', 'moderator')`}
      ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'moderator' THEN 1 ELSE 2 END, u.display_name
      LIMIT 500`,
    [spaceId],
  );
  const moderator = Rules.isModerator(membership);
  return {
    listVisible: visible,
    count: await memberCount(spaceId),
    items: rows.map((row) => ({
      userId: row.user_id,
      displayName: row.display_name,
      role: row.role,
      joinedAt: iso(row.joined_at),
      you: row.user_id === viewer.userId,
      timeoutUntil: moderator ? iso(row.timeout_until) : undefined,
    })),
  };
};

export const updateMember = async ({ viewer, spaceId, userId, role, timeoutMinutes }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators manage members.');
  const target = await membershipOf(spaceId, userId);
  if (!target) fail('not_found', 'Not a member.');
  if (target.role === 'owner' && membership.role !== 'owner') fail('forbidden', 'Moderators cannot change an owner.');
  if (role !== undefined) {
    if (membership.role !== 'owner') fail('forbidden', 'Only an owner changes roles.');
    if (userId === viewer.userId) fail('forbidden', 'Ask another owner to change your own role.');
    await pool.query(`UPDATE space_memberships SET role = $3 WHERE space_id = $1 AND user_id = $2`, [spaceId, userId, role]);
  }
  if (timeoutMinutes !== undefined) {
    await pool.query(
      `UPDATE space_memberships SET timeout_until = CASE WHEN $3::int > 0 THEN now() + ($3::int || ' minutes')::interval END
        WHERE space_id = $1 AND user_id = $2`,
      [spaceId, userId, timeoutMinutes],
    );
  }
  return { updated: true };
};

export const removeMember = async ({ viewer, spaceId, userId }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators remove people.');
  const target = await membershipOf(spaceId, userId);
  if (target?.role === 'owner') fail('forbidden', 'An owner cannot be removed.');
  await pool.query(`DELETE FROM space_memberships WHERE space_id = $1 AND user_id = $2`, [spaceId, userId]);
  return { removed: true };
};

// ---------------------------------------------------------------------------
// Threads
// ---------------------------------------------------------------------------

const toThreadSummary = (row, viewer) => {
  const moderator = row.viewer_role === 'owner' || row.viewer_role === 'moderator';
  return {
    threadId: row.id,
    spaceId: row.space_id,
    spaceName: row.space_name ?? undefined,
    spaceEmoji: row.space_emoji ?? undefined,
    title: row.title,
    kind: row.kind ?? 'discussion',
    excerpt: Rules.excerpt(row.first_body ?? ''),
    author: Rules.authorView({
      authorId: row.author_id,
      displayName: row.display_name,
      anonymous: Boolean(row.anonymous),
      viewerId: viewer.userId,
      viewerIsModerator: moderator,
    }),
    replies: Math.max(0, (row.post_count ?? 1) - 1),
    answered: Boolean(row.answered_post_id),
    metoo: row.metoo_count ?? 0,
    myMetoo: Boolean(row.my_metoo),
    pinned: Boolean(row.pinned),
    locked: Boolean(row.locked),
    createdAt: iso(row.created_at),
    lastPostAt: iso(row.last_post_at),
  };
};

const THREAD_SELECT = `
  SELECT t.*, u.display_name,
         s.name AS space_name, s.emoji AS space_emoji,
         vm.role AS viewer_role,
         (SELECT p.body FROM posts p WHERE p.thread_id = t.id AND p.deleted_at IS NULL ORDER BY p.created_at, p.id LIMIT 1) AS first_body,
         EXISTS (SELECT 1 FROM thread_metoo mt WHERE mt.thread_id = t.id AND mt.user_id = $1) AS my_metoo
    FROM threads t
    JOIN users u ON u.id = t.author_id
    JOIN spaces s ON s.id = t.space_id
    LEFT JOIN space_memberships vm ON vm.space_id = t.space_id AND vm.user_id = $1`;

export const listThreads = async ({ viewer, spaceId, filter = 'all' }) => {
  const { space, membership } = await loadSpace(viewer, spaceId);
  if (Rules.viewOf(space, membership) !== 'full') fail('forbidden', 'Join the space to read it.');
  const extra =
    filter === 'questions' ? `AND t.kind = 'question'`
      : filter === 'unanswered' ? `AND t.kind = 'question' AND t.answered_post_id IS NULL`
        : '';
  const { rows } = await pool.query(
    `${THREAD_SELECT}
      WHERE t.space_id = $2 AND t.deleted_at IS NULL AND ${NOT_BLOCKED('t.author_id', '$1')} ${extra}
      ORDER BY t.pinned DESC, t.last_post_at DESC, t.id DESC
      LIMIT 100`,
    [viewer.userId, spaceId],
  );
  return { items: rows.map((row) => toThreadSummary(row, viewer)) };
};

export const createThread = async ({ viewer, spaceId, input }) => {
  const { space, membership } = await loadSpace(viewer, spaceId);
  const blocked = Rules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);
  const threadId = await inTransaction(async (client) => {
    const thread = await insertRow(client, 'threads', {
      space_id: spaceId,
      tenant_id: viewer.tenantId,
      title: input.title,
      author_id: viewer.userId,
      kind: input.kind,
      anonymous: input.anonymous,
      post_count: 1,
      last_post_at: new Date(),
    });
    await insertRow(client, 'posts', {
      thread_id: thread.id,
      tenant_id: viewer.tenantId,
      author_id: viewer.userId,
      body: input.body,
    });
    return thread.id;
  });
  log.info({ threadId, spaceId, kind: input.kind }, 'thread started');
  return getThread({ viewer, threadId });
};

const loadThread = async (viewer, threadId) => {
  const { rows } = await pool.query(`SELECT * FROM threads WHERE id = $1 AND deleted_at IS NULL`, [threadId]);
  if (!rows[0]) fail('not_found', 'No such thread');
  const { space, membership } = await loadSpace(viewer, rows[0].space_id);
  if (Rules.viewOf(space, membership) !== 'full') fail('forbidden', 'Join the space to read it.');
  const blockedAuthor = await pool.query(
    `SELECT 1 FROM blocks WHERE (user_id = $1 AND blocked_id = $2) OR (user_id = $2 AND blocked_id = $1) LIMIT 1`,
    [viewer.userId, rows[0].author_id],
  );
  if (blockedAuthor.rows.length) fail('not_found', 'No such thread');
  return { thread: rows[0], space, membership };
};

export const getThread = async ({ viewer, threadId }) => {
  const { thread, space, membership } = await loadThread(viewer, threadId);
  const moderator = Rules.isModerator(membership);
  const { rows: summaryRows } = await pool.query(`${THREAD_SELECT} WHERE t.id = $2`, [viewer.userId, threadId]);
  const { rows: posts } = await pool.query(
    `SELECT p.id, p.author_id, p.body, p.reply_to_id, p.created_at, p.edited_at, u.display_name
       FROM posts p JOIN users u ON u.id = p.author_id
      WHERE p.thread_id = $1 AND p.deleted_at IS NULL AND ${NOT_BLOCKED('p.author_id', '$2')}
      ORDER BY p.created_at, p.id
      LIMIT 500`,
    [threadId, viewer.userId],
  );
  if (membership) {
    await pool
      .query(`UPDATE space_memberships SET last_seen_at = now() WHERE space_id = $1 AND user_id = $2`, [space.spaceId, viewer.userId])
      .catch(() => undefined);
  }
  const blocked = Rules.postingBlockedBecause(space, membership);
  return {
    ...toThreadSummary(summaryRows[0], viewer),
    space: { spaceId: space.spaceId, name: space.name, emoji: space.emoji, kind: space.kind },
    answeredPostId: thread.answered_post_id ?? null,
    posts: posts.map((post, index) => ({
      postId: post.id,
      first: index === 0,
      body: post.body,
      replyToId: post.reply_to_id ?? null,
      createdAt: iso(post.created_at),
      editedAt: iso(post.edited_at),
      author: Rules.authorView({
        authorId: post.author_id,
        displayName: post.display_name,
        // The asker stays anonymous in their own anonymous thread.
        anonymous: Boolean(thread.anonymous) && post.author_id === thread.author_id,
        viewerId: viewer.userId,
        viewerIsModerator: moderator,
      }),
      answer: post.id === thread.answered_post_id,
      canRemove: Rules.canRemove({ authorId: post.author_id, viewerId: viewer.userId, membership }) && index > 0,
    })),
    me: {
      moderator,
      canReply: !blocked && !thread.locked,
      replyBlocked: thread.locked ? 'This thread is locked.' : blocked,
      canMarkAnswer: Rules.canMarkAnswer({
        thread: { kind: thread.kind, authorId: thread.author_id },
        viewerId: viewer.userId,
        membership,
      }),
      canRemoveThread: Rules.canRemove({ authorId: thread.author_id, viewerId: viewer.userId, membership }),
      canMetoo: thread.kind === 'question' && thread.author_id !== viewer.userId && Boolean(membership),
    },
  };
};

export const reply = async ({ viewer, threadId, input }) => {
  const { thread, space, membership } = await loadThread(viewer, threadId);
  const blocked = Rules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);
  if (thread.locked) fail('forbidden', 'This thread is locked.');
  await inTransaction(async (client) => {
    await insertRow(client, 'posts', {
      thread_id: threadId,
      tenant_id: viewer.tenantId,
      author_id: viewer.userId,
      body: input.body,
      reply_to_id: input.replyToId ?? null,
    });
    await client.query(`UPDATE threads SET post_count = post_count + 1, last_post_at = now(), updated_at = now() WHERE id = $1`, [threadId]);
  });
  if (thread.author_id !== viewer.userId) {
    await notify({
      userIds: [thread.author_id],
      type: 'thread.reply',
      title: `New reply: ${thread.title}`,
      body: Rules.excerpt(input.body, 120),
      href: `/community/threads/${threadId}`,
      actorId: viewer.userId,
      data: { threadId, spaceId: space.spaceId },
      dedupeKey: `thread.reply:${threadId}:${Math.floor(Date.now() / 60_000)}`,
    });
  }
  return getThread({ viewer, threadId });
};

export const markAnswer = async ({ viewer, threadId, postId }) => {
  const { thread, membership } = await loadThread(viewer, threadId);
  if (!Rules.canMarkAnswer({ thread: { kind: thread.kind, authorId: thread.author_id }, viewerId: viewer.userId, membership })) {
    fail('forbidden', 'Only the person who asked, or a moderator, marks the answer.');
  }
  let answerAuthor = null;
  if (postId) {
    const { rows } = await pool.query(
      `SELECT author_id FROM posts WHERE id = $1 AND thread_id = $2 AND deleted_at IS NULL`,
      [postId, threadId],
    );
    if (!rows[0]) fail('not_found', 'No such reply');
    answerAuthor = rows[0].author_id;
  }
  await pool.query(`UPDATE threads SET answered_post_id = $2, updated_at = now() WHERE id = $1`, [threadId, postId ?? null]);
  if (answerAuthor && answerAuthor !== viewer.userId) {
    await notify({
      userIds: [answerAuthor],
      type: 'thread.answered',
      title: `Your reply was marked as the answer: ${thread.title}`,
      href: `/community/threads/${threadId}`,
      actorId: viewer.userId,
      data: { threadId },
    });
  }
  return getThread({ viewer, threadId });
};

/** "I have the same question" — counted, never listed by name. */
export const toggleMetoo = async ({ viewer, threadId }) => {
  const { thread, membership } = await loadThread(viewer, threadId);
  if (thread.kind !== 'question') fail('validation_failed', 'Only questions have "me too".');
  if (thread.author_id === viewer.userId) fail('validation_failed', 'You asked this question.');
  if (!membership) fail('forbidden', 'Join the space first.');
  await inTransaction(async (client) => {
    const removed = await client.query(`DELETE FROM thread_metoo WHERE thread_id = $1 AND user_id = $2`, [threadId, viewer.userId]);
    if (removed.rowCount === 0) {
      await client.query(`INSERT INTO thread_metoo (thread_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [threadId, viewer.userId]);
    }
    await client.query(
      `UPDATE threads SET metoo_count = (SELECT count(*)::int FROM thread_metoo WHERE thread_id = $1) WHERE id = $1`,
      [threadId],
    );
  });
  return getThread({ viewer, threadId });
};

export const moderateThread = async ({ viewer, threadId, pinned, locked }) => {
  const { membership } = await loadThread(viewer, threadId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators pin or lock.');
  if (pinned !== undefined) await pool.query(`UPDATE threads SET pinned = $2 WHERE id = $1`, [threadId, Boolean(pinned)]);
  if (locked !== undefined) await pool.query(`UPDATE threads SET locked = $2 WHERE id = $1`, [threadId, Boolean(locked)]);
  return getThread({ viewer, threadId });
};

export const removeThread = async ({ viewer, threadId }) => {
  const { thread, membership } = await loadThread(viewer, threadId);
  if (!Rules.canRemove({ authorId: thread.author_id, viewerId: viewer.userId, membership })) fail('forbidden', 'You cannot remove this thread.');
  await pool.query(`UPDATE threads SET deleted_at = now() WHERE id = $1`, [threadId]);
  return { removed: true, spaceId: thread.space_id };
};

export const removePost = async ({ viewer, postId }) => {
  const { rows } = await pool.query(`SELECT id, thread_id, author_id FROM posts WHERE id = $1 AND deleted_at IS NULL`, [postId]);
  if (!rows[0]) fail('not_found', 'No such reply');
  const { thread, membership } = await loadThread(viewer, rows[0].thread_id);
  if (!Rules.canRemove({ authorId: rows[0].author_id, viewerId: viewer.userId, membership })) fail('forbidden', 'You cannot remove this reply.');
  await inTransaction(async (client) => {
    await client.query(`UPDATE posts SET deleted_at = now(), deleted_by = $2 WHERE id = $1`, [postId, viewer.userId]);
    await client.query(
      `UPDATE threads SET post_count = greatest(1, post_count - 1),
              answered_post_id = CASE WHEN answered_post_id = $2 THEN NULL ELSE answered_post_id END
        WHERE id = $1`,
      [thread.id, postId],
    );
  });
  return getThread({ viewer, threadId: thread.id });
};

// ---------------------------------------------------------------------------
// Across spaces: home and questions
// ---------------------------------------------------------------------------

export const home = async ({ viewer }) => {
  const [spaces, recent, mine, open] = await Promise.all([
    listSpaces({ viewer, scope: 'mine' }),
    pool.query(
      `${THREAD_SELECT}
        WHERE t.deleted_at IS NULL AND vm.user_id IS NOT NULL AND s.archived_at IS NULL
          AND ${NOT_BLOCKED('t.author_id', '$1')}
        ORDER BY t.last_post_at DESC LIMIT 30`,
      [viewer.userId],
    ),
    pool.query(
      `${THREAD_SELECT}
        WHERE t.deleted_at IS NULL AND t.author_id = $1 AND t.post_count > 1
        ORDER BY t.last_post_at DESC LIMIT 5`,
      [viewer.userId],
    ),
    pool.query(
      `SELECT count(*)::int AS n FROM threads t JOIN space_memberships m ON m.space_id = t.space_id AND m.user_id = $1
        WHERE t.deleted_at IS NULL AND t.kind = 'question' AND t.answered_post_id IS NULL AND t.author_id <> $1`,
      [viewer.userId],
    ),
  ]);
  return {
    spaces: spaces.items.slice(0, 12),
    recent: recent.rows.map((row) => toThreadSummary(row, viewer)),
    myThreads: mine.rows.map((row) => toThreadSummary(row, viewer)),
    openQuestions: open.rows[0].n,
  };
};

/** Questions across all my spaces. "unanswered" first shows what most people share. */
export const questions = async ({ viewer, filter = 'unanswered', sort = 'metoo' }) => {
  const answered = filter === 'answered' ? 'AND t.answered_post_id IS NOT NULL' : filter === 'unanswered' ? 'AND t.answered_post_id IS NULL' : '';
  const order = sort === 'new' ? 't.created_at DESC' : 't.metoo_count DESC, t.last_post_at DESC';
  const { rows } = await pool.query(
    `${THREAD_SELECT}
      WHERE t.deleted_at IS NULL AND t.kind = 'question' AND vm.user_id IS NOT NULL AND s.archived_at IS NULL
        AND ${NOT_BLOCKED('t.author_id', '$1')} ${answered}
      ORDER BY ${order} LIMIT 100`,
    [viewer.userId],
  );
  return { items: rows.map((row) => toThreadSummary(row, viewer)) };
};

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

export const report = async ({ viewer, spaceId, input }) => {
  const { space } = await loadSpace(viewer, spaceId);
  const { rows } = await pool.query(
    `INSERT INTO space_reports (space_id, target_type, target_id, reporter_id, reason, note)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
    [spaceId, input.targetType, input.targetId, viewer.userId, input.reason, input.note ?? null],
  );
  await notify({
    userIds: await moderatorIds(spaceId),
    type: 'space.report',
    title: `A report in ${space.name}`,
    body: `Reason: ${input.reason}`,
    href: `/community/spaces/${spaceId}?tab=reports`,
    actorId: null,
    data: { spaceId, reportId: rows[0].id },
  });
  return { reported: true };
};

export const listReports = async ({ viewer, spaceId }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators see reports.');
  const { rows } = await pool.query(
    `SELECT r.*,
            coalesce(t.title, pt.title) AS thread_title,
            coalesce(t.id, p.thread_id) AS thread_id,
            p.body AS post_body, tu.display_name AS target_name
       FROM space_reports r
       LEFT JOIN threads t ON r.target_type = 'thread' AND t.id = r.target_id
       LEFT JOIN posts p ON r.target_type = 'post' AND p.id = r.target_id
       LEFT JOIN threads pt ON pt.id = p.thread_id
       LEFT JOIN users tu ON r.target_type = 'user' AND tu.id = r.target_id
      WHERE r.space_id = $1 AND r.status = 'open'
      ORDER BY r.created_at DESC LIMIT 100`,
    [spaceId],
  );
  return {
    items: rows.map((row) => ({
      reportId: row.id,
      targetType: row.target_type,
      targetId: row.target_id,
      reason: row.reason,
      note: row.note,
      threadId: row.thread_id ?? null,
      threadTitle: row.thread_title ?? null,
      excerpt: row.post_body ? Rules.excerpt(row.post_body, 140) : null,
      targetName: row.target_name ?? null,
      at: iso(row.created_at),
    })),
  };
};

export const resolveReport = async ({ viewer, spaceId, reportId, action }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators resolve reports.');
  const { rows } = await pool.query(`SELECT * FROM space_reports WHERE id = $1 AND space_id = $2 AND status = 'open'`, [reportId, spaceId]);
  const found = rows[0];
  if (!found) fail('not_found', 'No open report');
  if (action === 'remove') {
    if (found.target_type === 'thread') await pool.query(`UPDATE threads SET deleted_at = now() WHERE id = $1`, [found.target_id]);
    if (found.target_type === 'post') {
      await pool.query(`UPDATE posts SET deleted_at = now(), deleted_by = $2 WHERE id = $1`, [found.target_id, viewer.userId]);
    }
    if (found.target_type === 'user') {
      await pool.query(`DELETE FROM space_memberships WHERE space_id = $1 AND user_id = $2 AND role <> 'owner'`, [spaceId, found.target_id]);
    }
  }
  await pool.query(
    `UPDATE space_reports SET status = $2, resolved_by = $3, resolved_at = now() WHERE id = $1`,
    [reportId, action === 'remove' ? 'removed' : 'dismissed', viewer.userId],
  );
  return { resolved: true };
};

export default {
  viewerOf, listSpaces, getSpace, createSpace, updateSpace, archiveSpace, join, leave, listRequests, decideRequest,
  invite, listMembers, updateMember, removeMember, listThreads, createThread, getThread, reply, markAnswer,
  toggleMetoo, moderateThread, removeThread, removePost, home, questions, report, listReports, resolveReport,
};
__CM_EOF__
echo "wrote server/src/hub/HubService.js"

mkdir -p server/src/routes
cat > server/src/routes/hub.routes.js <<'__CM_EOF__'
/**
 * hub.routes — the community  (Community, part 1)
 *
 * Mounted under /hub (app.js). The older /community routes stay where they
 * are, untouched. Everything here is for the signed-in person, inside their
 * organisation; rules in hub/hubRules.js, storage in hub/HubService.js.
 *
 *   GET    /home                               my spaces, recent activity, my threads
 *   GET    /questions?filter=&sort=             questions across my spaces
 *   GET    /spaces?scope=mine|discover&q=&kind= spaces
 *   POST   /spaces                              create
 *   GET    /spaces/:id                          one space, with what I may do
 *   PATCH  /spaces/:id                          change              moderators
 *   POST   /spaces/:id/archive                  archive             owner
 *   POST   /spaces/:id/join  { answer? }        join, or ask to join
 *   POST   /spaces/:id/leave
 *   GET    /spaces/:id/requests                 open requests       moderators
 *   POST   /spaces/:id/requests/:userId         { approve }         moderators
 *   POST   /spaces/:id/invite  { userIds }      add people          moderators
 *   GET    /spaces/:id/members                  names and roles only
 *   PATCH  /spaces/:id/members/:userId          { role?, timeoutMinutes? }
 *   DELETE /spaces/:id/members/:userId          remove              moderators
 *   GET    /spaces/:id/threads?filter=
 *   POST   /spaces/:id/threads                  start a discussion or ask a question
 *   GET    /threads/:id
 *   POST   /threads/:id/replies
 *   POST   /threads/:id/answer  { postId|null } mark the answer     asker, moderators
 *   POST   /threads/:id/metoo                   "I have the same question" (toggle)
 *   PATCH  /threads/:id  { pinned?, locked? }                       moderators
 *   DELETE /threads/:id                                              author, moderators
 *   DELETE /posts/:id                                                author, moderators
 *   POST   /spaces/:id/reports                  report a thread, reply or person
 *   GET    /spaces/:id/reports                                      moderators
 *   POST   /spaces/:id/reports/:reportId  { action: remove|dismiss } moderators
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Hub from '../hub/HubService.js';
import * as Rules from '../hub/hubRules.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, notFound, badRequest, forbidden, conflict } from './_helpers.js';

const router = Router();
router.use(requireAuth);

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
        throw conflict(error.message);
      default:
        throw error;
    }
  }
};

/** Resolves the viewer once per request; every handler gets it. */
const handle = (fn) =>
  route(
    asHttp(async (req, res) => {
      const viewer = await Hub.viewerOf(req.user.id);
      return fn(req, res, viewer);
    }),
  );

const parse = (schema, body) => {
  const parsed = schema.safeParse(body ?? {});
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    throw badRequest(`${issue?.path?.length ? `${issue.path.join('.')}: ` : ''}${issue?.message ?? 'invalid input'}`);
  }
  return parsed.data;
};

const id = z.string().uuid();
const spaceParam = z.object({ id });
const writeLimit = rateLimit({ key: 'hub:write', points: 60, durationSec: 600, by: ['user'] });

/* ---------------------------------------------------------------- overview */

router.get('/home', handle((req, res, viewer) => Hub.home({ viewer })));

router.get(
  '/questions',
  validate({ query: z.object({ filter: z.enum(['unanswered', 'answered', 'all']).optional(), sort: z.enum(['metoo', 'new']).optional() }).passthrough() }),
  handle((req, res, viewer) => Hub.questions({ viewer, filter: req.query.filter ?? 'unanswered', sort: req.query.sort ?? 'metoo' })),
);

/* ---------------------------------------------------------------- spaces */

router.get(
  '/spaces',
  validate({
    query: z
      .object({ scope: z.enum(['mine', 'discover']).optional(), q: z.string().trim().max(60).optional(), kind: z.enum(Rules.KINDS).optional() })
      .passthrough(),
  }),
  handle((req, res, viewer) =>
    Hub.listSpaces({ viewer, scope: req.query.scope ?? 'mine', q: req.query.q || null, kind: req.query.kind ?? null }),
  ),
);

router.post(
  '/spaces',
  rateLimit({ key: 'hub:create-space', points: 10, durationSec: 3600, by: ['user'] }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Hub.createSpace({ viewer, input: parse(Rules.CreateSpaceSchema, req.body) });
  }),
);

router.get('/spaces/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.getSpace({ viewer, spaceId: req.params.id })));

router.patch(
  '/spaces/:id',
  validate({ params: spaceParam }),
  handle((req, res, viewer) => Hub.updateSpace({ viewer, spaceId: req.params.id, patch: parse(Rules.UpdateSpaceSchema, req.body) })),
);

router.post('/spaces/:id/archive', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.archiveSpace({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/join',
  writeLimit,
  validate({ params: spaceParam, body: z.object({ answer: z.string().trim().max(500).nullish() }).default({}) }),
  handle((req, res, viewer) => Hub.join({ viewer, spaceId: req.params.id, answer: req.body.answer ?? null })),
);

router.post('/spaces/:id/leave', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.leave({ viewer, spaceId: req.params.id })));

router.get('/spaces/:id/requests', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.listRequests({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/requests/:userId',
  validate({ params: z.object({ id, userId: id }), body: z.object({ approve: z.boolean() }) }),
  handle((req, res, viewer) => Hub.decideRequest({ viewer, spaceId: req.params.id, userId: req.params.userId, approve: req.body.approve })),
);

router.post(
  '/spaces/:id/invite',
  writeLimit,
  validate({ params: spaceParam, body: z.object({ userIds: z.array(id).min(1).max(100) }) }),
  handle((req, res, viewer) => Hub.invite({ viewer, spaceId: req.params.id, userIds: req.body.userIds })),
);

router.get('/spaces/:id/members', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.listMembers({ viewer, spaceId: req.params.id })));

router.patch(
  '/spaces/:id/members/:userId',
  validate({
    params: z.object({ id, userId: id }),
    body: z.object({ role: z.enum(['owner', 'moderator', 'member']).optional(), timeoutMinutes: z.number().int().min(0).max(10080).optional() }),
  }),
  handle((req, res, viewer) =>
    Hub.updateMember({ viewer, spaceId: req.params.id, userId: req.params.userId, role: req.body.role, timeoutMinutes: req.body.timeoutMinutes }),
  ),
);

router.delete(
  '/spaces/:id/members/:userId',
  validate({ params: z.object({ id, userId: id }) }),
  handle((req, res, viewer) => Hub.removeMember({ viewer, spaceId: req.params.id, userId: req.params.userId })),
);

/* ---------------------------------------------------------------- threads */

router.get(
  '/spaces/:id/threads',
  validate({ params: spaceParam, query: z.object({ filter: z.enum(['all', 'questions', 'unanswered']).optional() }).passthrough() }),
  handle((req, res, viewer) => Hub.listThreads({ viewer, spaceId: req.params.id, filter: req.query.filter ?? 'all' })),
);

router.post(
  '/spaces/:id/threads',
  writeLimit,
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Hub.createThread({ viewer, spaceId: req.params.id, input: parse(Rules.CreateThreadSchema, req.body) });
  }),
);

router.get('/threads/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.getThread({ viewer, threadId: req.params.id })));

router.post(
  '/threads/:id/replies',
  writeLimit,
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Hub.reply({ viewer, threadId: req.params.id, input: parse(Rules.ReplySchema, req.body) });
  }),
);

router.post(
  '/threads/:id/answer',
  validate({ params: spaceParam, body: z.object({ postId: id.nullable() }) }),
  handle((req, res, viewer) => Hub.markAnswer({ viewer, threadId: req.params.id, postId: req.body.postId })),
);

router.post('/threads/:id/metoo', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.toggleMetoo({ viewer, threadId: req.params.id })));

router.patch(
  '/threads/:id',
  validate({ params: spaceParam, body: z.object({ pinned: z.boolean().optional(), locked: z.boolean().optional() }) }),
  handle((req, res, viewer) => Hub.moderateThread({ viewer, threadId: req.params.id, pinned: req.body.pinned, locked: req.body.locked })),
);

router.delete('/threads/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.removeThread({ viewer, threadId: req.params.id })));

router.delete('/posts/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.removePost({ viewer, postId: req.params.id })));

/* ---------------------------------------------------------------- reports */

router.post(
  '/spaces/:id/reports',
  rateLimit({ key: 'hub:report', points: 20, durationSec: 3600, by: ['user'] }),
  validate({ params: spaceParam }),
  handle((req, res, viewer) => Hub.report({ viewer, spaceId: req.params.id, input: parse(Rules.ReportSchema, req.body) })),
);

router.get('/spaces/:id/reports', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.listReports({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/reports/:reportId',
  validate({ params: z.object({ id, reportId: id }), body: z.object({ action: z.enum(['remove', 'dismiss']) }) }),
  handle((req, res, viewer) => Hub.resolveReport({ viewer, spaceId: req.params.id, reportId: req.params.reportId, action: req.body.action })),
);

export default router;
__CM_EOF__
echo "wrote server/src/routes/hub.routes.js"

mkdir -p server/test/hub
cat > server/test/hub/hubRules.check.mjs <<'__CM_EOF__'
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
__CM_EOF__
echo "wrote server/test/hub/hubRules.check.mjs"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/hubApi.ts <<'__CM_EOF__'
/**
 * Community API  (Community, part 1)
 *
 * Spaces, membership, threads, questions and reports. Paths are the server's
 * (server/src/routes/hub.routes.js, mounted under /hub). Responses are
 * validated loosely (passthrough): the server shapes every view, including
 * who is shown as "Anonymous".
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

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
        })
        .passthrough(),
    ),
  })
  .passthrough();
export type HubMembers = z.infer<typeof MembersSchema>;

const HomeSchema = z
  .object({
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
  reply(threadId: string, body: string, replyToId?: string | null): Promise<HubThread>;
  markAnswer(threadId: string, postId: string | null): Promise<HubThread>;
  metoo(threadId: string): Promise<HubThread>;
  moderateThread(threadId: string, patch: { pinned?: boolean; locked?: boolean }): Promise<HubThread>;
  removeThread(threadId: string): Promise<{ removed: boolean; spaceId: string }>;
  removePost(postId: string): Promise<HubThread>;
  report(spaceId: string, input: { targetType: 'thread' | 'post' | 'user'; targetId: string; reason: string; note?: string | null }): Promise<unknown>;
  reports(spaceId: string, signal?: AbortSignal): Promise<{ items: HubReport[] }>;
  resolveReport(spaceId: string, reportId: string, action: 'remove' | 'dismiss'): Promise<unknown>;
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
  reply: (threadId, body, replyToId = null) =>
    http.post(`/hub/threads/${enc(threadId)}/replies`, { body, replyToId }, { schema: HubThreadSchema, ...once }),
  markAnswer: (threadId, postId) => http.post(`/hub/threads/${enc(threadId)}/answer`, { postId }, { schema: HubThreadSchema }),
  metoo: (threadId) => http.post(`/hub/threads/${enc(threadId)}/metoo`, {}, { schema: HubThreadSchema }),
  moderateThread: (threadId, patch) => http.patch(`/hub/threads/${enc(threadId)}`, patch, { schema: HubThreadSchema }),
  removeThread: (threadId) =>
    http.delete(`/hub/threads/${enc(threadId)}`, { schema: z.object({ removed: z.boolean(), spaceId: z.string() }).passthrough() }),
  removePost: (postId) => http.delete(`/hub/posts/${enc(postId)}`, { schema: HubThreadSchema }),
  report: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/reports`, input, once),
  reports: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/reports`, { schema: Items(ReportSchema), signal }),
  resolveReport: (spaceId, reportId, action) => http.post(`/hub/spaces/${enc(spaceId)}/reports/${enc(reportId)}`, { action }, once),
});
__CM_EOF__
echo "wrote packages/core-client/src/api/hubApi.ts"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/CommunityPage.jsx <<'__CM_EOF__'
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLocation, useParams } from 'react-router-dom';
import { createHubApi, useCore } from '@classroom/core-client';

import SpaceRail from '../components/Hub/SpaceRail.jsx';
import HubHome from '../components/Hub/HubHome.jsx';
import HubQuestions from '../components/Hub/HubQuestions.jsx';
import HubDiscover from '../components/Hub/HubDiscover.jsx';
import NewSpaceForm from '../components/Hub/NewSpaceForm.jsx';
import SpaceView from '../components/Hub/SpaceView.jsx';
import HubThread from '../components/Hub/HubThread.jsx';
import { tabFrom } from '../components/Hub/hubModel.js';
import { onUserEvent } from '../lib/userEvents.js';
import '../components/Hub/hub.css';

/**
 * Community  (Community, part 1)
 *
 *   /community                    Home: what is new in your spaces
 *   /community?tab=questions      Questions across all your spaces
 *   /community?tab=discover       Spaces you are not in yet
 *   /community?tab=new            Create a space
 *   /community/spaces/:spaceId    One space (?tab=members|about|requests|reports)
 *   /community/threads/:threadId  One thread
 *
 * The same three routes main.jsx already had; the rest is query strings, so
 * nothing outside this page changes. Data comes from /hub (hubApi).
 */

const TEACHING = new Set(['teacher', 'owner', 'admin']);

export default function CommunityPage() {
  const core = useCore();
  const { http, session } = core;
  const hub = useMemo(() => createHubApi(http), [http]);
  const { spaceId, threadId } = useParams();
  const location = useLocation();

  const [home, setHome] = useState(null);
  const [version, setVersion] = useState(0);
  const bump = useCallback(() => setVersion((value) => value + 1), []);

  useEffect(() => {
    const controller = new AbortController();
    hub
      .home(controller.signal)
      .then(setHome)
      .catch(() => !controller.signal.aborted && setHome({ spaces: [], recent: [], myThreads: [], openQuestions: 0 }));
    return () => controller.abort();
  }, [hub, version]);

  // A reply, an answer or an admission arrives as a notification: refresh.
  useEffect(
    () =>
      onUserEvent(core, 'notification:new', (payload) => {
        const kind = String(payload?.notification?.kind ?? '');
        if (kind.startsWith('thread.') || kind.startsWith('space.')) bump();
      }),
    [core, bump],
  );

  // Back from another tab or window: catch up.
  useEffect(() => {
    const onFocus = () => bump();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [bump]);

  const tab = tabFrom(location.search, ['home', 'questions', 'discover', 'new'], 'home');
  const canCreateClass = TEACHING.has(session?.role);

  let main;
  if (threadId) main = <HubThread key={threadId} hub={hub} threadId={threadId} bump={bump} />;
  else if (spaceId) main = <SpaceView key={spaceId} hub={hub} spaceId={spaceId} version={version} bump={bump} />;
  else if (tab === 'questions') main = <HubQuestions hub={hub} />;
  else if (tab === 'discover') main = <HubDiscover hub={hub} onChanged={bump} />;
  else if (tab === 'new') main = <NewSpaceForm hub={hub} canCreateClass={canCreateClass} onCreated={bump} />;
  else main = <HubHome home={home} displayName={session?.displayName} />;

  return (
    <section className="page hb">
      <SpaceRail spaces={home?.spaces ?? null} openQuestions={home?.openQuestions ?? 0} />
      <div className="hb-main" key={`${location.pathname}${location.search}`}>
        {main}
      </div>
    </section>
  );
}
__CM_EOF__
echo "wrote apps/web/src/pages/CommunityPage.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/hubModel.js <<'__CM_EOF__'
/**
 * Pure helpers for the community pages  (Community, part 1)
 * Tested in __checks__/hubModel.check.mjs. The server decides what is
 * allowed; these only shape forms and words.
 */

export const KINDS = [
  { value: 'topic', label: 'Topic space', hint: 'An interest or subject: open to everyone who cares about it.' },
  { value: 'study', label: 'Study group', hint: 'Up to 12 people working towards something, with an end date.' },
  { value: 'class', label: 'Class space', hint: 'For a class or course you teach. Teachers only.' },
];

export const ACCESS = [
  { value: 'open', label: 'Open', hint: 'Anyone in your organisation can read and join.' },
  { value: 'request', label: 'Ask to join', hint: 'Anyone can find it; you admit people.' },
  { value: 'invite', label: 'Invite only', hint: 'Invisible to everyone you have not added.' },
];

export const KIND_LABEL = { topic: 'Topic', study: 'Study group', class: 'Class' };
export const ROLE_LABEL = { owner: 'Owner', moderator: 'Moderator', member: 'Member' };
export const REPORT_REASONS = [
  { value: 'harassment', label: 'Harassment or bullying' },
  { value: 'hate', label: 'Hateful content' },
  { value: 'inappropriate', label: 'Inappropriate content' },
  { value: 'spam', label: 'Spam or advertising' },
  { value: 'off-topic', label: 'Off-topic' },
  { value: 'other', label: 'Something else' },
];

export const TIMEOUTS = [
  { minutes: 60, label: '1 hour' },
  { minutes: 24 * 60, label: '1 day' },
  { minutes: 7 * 24 * 60, label: '1 week' },
];

export const emptySpaceForm = () => ({
  name: '',
  description: '',
  kind: 'topic',
  access: 'open',
  memberList: 'members',
  joinQuestion: '',
  endsOn: '',
  emoji: '',
  tags: '',
});

/** "maths, exam prep" → ['maths', 'exam prep'], at most five, no duplicates. */
export const parseTags = (text) =>
  [...new Set(String(text ?? '').split(',').map((tag) => tag.trim().toLowerCase()).filter(Boolean))].slice(0, 5);

export const validateSpaceForm = (form, { today = new Date().toISOString().slice(0, 10), canCreateClass = false } = {}) => {
  const errors = {};
  if (form.name.trim().length < 2) errors.name = 'At least 2 characters.';
  if (form.name.trim().length > 80) errors.name = 'At most 80 characters.';
  if (form.kind === 'class' && !canCreateClass) errors.kind = 'Only teachers can create class spaces.';
  if (form.kind === 'study') {
    if (!form.endsOn) errors.endsOn = 'Choose when the group ends, for example the exam date.';
    else if (form.endsOn <= today) errors.endsOn = 'The end date has to be in the future.';
  }
  if (parseTags(form.tags).some((tag) => tag.length > 24)) errors.tags = 'Each tag at most 24 characters.';
  return errors;
};

/** The API's input for the create form. A study group ends at the end of its last day. */
export const spaceFormToInput = (form) => ({
  name: form.name.trim(),
  description: form.description.trim() || null,
  kind: form.kind,
  access: form.access,
  memberList: form.memberList,
  joinQuestion: form.access === 'request' ? form.joinQuestion.trim() || null : null,
  endsAt: form.kind === 'study' && form.endsOn ? new Date(`${form.endsOn}T23:59:00`).toISOString() : null,
  emoji: form.emoji.trim() || null,
  tags: parseTags(form.tags),
});

export const validateThreadForm = ({ title, body }) => {
  const errors = {};
  if (title.trim().length < 3) errors.title = 'A title of at least 3 characters.';
  if (!body.trim()) errors.body = 'Write something first.';
  return errors;
};

/** A space's avatar: its emoji, or its first letter. */
export const spaceMark = (space) => space?.emoji || (space?.name ?? '?').trim().charAt(0).toUpperCase() || '?';

/** "Ends in 3 days", "Ended", or null. */
export const endsLabel = (endsAt, now = new Date()) => {
  if (!endsAt) return null;
  const days = Math.ceil((new Date(endsAt) - now) / 86_400_000);
  if (days <= 0) return 'Ended';
  if (days === 1) return 'Ends tomorrow';
  return `Ends in ${days} days`;
};

/** The badge on a thread row. */
export const threadBadge = (thread) => {
  if (thread.kind !== 'question') return null;
  return thread.answered ? { tone: 'done', text: 'Answered' } : { tone: 'open', text: 'Question' };
};

/** Tab from ?tab=, limited to the ones that exist. */
export const tabFrom = (search, allowed, fallback) => {
  const value = new URLSearchParams(search).get('tab');
  return allowed.includes(value) ? value : fallback;
};

/** Paragraphs of a post, for rendering as text (never as HTML). */
export const paragraphs = (body) =>
  String(body ?? '')
    .split(/\n{2,}/)
    .map((part) => part.trim())
    .filter(Boolean);
__CM_EOF__
echo "wrote apps/web/src/components/Hub/hubModel.js"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/ThreadRow.jsx <<'__CM_EOF__'
import { Link } from 'react-router-dom';
import { relativeTime } from '../Settings/notificationsModel.js';
import { threadBadge } from './hubModel.js';

/** One thread in a list: title, excerpt, who, when, replies, "me too". */
export default function ThreadRow({ thread, showSpace = false }) {
  const badge = threadBadge(thread);
  return (
    <Link to={`/community/threads/${thread.threadId}`} className={thread.pinned ? 'hb-row is-pinned' : 'hb-row'}>
      <div className="hb-row__main">
        <p className="hb-row__meta">
          {badge ? <span className={`hb-badge hb-badge--${badge.tone}`}>{badge.text}</span> : null}
          {thread.pinned ? <span className="hb-badge hb-badge--pin">Pinned</span> : null}
          {thread.locked ? <span className="hb-badge">Locked</span> : null}
          {showSpace && thread.spaceName ? (
            <span className="hb-row__space">
              {thread.spaceEmoji ? `${thread.spaceEmoji} ` : ''}
              {thread.spaceName}
            </span>
          ) : null}
        </p>
        <p className="hb-row__title">{thread.title}</p>
        {thread.excerpt ? <p className="hb-row__excerpt">{thread.excerpt}</p> : null}
        <p className="hb-row__by">
          {thread.author.anonymous && !thread.author.you ? <span className="hb-anon">Anonymous</span> : thread.author.displayName}
          {thread.author.you ? ' (you)' : ''}, {relativeTime(thread.lastPostAt) || 'just now'}
        </p>
      </div>
      <div className="hb-row__stats" aria-label={`${thread.replies} replies${thread.kind === 'question' ? `, ${thread.metoo} with the same question` : ''}`}>
        <span className="hb-stat">
          <strong>{thread.replies}</strong> {thread.replies === 1 ? 'reply' : 'replies'}
        </span>
        {thread.kind === 'question' && thread.metoo > 0 ? (
          <span className={thread.myMetoo ? 'hb-stat is-mine' : 'hb-stat'}>
            <strong>{thread.metoo}</strong> me too
          </span>
        ) : null}
      </div>
    </Link>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/ThreadRow.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/ReportButton.jsx <<'__CM_EOF__'
import { useState } from 'react';
import { REPORT_REASONS } from './hubModel.js';

/**
 * "Report" — opens a small form in place. Reports go to the space's
 * moderators; the person reported is not told who reported them.
 */
export default function ReportButton({ hub, spaceId, targetType, targetId, label = 'Report' }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('harassment');
  const [note, setNote] = useState('');
  const [state, setState] = useState('idle');

  if (state === 'sent') return <span className="hb-muted">Reported. Thank you.</span>;
  if (!open) {
    return (
      <button type="button" className="hb-link hb-link--quiet" onClick={() => setOpen(true)}>
        {label}
      </button>
    );
  }
  const send = async () => {
    setState('sending');
    try {
      await hub.report(spaceId, { targetType, targetId, reason, note: note.trim() || null });
      setState('sent');
    } catch {
      setState('error');
    }
  };
  return (
    <div className="hb-report" role="group" aria-label="Report">
      <select className="hb-input" value={reason} onChange={(event) => setReason(event.target.value)} aria-label="Reason">
        {REPORT_REASONS.map((entry) => (
          <option key={entry.value} value={entry.value}>
            {entry.label}
          </option>
        ))}
      </select>
      <input className="hb-input" placeholder="Anything moderators should know (optional)" maxLength={500} value={note} onChange={(event) => setNote(event.target.value)} />
      <div className="hb-inline">
        <button type="button" className="btn btn--danger btn--tiny" disabled={state === 'sending'} onClick={send}>
          Send report
        </button>
        <button type="button" className="hb-link" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
      {state === 'error' ? <p className="hb-error">The report was not sent. Try again.</p> : null}
    </div>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/ReportButton.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/SpaceRail.jsx <<'__CM_EOF__'
import { NavLink, useLocation } from 'react-router-dom';
import { spaceMark } from './hubModel.js';

/**
 * The community's left rail: the four places, and your spaces with what is
 * new in each. On narrow screens it becomes a row of tabs above the content.
 */
export default function SpaceRail({ spaces, openQuestions }) {
  const location = useLocation();
  const tab = new URLSearchParams(location.search).get('tab');
  const onOverview = location.pathname === '/community';
  const is = (name) => onOverview && (tab ?? 'home') === name;

  return (
    <nav className="hb-rail" aria-label="Community">
      <div className="hb-rail__places">
        <NavLink to="/community" end className={() => (is('home') ? 'hb-place is-on' : 'hb-place')}>
          Home
        </NavLink>
        <NavLink to="/community?tab=questions" className={() => (is('questions') ? 'hb-place is-on' : 'hb-place')}>
          Questions
          {openQuestions > 0 ? <span className="hb-count">{openQuestions}</span> : null}
        </NavLink>
        <NavLink to="/community?tab=discover" className={() => (is('discover') ? 'hb-place is-on' : 'hb-place')}>
          Discover
        </NavLink>
        <NavLink to="/community?tab=new" className={() => (is('new') ? 'hb-place hb-place--new is-on' : 'hb-place hb-place--new')}>
          + New space
        </NavLink>
      </div>

      <p className="hb-rail__head">Your spaces</p>
      {spaces === null ? <p className="hb-muted hb-rail__empty">Loading…</p> : null}
      {spaces?.length === 0 ? <p className="hb-muted hb-rail__empty">None yet. Discover one, or create your own.</p> : null}
      <ul className="hb-rail__spaces">
        {(spaces ?? []).map((space) => (
          <li key={space.spaceId}>
            <NavLink to={`/community/spaces/${space.spaceId}`} className={({ isActive }) => (isActive ? 'hb-spacelink is-on' : 'hb-spacelink')}>
              <span className={`hb-mark hb-mark--${space.kind}`} aria-hidden="true">
                {spaceMark(space)}
              </span>
              <span className="hb-spacelink__name">{space.name}</span>
              {space.newActivity > 0 ? <span className="hb-dot" aria-label={`${space.newActivity} new`} /> : null}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/SpaceRail.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/HubHome.jsx <<'__CM_EOF__'
import { Link } from 'react-router-dom';
import ThreadRow from './ThreadRow.jsx';
import { spaceMark } from './hubModel.js';

/**
 * Community home: what is new in your spaces, in time order — no ranking, no
 * "you might like". Replies to your own threads first, then everything else.
 */
export default function HubHome({ home, displayName }) {
  if (!home) return <p className="hb-muted">Loading…</p>;
  const first = (displayName ?? '').split(' ')[0];

  if (home.spaces.length === 0) {
    return (
      <div className="hb-empty">
        <p className="hb-empty__title">{first ? `Welcome, ${first}.` : 'Welcome.'} Find your people.</p>
        <p className="hb-muted">
          Spaces are groups around a class, a subject or a goal. Nobody in them sees your email or phone number — only your name, and
          only what your privacy settings allow.
        </p>
        <div className="hb-inline">
          <Link className="btn btn--primary" to="/community?tab=discover">
            Discover spaces
          </Link>
          <Link className="btn" to="/community?tab=new">
            Create a space
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div className="hb-home">
      <header className="hb-head">
        <h1>{first ? `Hello, ${first}` : 'Community'}</h1>
        <p className="hb-muted">
          {home.openQuestions > 0 ? (
            <>
              {home.openQuestions} open {home.openQuestions === 1 ? 'question' : 'questions'} in your spaces.{' '}
              <Link to="/community?tab=questions">Help someone</Link>
            </>
          ) : (
            'Every question in your spaces is answered.'
          )}
        </p>
      </header>

      <div className="hb-tiles">
        {home.spaces.slice(0, 6).map((space) => (
          <Link key={space.spaceId} to={`/community/spaces/${space.spaceId}`} className="hb-tile">
            <span className={`hb-mark hb-mark--${space.kind} hb-mark--big`} aria-hidden="true">
              {spaceMark(space)}
            </span>
            <span className="hb-tile__name">{space.name}</span>
            <span className="hb-muted">
              {space.newActivity > 0 ? `${space.newActivity} new` : `${space.memberCount} ${space.memberCount === 1 ? 'member' : 'members'}`}
            </span>
          </Link>
        ))}
      </div>

      {home.myThreads.length > 0 ? (
        <section className="hb-block">
          <h2 className="hb-block__title">Replies to what you wrote</h2>
          <div className="hb-list">
            {home.myThreads.map((thread) => (
              <ThreadRow key={thread.threadId} thread={thread} showSpace />
            ))}
          </div>
        </section>
      ) : null}

      <section className="hb-block">
        <h2 className="hb-block__title">Latest in your spaces</h2>
        {home.recent.length === 0 ? (
          <p className="hb-muted">Quiet so far. Start a thread in one of your spaces.</p>
        ) : (
          <div className="hb-list">
            {home.recent.map((thread) => (
              <ThreadRow key={thread.threadId} thread={thread} showSpace />
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/HubHome.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/HubQuestions.jsx <<'__CM_EOF__'
import { useEffect, useState } from 'react';
import ThreadRow from './ThreadRow.jsx';

/**
 * Questions from all your spaces in one place. "Most shared" puts the
 * questions with the most "me too" first — what many people are stuck on.
 */
export default function HubQuestions({ hub }) {
  const [filter, setFilter] = useState('unanswered');
  const [sort, setSort] = useState('metoo');
  const [items, setItems] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    setItems(null);
    hub
      .questions({ filter, sort }, controller.signal)
      .then((result) => setItems(result.items))
      .catch(() => !controller.signal.aborted && setItems([]));
    return () => controller.abort();
  }, [hub, filter, sort]);

  return (
    <div>
      <header className="hb-head">
        <h1>Questions</h1>
        <p className="hb-muted">From every space you are in. “Me too” shows what many people are stuck on.</p>
      </header>
      <div className="hb-toolbar">
        <div className="hb-segment" role="tablist" aria-label="Which questions">
          {[
            ['unanswered', 'Open'],
            ['answered', 'Answered'],
            ['all', 'All'],
          ].map(([value, label]) => (
            <button key={value} type="button" role="tab" aria-selected={filter === value} className={filter === value ? 'is-on' : ''} onClick={() => setFilter(value)}>
              {label}
            </button>
          ))}
        </div>
        <label className="hb-sort">
          Sort
          <select className="hb-input" value={sort} onChange={(event) => setSort(event.target.value)}>
            <option value="metoo">Most shared</option>
            <option value="new">Newest</option>
          </select>
        </label>
      </div>
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? (
        <p className="hb-muted">{filter === 'unanswered' ? 'No open questions. Nice.' : 'Nothing here yet.'}</p>
      ) : null}
      <div className="hb-list">
        {(items ?? []).map((thread) => (
          <ThreadRow key={thread.threadId} thread={thread} showSpace />
        ))}
      </div>
    </div>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/HubQuestions.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/HubDiscover.jsx <<'__CM_EOF__'
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ACCESS, KIND_LABEL, endsLabel, spaceMark } from './hubModel.js';

/**
 * Spaces in your organisation you are not in yet. Invite-only spaces never
 * appear here. Open spaces can be joined at once; the others take a request.
 */
export default function HubDiscover({ hub, onChanged }) {
  const [q, setQ] = useState('');
  const [kind, setKind] = useState('');
  const [items, setItems] = useState(null);
  const [busy, setBusy] = useState(null);
  const [asking, setAsking] = useState(null);
  const [answer, setAnswer] = useState('');

  const load = async (signal) => {
    try {
      setItems((await hub.spaces({ scope: 'discover', q: q.trim() || undefined, kind: kind || undefined }, signal)).items);
    } catch {
      if (!signal?.aborted) setItems([]);
    }
  };

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => load(controller.signal), 250);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hub, q, kind]);

  const join = async (space, withAnswer = null) => {
    setBusy(space.spaceId);
    try {
      await hub.join(space.spaceId, withAnswer);
      setAsking(null);
      setAnswer('');
      await load();
      onChanged();
    } finally {
      setBusy(null);
    }
  };

  return (
    <div>
      <header className="hb-head">
        <h1>Discover</h1>
        <p className="hb-muted">Spaces in your organisation. Joining shows your name to members — never your email.</p>
      </header>
      <div className="hb-toolbar">
        <input className="hb-input hb-search" type="search" placeholder="Search by name, topic or tag" value={q} onChange={(event) => setQ(event.target.value)} aria-label="Search spaces" />
        <select className="hb-input" value={kind} onChange={(event) => setKind(event.target.value)} aria-label="Kind">
          <option value="">All kinds</option>
          <option value="topic">Topics</option>
          <option value="study">Study groups</option>
          <option value="class">Classes</option>
        </select>
      </div>
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? <p className="hb-muted">Nothing found. <Link to="/community?tab=new">Create the space you are looking for.</Link></p> : null}
      <div className="hb-cards">
        {(items ?? []).map((space) => {
          const access = ACCESS.find((entry) => entry.value === space.access);
          const ends = endsLabel(space.endsAt);
          return (
            <article key={space.spaceId} className="hb-card">
              <div className="hb-card__top">
                <span className={`hb-mark hb-mark--${space.kind} hb-mark--big`} aria-hidden="true">
                  {spaceMark(space)}
                </span>
                <div>
                  <p className="hb-card__name">{space.name}</p>
                  <p className="hb-muted">
                    {KIND_LABEL[space.kind]}, {space.memberCount} {space.memberCount === 1 ? 'member' : 'members'}
                    {ends ? `, ${ends.toLowerCase()}` : ''}
                  </p>
                </div>
              </div>
              {space.description ? <p className="hb-card__text">{space.description}</p> : null}
              {space.tags.length ? (
                <p className="hb-tags">
                  {space.tags.map((tag) => (
                    <button key={tag} type="button" className="hb-tag" onClick={() => setQ(tag)}>
                      {tag}
                    </button>
                  ))}
                </p>
              ) : null}
              <div className="hb-card__foot">
                {space.access === 'open' ? (
                  <>
                    <Link to={`/community/spaces/${space.spaceId}`} className="hb-link">
                      Look inside
                    </Link>
                    <button type="button" className="btn btn--primary" disabled={busy === space.spaceId} onClick={() => join(space)}>
                      Join
                    </button>
                  </>
                ) : space.myRequest === 'pending' ? (
                  <span className="hb-muted">Request sent. A moderator decides.</span>
                ) : asking === space.spaceId ? (
                  <div className="hb-ask">
                    {space.joinQuestion ? <label className="hb-label">{space.joinQuestion}</label> : null}
                    <input className="hb-input" maxLength={500} placeholder={space.joinQuestion ? 'Your answer' : 'A short note (optional)'} value={answer} onChange={(event) => setAnswer(event.target.value)} />
                    <div className="hb-inline">
                      <button type="button" className="btn btn--primary" disabled={busy === space.spaceId} onClick={() => join(space, answer.trim() || null)}>
                        Send request
                      </button>
                      <button type="button" className="hb-link" onClick={() => setAsking(null)}>
                        Cancel
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <span className="hb-muted">{access?.label}</span>
                    <button type="button" className="btn" onClick={() => setAsking(space.spaceId)}>
                      Ask to join
                    </button>
                  </>
                )}
              </div>
            </article>
          );
        })}
      </div>
    </div>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/HubDiscover.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/NewSpaceForm.jsx <<'__CM_EOF__'
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ACCESS, KINDS, emptySpaceForm, spaceFormToInput, validateSpaceForm } from './hubModel.js';

/** Create a space: what kind, who gets in, and who sees the member list. */
export default function NewSpaceForm({ hub, canCreateClass, onCreated }) {
  const navigate = useNavigate();
  const [form, setForm] = useState(emptySpaceForm);
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const errors = validateSpaceForm(form, { canCreateClass });
  const shown = touched ? errors : {};
  const set = (patch) => setForm((current) => ({ ...current, ...patch }));

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length) return;
    setBusy(true);
    setError(null);
    try {
      const space = await hub.createSpace(spaceFormToInput(form));
      onCreated();
      navigate(`/community/spaces/${space.spaceId}`);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'The space was not created.');
    } finally {
      setBusy(false);
    }
  };

  const kinds = KINDS.filter((kind) => kind.value !== 'class' || canCreateClass);

  return (
    <form className="hb-form" onSubmit={submit} noValidate>
      <header className="hb-head">
        <h1>New space</h1>
        <p className="hb-muted">A place for a class, a subject or a goal. You become its owner and moderator.</p>
      </header>

      <fieldset className="hb-fieldset">
        <legend>What kind</legend>
        <div className="hb-options">
          {kinds.map((kind) => (
            <label key={kind.value} className={form.kind === kind.value ? 'hb-option is-on' : 'hb-option'}>
              <input type="radio" name="kind" value={kind.value} checked={form.kind === kind.value} onChange={() => set({ kind: kind.value })} />
              <span>
                <span className="hb-label">{kind.label}</span>
                <span className="hb-muted">{kind.hint}</span>
              </span>
            </label>
          ))}
        </div>
        {shown.kind ? <p className="hb-error">{shown.kind}</p> : null}
      </fieldset>

      <fieldset className="hb-fieldset">
        <legend>About it</legend>
        <div className="hb-row2">
          <label className="hb-field hb-field--emoji">
            <span className="hb-label">Emoji</span>
            <input className="hb-input" value={form.emoji} maxLength={4} placeholder="📚" onChange={(event) => set({ emoji: event.target.value })} />
          </label>
          <label className="hb-field">
            <span className="hb-label">Name</span>
            <input className="hb-input" value={form.name} maxLength={80} placeholder="e.g. Exam prep maths" onChange={(event) => set({ name: event.target.value })} aria-invalid={Boolean(shown.name)} autoFocus />
            {shown.name ? <span className="hb-error">{shown.name}</span> : null}
          </label>
        </div>
        <label className="hb-field">
          <span className="hb-label">Description</span>
          <textarea className="hb-input" rows={3} maxLength={500} value={form.description} placeholder="What is it for, and who should join?" onChange={(event) => set({ description: event.target.value })} />
        </label>
        <label className="hb-field">
          <span className="hb-label">Tags</span>
          <input className="hb-input" value={form.tags} placeholder="maths, exam prep" onChange={(event) => set({ tags: event.target.value })} />
          <span className="hb-muted">Up to five, separated by commas. People find spaces by them in Discover.</span>
          {shown.tags ? <span className="hb-error">{shown.tags}</span> : null}
        </label>
        {form.kind === 'study' ? (
          <label className="hb-field">
            <span className="hb-label">Ends on</span>
            <input className="hb-input" type="date" value={form.endsOn} onChange={(event) => set({ endsOn: event.target.value })} aria-invalid={Boolean(shown.endsOn)} />
            <span className="hb-muted">After this day the group becomes read-only, so it does not linger forever.</span>
            {shown.endsOn ? <span className="hb-error">{shown.endsOn}</span> : null}
          </label>
        ) : null}
      </fieldset>

      <fieldset className="hb-fieldset">
        <legend>Who gets in</legend>
        <div className="hb-options">
          {ACCESS.map((access) => (
            <label key={access.value} className={form.access === access.value ? 'hb-option is-on' : 'hb-option'}>
              <input type="radio" name="access" value={access.value} checked={form.access === access.value} onChange={() => set({ access: access.value })} />
              <span>
                <span className="hb-label">{access.label}</span>
                <span className="hb-muted">{access.hint}</span>
              </span>
            </label>
          ))}
        </div>
        {form.access === 'request' ? (
          <label className="hb-field">
            <span className="hb-label">A question for people who ask to join (optional)</span>
            <input className="hb-input" maxLength={200} value={form.joinQuestion} placeholder="e.g. Which class are you in?" onChange={(event) => set({ joinQuestion: event.target.value })} />
          </label>
        ) : null}
      </fieldset>

      <fieldset className="hb-fieldset">
        <legend>Privacy</legend>
        <label className="hb-check">
          <input type="checkbox" checked={form.memberList === 'moderators'} onChange={(event) => set({ memberList: event.target.checked ? 'moderators' : 'members' })} />
          <span>
            <span className="hb-label">Only moderators see who is in this space</span>
            <span className="hb-muted">For groups where being a member is itself private. Members still see the moderators.</span>
          </span>
        </label>
        <p className="hb-muted">Nobody ever sees members’ email addresses or phone numbers — only names and roles.</p>
      </fieldset>

      {error ? <p className="hb-error" role="alert">{error}</p> : null}
      <div className="hb-inline">
        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Creating…' : 'Create space'}
        </button>
      </div>
    </form>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/NewSpaceForm.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/SpaceView.jsx <<'__CM_EOF__'
import { useCallback, useEffect, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import ThreadRow from './ThreadRow.jsx';
import ReportButton from './ReportButton.jsx';
import { ACCESS, KIND_LABEL, ROLE_LABEL, TIMEOUTS, endsLabel, spaceMark, tabFrom, validateThreadForm } from './hubModel.js';
import { relativeTime } from '../Settings/notificationsModel.js';

/**
 * One space  (Community, part 1)
 *
 *   threads   discussions and questions; start one, filter to open questions
 *   members   names and roles — or only the moderators, if the space says so
 *   requests  people asking to join                       moderators
 *   reports   what members reported                       moderators
 *   about     description, rules of entry; settings        moderators edit
 */

function NewThread({ hub, space, onCreated }) {
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState('discussion');
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [anonymous, setAnonymous] = useState(false);
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const errors = validateThreadForm({ title, body });
  const navigate = useNavigate();

  if (!open) {
    return (
      <div className="hb-starter">
        <button type="button" className="hb-starter__button" onClick={() => { setKind('question'); setOpen(true); }}>
          Ask a question
        </button>
        <button type="button" className="hb-starter__button" onClick={() => { setKind('discussion'); setOpen(true); }}>
          Start a discussion
        </button>
      </div>
    );
  }

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length) return;
    setBusy(true);
    setError(null);
    try {
      const thread = await hub.createThread(space.spaceId, { title: title.trim(), body: body.trim(), kind, anonymous: kind === 'question' && anonymous });
      onCreated();
      navigate(`/community/threads/${thread.threadId}`);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'It was not posted.');
      setBusy(false);
    }
  };

  return (
    <form className="hb-composer" onSubmit={submit} noValidate>
      <div className="hb-segment" role="tablist" aria-label="Kind">
        <button type="button" role="tab" aria-selected={kind === 'question'} className={kind === 'question' ? 'is-on' : ''} onClick={() => setKind('question')}>
          Question
        </button>
        <button type="button" role="tab" aria-selected={kind === 'discussion'} className={kind === 'discussion' ? 'is-on' : ''} onClick={() => setKind('discussion')}>
          Discussion
        </button>
      </div>
      <input className="hb-input hb-input--title" placeholder={kind === 'question' ? 'Your question in one line' : 'Title'} maxLength={160} value={title} onChange={(event) => setTitle(event.target.value)} aria-invalid={Boolean(touched && errors.title)} autoFocus />
      {touched && errors.title ? <p className="hb-error">{errors.title}</p> : null}
      <textarea className="hb-input" rows={5} maxLength={10000} placeholder={kind === 'question' ? 'What have you tried? Where exactly are you stuck?' : 'What would you like to talk about?'} value={body} onChange={(event) => setBody(event.target.value)} aria-invalid={Boolean(touched && errors.body)} />
      {touched && errors.body ? <p className="hb-error">{errors.body}</p> : null}
      {kind === 'question' ? (
        <label className="hb-check">
          <input type="checkbox" checked={anonymous} onChange={(event) => setAnonymous(event.target.checked)} />
          <span>
            <span className="hb-label">Ask anonymously</span>
            <span className="hb-muted">Members see “Anonymous”. Moderators can see it was you, so it stays safe for everyone.</span>
          </span>
        </label>
      ) : null}
      {error ? <p className="hb-error" role="alert">{error}</p> : null}
      <div className="hb-inline">
        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Posting…' : kind === 'question' ? 'Ask' : 'Post'}
        </button>
        <button type="button" className="hb-link" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
    </form>
  );
}

function Threads({ hub, space, version, bump }) {
  const [filter, setFilter] = useState('all');
  const [items, setItems] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    hub
      .threads(space.spaceId, filter, controller.signal)
      .then((result) => setItems(result.items))
      .catch(() => !controller.signal.aborted && setItems([]));
    return () => controller.abort();
  }, [hub, space.spaceId, filter, version]);

  return (
    <>
      {space.me?.postingBlocked ? (
        space.me.role ? <p className="hb-note">{space.me.postingBlocked}</p> : null
      ) : (
        <NewThread hub={hub} space={space} onCreated={bump} />
      )}
      <div className="hb-toolbar">
        <div className="hb-segment" role="tablist" aria-label="Show">
          {[
            ['all', 'Everything'],
            ['questions', 'Questions'],
            ['unanswered', 'Open questions'],
          ].map(([value, label]) => (
            <button key={value} type="button" role="tab" aria-selected={filter === value} className={filter === value ? 'is-on' : ''} onClick={() => setFilter(value)}>
              {label}
            </button>
          ))}
        </div>
      </div>
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? <p className="hb-muted">Nothing here yet. Be the first.</p> : null}
      <div className="hb-list">
        {(items ?? []).map((thread) => (
          <ThreadRow key={thread.threadId} thread={thread} />
        ))}
      </div>
    </>
  );
}

function Members({ hub, space, version, bump }) {
  const [members, setMembers] = useState(null);
  const moderator = space.me?.moderator;
  const owner = space.me?.role === 'owner';

  const load = useCallback(async () => {
    try {
      setMembers(await hub.members(space.spaceId));
    } catch {
      setMembers({ listVisible: false, count: 0, items: [] });
    }
  }, [hub, space.spaceId]);

  useEffect(() => {
    load();
  }, [load, version]);

  if (!members) return <p className="hb-muted">Loading…</p>;
  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
    bump();
  };

  return (
    <div>
      <p className="hb-muted">
        {members.count} {members.count === 1 ? 'member' : 'members'}.{' '}
        {members.listVisible ? 'Names and roles only — never email addresses or phone numbers.' : 'Only moderators see who else is here.'}
      </p>
      <ul className="hb-members">
        {members.items.map((member) => (
          <li key={member.userId} className="hb-member">
            <span className="hb-avatar" aria-hidden="true">
              {member.displayName.charAt(0).toUpperCase()}
            </span>
            <span className="hb-member__name">
              {member.displayName}
              {member.you ? ' (you)' : ''}
              {member.role !== 'member' ? <span className="hb-badge">{ROLE_LABEL[member.role]}</span> : null}
              {member.timeoutUntil && new Date(member.timeoutUntil) > new Date() ? <span className="hb-badge hb-badge--warn">Paused</span> : null}
            </span>
            {moderator && !member.you && member.role !== 'owner' ? (
              <span className="hb-member__actions">
                {owner ? (
                  <button type="button" className="hb-link" onClick={() => act(() => hub.updateMember(space.spaceId, member.userId, { role: member.role === 'moderator' ? 'member' : 'moderator' }))}>
                    {member.role === 'moderator' ? 'Make member' : 'Make moderator'}
                  </button>
                ) : null}
                <select
                  className="hb-input hb-input--small"
                  value=""
                  aria-label={`Pause ${member.displayName}`}
                  onChange={(event) => {
                    const minutes = Number(event.target.value);
                    if (minutes >= 0) act(() => hub.updateMember(space.spaceId, member.userId, { timeoutMinutes: minutes }));
                  }}
                >
                  <option value="" disabled>
                    Pause posting…
                  </option>
                  {TIMEOUTS.map((entry) => (
                    <option key={entry.minutes} value={entry.minutes}>
                      for {entry.label}
                    </option>
                  ))}
                  <option value="0">End the pause</option>
                </select>
                <button type="button" className="hb-link hb-link--danger" onClick={() => window.confirm(`Remove ${member.displayName} from the space?`) && act(() => hub.removeMember(space.spaceId, member.userId))}>
                  Remove
                </button>
              </span>
            ) : !member.you && space.me?.role ? (
              <ReportButton hub={hub} spaceId={space.spaceId} targetType="user" targetId={member.userId} />
            ) : null}
          </li>
        ))}
      </ul>
    </div>
  );
}

function Requests({ hub, space, bump }) {
  const [items, setItems] = useState(null);
  const load = useCallback(async () => {
    try {
      setItems((await hub.requests(space.spaceId)).items);
    } catch {
      setItems([]);
    }
  }, [hub, space.spaceId]);
  useEffect(() => {
    load();
  }, [load]);
  const decide = async (userId, approve) => {
    await hub.decide(space.spaceId, userId, approve).catch(() => undefined);
    await load();
    bump();
  };
  if (!items) return <p className="hb-muted">Loading…</p>;
  if (items.length === 0) return <p className="hb-muted">Nobody is waiting.</p>;
  return (
    <ul className="hb-members">
      {items.map((request) => (
        <li key={request.userId} className="hb-member hb-member--request">
          <span className="hb-avatar" aria-hidden="true">
            {request.displayName.charAt(0).toUpperCase()}
          </span>
          <span className="hb-member__name">
            {request.displayName}
            <span className="hb-muted">
              {request.answer ? `“${request.answer}”` : 'No note'}, {relativeTime(request.at)}
            </span>
          </span>
          <span className="hb-member__actions">
            <button type="button" className="btn btn--primary btn--tiny" onClick={() => decide(request.userId, true)}>
              Let in
            </button>
            <button type="button" className="btn btn--tiny" onClick={() => decide(request.userId, false)}>
              Decline
            </button>
          </span>
        </li>
      ))}
    </ul>
  );
}

function Reports({ hub, space }) {
  const [items, setItems] = useState(null);
  const load = useCallback(async () => {
    try {
      setItems((await hub.reports(space.spaceId)).items);
    } catch {
      setItems([]);
    }
  }, [hub, space.spaceId]);
  useEffect(() => {
    load();
  }, [load]);
  const resolve = async (reportId, action) => {
    await hub.resolveReport(space.spaceId, reportId, action).catch(() => undefined);
    await load();
  };
  if (!items) return <p className="hb-muted">Loading…</p>;
  if (items.length === 0) return <p className="hb-muted">No open reports.</p>;
  return (
    <ul className="hb-reports">
      {items.map((report) => (
        <li key={report.reportId} className="hb-reportcard">
          <p className="hb-label">
            {report.targetType === 'user' ? `Person: ${report.targetName ?? 'unknown'}` : report.threadTitle ?? 'A post'}
            <span className="hb-badge hb-badge--warn">{report.reason}</span>
          </p>
          {report.excerpt ? <p className="hb-muted">“{report.excerpt}”</p> : null}
          {report.note ? <p>{report.note}</p> : null}
          <div className="hb-inline">
            {report.threadId ? (
              <Link className="hb-link" to={`/community/threads/${report.threadId}`}>
                Open
              </Link>
            ) : null}
            <button type="button" className="btn btn--danger btn--tiny" onClick={() => resolve(report.reportId, 'remove')}>
              {report.targetType === 'user' ? 'Remove from space' : 'Remove'}
            </button>
            <button type="button" className="btn btn--tiny" onClick={() => resolve(report.reportId, 'dismiss')}>
              Dismiss
            </button>
          </div>
        </li>
      ))}
    </ul>
  );
}

function About({ hub, space, bump }) {
  const navigate = useNavigate();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState({ description: space.description ?? '', access: space.access, memberList: space.memberList, joinQuestion: space.joinQuestion ?? '' });
  const [error, setError] = useState(null);
  const moderator = space.me?.moderator;
  const access = ACCESS.find((entry) => entry.value === space.access);

  const save = async () => {
    setError(null);
    try {
      await hub.updateSpace(space.spaceId, {
        description: draft.description.trim() || null,
        access: draft.access,
        memberList: draft.memberList,
        joinQuestion: draft.access === 'request' ? draft.joinQuestion.trim() || null : null,
      });
      setEditing(false);
      bump();
    } catch (cause) {
      setError(cause?.detail ?? 'Not saved.');
    }
  };

  const leave = async () => {
    setError(null);
    try {
      await hub.leave(space.spaceId);
      bump();
      navigate('/community');
    } catch (cause) {
      setError(cause?.detail ?? 'You could not leave.');
    }
  };

  const archive = async () => {
    if (!window.confirm('Archive this space? It becomes read-only and leaves everyone’s list.')) return;
    await hub.archiveSpace(space.spaceId).catch(() => undefined);
    bump();
    navigate('/community');
  };

  return (
    <div className="hb-about">
      {editing ? (
        <div className="hb-form">
          <label className="hb-field">
            <span className="hb-label">Description</span>
            <textarea className="hb-input" rows={3} maxLength={500} value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} />
          </label>
          <label className="hb-field">
            <span className="hb-label">Who gets in</span>
            <select className="hb-input" value={draft.access} onChange={(event) => setDraft({ ...draft, access: event.target.value })}>
              {ACCESS.map((entry) => (
                <option key={entry.value} value={entry.value}>
                  {entry.label}: {entry.hint}
                </option>
              ))}
            </select>
          </label>
          {draft.access === 'request' ? (
            <label className="hb-field">
              <span className="hb-label">Question for people who ask to join</span>
              <input className="hb-input" maxLength={200} value={draft.joinQuestion} onChange={(event) => setDraft({ ...draft, joinQuestion: event.target.value })} />
            </label>
          ) : null}
          <label className="hb-check">
            <input type="checkbox" checked={draft.memberList === 'moderators'} onChange={(event) => setDraft({ ...draft, memberList: event.target.checked ? 'moderators' : 'members' })} />
            <span className="hb-label">Only moderators see who is in this space</span>
          </label>
          {error ? <p className="hb-error">{error}</p> : null}
          <div className="hb-inline">
            <button type="button" className="btn btn--primary" onClick={save}>
              Save
            </button>
            <button type="button" className="hb-link" onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <>
          <p>{space.description || <span className="hb-muted">No description yet.</span>}</p>
          <dl className="hb-facts">
            <div>
              <dt>Kind</dt>
              <dd>{KIND_LABEL[space.kind]}</dd>
            </div>
            <div>
              <dt>Who gets in</dt>
              <dd>{access?.label}: {access?.hint}</dd>
            </div>
            <div>
              <dt>Member list</dt>
              <dd>{space.memberList === 'moderators' ? 'Visible to moderators only' : 'Visible to members'}</dd>
            </div>
            {space.endsAt ? (
              <div>
                <dt>Ends</dt>
                <dd>{endsLabel(space.endsAt)}</dd>
              </div>
            ) : null}
          </dl>
          {error ? <p className="hb-error">{error}</p> : null}
          <div className="hb-inline">
            {moderator ? (
              <button type="button" className="btn" onClick={() => setEditing(true)}>
                Edit
              </button>
            ) : null}
            {space.me?.role ? (
              <button type="button" className="btn" onClick={leave}>
                Leave space
              </button>
            ) : null}
            {space.me?.role === 'owner' ? (
              <button type="button" className="btn btn--danger" onClick={archive}>
                Archive
              </button>
            ) : null}
          </div>
        </>
      )}
    </div>
  );
}

export default function SpaceView({ hub, spaceId, version, bump }) {
  const location = useLocation();
  const navigate = useNavigate();
  const [space, setSpace] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState('');

  useEffect(() => {
    const controller = new AbortController();
    hub
      .space(spaceId, controller.signal)
      .then((result) => {
        setSpace(result);
        setError(null);
      })
      .catch((cause) => !controller.signal.aborted && setError(cause?.detail ?? 'This space does not exist, or it is not shared with you.'));
    return () => controller.abort();
  }, [hub, spaceId, version]);

  if (error) return <p className="hb-error">{error}</p>;
  if (!space) return <p className="hb-muted">Loading…</p>;

  const moderator = space.me?.moderator;
  const member = Boolean(space.me?.role);
  const tabs = ['threads', 'members', 'about', ...(moderator ? ['requests', 'reports'] : [])];
  const tab = space.view === 'preview' ? 'about' : tabFrom(location.search, tabs, 'threads');
  const labels = { threads: 'Threads', members: 'Members', about: 'About', requests: 'Requests', reports: 'Reports' };
  const ends = endsLabel(space.endsAt);

  const join = async () => {
    setBusy(true);
    try {
      setSpace(await hub.join(space.spaceId, answer.trim() || null));
      bump();
    } catch (cause) {
      setError(cause?.detail ?? 'You could not join.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="hb-space">
      <header className="hb-space__head">
        <span className={`hb-mark hb-mark--${space.kind} hb-mark--huge`} aria-hidden="true">
          {spaceMark(space)}
        </span>
        <div className="hb-space__title">
          <h1>{space.name}</h1>
          <p className="hb-muted">
            {KIND_LABEL[space.kind]}, {space.memberCount} {space.memberCount === 1 ? 'member' : 'members'}
            {space.openQuestions ? `, ${space.openQuestions} open ${space.openQuestions === 1 ? 'question' : 'questions'}` : ''}
            {ends ? `, ${ends.toLowerCase()}` : ''}
          </p>
        </div>
        <div className="hb-space__action">
          {member ? (
            <span className="hb-badge hb-badge--done">{moderator ? 'You moderate' : 'Member'}</span>
          ) : space.me?.request === 'pending' ? (
            <span className="hb-muted">Request sent</span>
          ) : space.access === 'open' || space.courseId ? (
            <button type="button" className="btn btn--primary" disabled={busy} onClick={join}>
              Join
            </button>
          ) : null}
        </div>
      </header>

      {!member && space.access === 'request' && space.me?.request !== 'pending' ? (
        <div className="hb-joinbox">
          <p className="hb-label">This space admits people by request.</p>
          {space.joinQuestion ? <p className="hb-muted">{space.joinQuestion}</p> : null}
          <div className="hb-inline">
            <input className="hb-input" maxLength={500} placeholder={space.joinQuestion ? 'Your answer' : 'A short note (optional)'} value={answer} onChange={(event) => setAnswer(event.target.value)} />
            <button type="button" className="btn btn--primary" disabled={busy} onClick={join}>
              Ask to join
            </button>
          </div>
        </div>
      ) : null}

      {space.view === 'full' ? (
        <nav className="hb-tabs" aria-label="In this space">
          {tabs.map((name) => (
            <button key={name} type="button" className={tab === name ? 'hb-tab is-on' : 'hb-tab'} aria-current={tab === name ? 'page' : undefined} onClick={() => navigate(`/community/spaces/${space.spaceId}${name === 'threads' ? '' : `?tab=${name}`}`)}>
              {labels[name]}
            </button>
          ))}
        </nav>
      ) : null}

      <div className="hb-panel" key={tab}>
        {tab === 'threads' ? <Threads hub={hub} space={space} version={version} bump={bump} /> : null}
        {tab === 'members' ? <Members hub={hub} space={space} version={version} bump={bump} /> : null}
        {tab === 'requests' ? <Requests hub={hub} space={space} bump={bump} /> : null}
        {tab === 'reports' ? <Reports hub={hub} space={space} /> : null}
        {tab === 'about' ? <About hub={hub} space={space} bump={bump} /> : null}
      </div>
    </div>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/SpaceView.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/HubThread.jsx <<'__CM_EOF__'
import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import ReportButton from './ReportButton.jsx';
import { paragraphs, spaceMark } from './hubModel.js';
import { relativeTime } from '../Settings/notificationsModel.js';

/**
 * One thread  (Community, part 1)
 *
 * The question or opening post, then the replies. For a question: the
 * accepted answer is marked and shown first below the question, "me too"
 * counts who shares it (never who), and the asker or a moderator can mark
 * any reply as the answer. Text is shown as text — never as HTML.
 */

function Body({ text }) {
  return (
    <div className="hb-post__body">
      {paragraphs(text).map((part, index) => (
        <p key={index}>{part}</p>
      ))}
    </div>
  );
}

function Author({ author }) {
  if (author.anonymous && !author.you && !author.revealedToModerator) {
    return <span className="hb-anon">Anonymous</span>;
  }
  return (
    <span className="hb-post__author">
      {author.displayName}
      {author.you ? ' (you)' : ''}
      {author.anonymous && author.you ? <span className="hb-badge">Shown as anonymous</span> : null}
      {author.revealedToModerator ? <span className="hb-badge hb-badge--warn">Anonymous to members</span> : null}
    </span>
  );
}

export default function HubThread({ hub, threadId, bump }) {
  const navigate = useNavigate();
  const [thread, setThread] = useState(null);
  const [error, setError] = useState(null);
  const [reply, setReply] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    hub
      .thread(threadId, controller.signal)
      .then(setThread)
      .catch((cause) => !controller.signal.aborted && setError(cause?.detail ?? 'This thread does not exist, or it is not shared with you.'));
    return () => controller.abort();
  }, [hub, threadId]);

  if (error) return <p className="hb-error">{error}</p>;
  if (!thread) return <p className="hb-muted">Loading…</p>;

  const run = async (fn) => {
    setBusy(true);
    try {
      const next = await fn();
      if (next?.threadId) setThread(next);
      return next;
    } catch (cause) {
      setError(cause?.detail ?? 'That did not work.');
      return null;
    } finally {
      setBusy(false);
    }
  };

  const send = async (event) => {
    event.preventDefault();
    if (!reply.trim()) return;
    const next = await run(() => hub.reply(thread.threadId, reply.trim()));
    if (next) {
      setReply('');
      bump();
    }
  };

  const [first, ...rest] = thread.posts;
  const answer = rest.find((post) => post.answer);
  const others = rest.filter((post) => !post.answer);
  const question = thread.kind === 'question';

  const Post = ({ post, highlight = false }) => (
    <article className={`hb-post${highlight ? ' is-answer' : ''}`} id={`post-${post.postId}`}>
      <header className="hb-post__head">
        <Author author={post.author} />
        <span className="hb-muted">{relativeTime(post.createdAt) || 'just now'}</span>
        {highlight ? <span className="hb-badge hb-badge--done">Answer</span> : null}
      </header>
      <Body text={post.body} />
      <footer className="hb-post__foot">
        {thread.me.canMarkAnswer && !post.first ? (
          <button type="button" className="hb-link" disabled={busy} onClick={() => run(() => hub.markAnswer(thread.threadId, post.answer ? null : post.postId))}>
            {post.answer ? 'Unmark answer' : 'Mark as the answer'}
          </button>
        ) : null}
        {post.canRemove ? (
          <button type="button" className="hb-link hb-link--danger" disabled={busy} onClick={() => window.confirm('Remove this reply?') && run(() => hub.removePost(post.postId))}>
            Remove
          </button>
        ) : null}
        {!post.author.you && !post.first ? <ReportButton hub={hub} spaceId={thread.space.spaceId} targetType="post" targetId={post.postId} /> : null}
      </footer>
    </article>
  );

  return (
    <div className="hb-thread">
      <p className="hb-crumbs">
        <Link to={`/community/spaces/${thread.space.spaceId}`}>
          <span className={`hb-mark hb-mark--${thread.space.kind}`} aria-hidden="true">
            {spaceMark(thread.space)}
          </span>
          {thread.space.name}
        </Link>
      </p>

      <article className="hb-post hb-post--first">
        <p className="hb-row__meta">
          {question ? <span className={thread.answered ? 'hb-badge hb-badge--done' : 'hb-badge hb-badge--open'}>{thread.answered ? 'Answered' : 'Question'}</span> : null}
          {thread.pinned ? <span className="hb-badge hb-badge--pin">Pinned</span> : null}
          {thread.locked ? <span className="hb-badge">Locked</span> : null}
        </p>
        <h1 className="hb-thread__title">{thread.title}</h1>
        <header className="hb-post__head">
          <Author author={first.author} />
          <span className="hb-muted">{relativeTime(first.createdAt) || 'just now'}</span>
        </header>
        <Body text={first.body} />
        <footer className="hb-post__foot">
          {question ? (
            <button
              type="button"
              className={thread.myMetoo ? 'hb-metoo is-on' : 'hb-metoo'}
              disabled={busy || !thread.me.canMetoo}
              aria-pressed={thread.myMetoo}
              title={thread.me.canMetoo ? 'Shows how many people share this question. Names are never listed.' : undefined}
              onClick={() => run(() => hub.metoo(thread.threadId))}
            >
              {thread.myMetoo ? 'You have this question too' : 'I have this question too'}
              <span className="hb-metoo__count">{thread.metoo}</span>
            </button>
          ) : null}
          {thread.me.moderator ? (
            <>
              <button type="button" className="hb-link" disabled={busy} onClick={() => run(() => hub.moderateThread(thread.threadId, { pinned: !thread.pinned }))}>
                {thread.pinned ? 'Unpin' : 'Pin'}
              </button>
              <button type="button" className="hb-link" disabled={busy} onClick={() => run(() => hub.moderateThread(thread.threadId, { locked: !thread.locked }))}>
                {thread.locked ? 'Unlock' : 'Lock'}
              </button>
            </>
          ) : null}
          {thread.me.canRemoveThread ? (
            <button
              type="button"
              className="hb-link hb-link--danger"
              disabled={busy}
              onClick={async () => {
                if (!window.confirm('Remove this thread and its replies?')) return;
                const done = await run(() => hub.removeThread(thread.threadId));
                if (done) {
                  bump();
                  navigate(`/community/spaces/${thread.space.spaceId}`);
                }
              }}
            >
              Remove thread
            </button>
          ) : null}
          {!first.author.you ? <ReportButton hub={hub} spaceId={thread.space.spaceId} targetType="thread" targetId={thread.threadId} /> : null}
        </footer>
      </article>

      {answer ? <Post post={answer} highlight /> : null}

      <h2 className="hb-thread__count">
        {thread.replies === 0 ? 'No replies yet' : `${thread.replies} ${thread.replies === 1 ? 'reply' : 'replies'}`}
      </h2>
      {others.map((post) => (
        <Post key={post.postId} post={post} />
      ))}

      {thread.me.canReply ? (
        <form className="hb-composer hb-composer--reply" onSubmit={send}>
          <label className="hb-label" htmlFor="hb-reply">
            {question && !thread.answered ? 'Your answer' : 'Your reply'}
          </label>
          <textarea id="hb-reply" className="hb-input" rows={4} maxLength={10000} value={reply} onChange={(event) => setReply(event.target.value)} placeholder={question ? 'Explain it the way you would have wanted it explained.' : 'Write a reply'} />
          <div className="hb-inline">
            <button type="submit" className="btn btn--primary" disabled={busy || !reply.trim()}>
              {busy ? 'Sending…' : 'Reply'}
            </button>
          </div>
        </form>
      ) : (
        <p className="hb-note">{thread.me.replyBlocked ?? 'Join the space to reply.'}</p>
      )}
    </div>
  );
}
__CM_EOF__
echo "wrote apps/web/src/components/Hub/HubThread.jsx"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/hub.css <<'__CM_EOF__'
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
.hb-tab { padding: 10px 14px; border: 0; border-bottom: 2px solid transparent; background: none; color: var(--color-muted, #a8bcb9); font: inherit; font-weight: 700; font-size: 14.5px; cursor: pointer; white-space: nowrap; transition: color 0.2s ease, border-color 0.3s ease; }
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
__CM_EOF__
echo "wrote apps/web/src/components/Hub/hub.css"

mkdir -p apps/web/src/components/Hub/__checks__
cat > apps/web/src/components/Hub/__checks__/hubModel.check.mjs <<'__CM_EOF__'
// Community — form and wording helpers.
// Run: node --test apps/web/src/components/Hub/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  emptySpaceForm, endsLabel, paragraphs, parseTags, spaceFormToInput, spaceMark, tabFrom, threadBadge,
  validateSpaceForm, validateThreadForm,
} from '../hubModel.js';

test('tags: trimmed, lower-case, unique, at most five', () => {
  assert.deepEqual(parseTags(' Maths, exam prep , maths,,a,b,c,d'), ['maths', 'exam prep', 'a', 'b', 'c']);
  assert.deepEqual(parseTags(''), []);
});

test('space form validation', () => {
  const base = { ...emptySpaceForm(), name: 'Book club' };
  assert.deepEqual(validateSpaceForm(base), {});
  assert.ok(validateSpaceForm({ ...base, name: 'x' }).name);
  assert.ok(validateSpaceForm({ ...base, kind: 'class' }).kind);
  assert.deepEqual(validateSpaceForm({ ...base, kind: 'class' }, { canCreateClass: true }), {});
  assert.ok(validateSpaceForm({ ...base, kind: 'study' }).endsOn);
  assert.ok(validateSpaceForm({ ...base, kind: 'study', endsOn: '2026-01-01' }, { today: '2026-03-01' }).endsOn);
  assert.deepEqual(validateSpaceForm({ ...base, kind: 'study', endsOn: '2026-04-01' }, { today: '2026-03-01' }), {});
});

test('form to API input', () => {
  const input = spaceFormToInput({ ...emptySpaceForm(), name: ' Exam prep ', kind: 'study', endsOn: '2026-04-01', access: 'request', joinQuestion: ' Which class? ', tags: 'Maths' });
  assert.equal(input.name, 'Exam prep');
  assert.equal(input.joinQuestion, 'Which class?');
  assert.ok(input.endsAt.startsWith('2026-04-01') || input.endsAt.startsWith('2026-04-02') || input.endsAt.startsWith('2026-03-31'));
  assert.deepEqual(input.tags, ['maths']);
  assert.equal(spaceFormToInput({ ...emptySpaceForm(), name: 'X', access: 'open', joinQuestion: 'ignored' }).joinQuestion, null);
});

test('wording helpers', () => {
  assert.equal(spaceMark({ emoji: '📚', name: 'Books' }), '📚');
  assert.equal(spaceMark({ name: 'books' }), 'B');
  const now = new Date('2026-03-01T12:00:00Z');
  assert.equal(endsLabel(null, now), null);
  assert.equal(endsLabel('2026-03-01T10:00:00Z', now), 'Ended');
  assert.equal(endsLabel('2026-03-02T10:00:00Z', now), 'Ends tomorrow');
  assert.equal(endsLabel('2026-03-05T12:00:00Z', now), 'Ends in 4 days');
  assert.equal(threadBadge({ kind: 'discussion' }), null);
  assert.equal(threadBadge({ kind: 'question', answered: true }).text, 'Answered');
  assert.equal(tabFrom('?tab=members', ['threads', 'members'], 'threads'), 'members');
  assert.equal(tabFrom('?tab=evil', ['threads', 'members'], 'threads'), 'threads');
  assert.deepEqual(paragraphs('one\n\n\ntwo\nlines\n\n'), ['one', 'two\nlines']);
  assert.deepEqual(validateThreadForm({ title: 'Hi', body: ' ' }).title !== undefined, true);
});
__CM_EOF__
echo "wrote apps/web/src/components/Hub/__checks__/hubModel.check.mjs"

cat > .community-patch.mjs <<'__CM_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Community, part 1 — edits to files that stay otherwise untouched.
 * Every anchor must be found exactly once; otherwise nothing is written.
 */

const plan = [
  {
    file: 'server/src/app.js',
    marker: 'hubRoutes',
    edits: [
      {
        name: 'import the community routes',
        regex: /^import\s+scheduledRoomsRoutes\s+from\s+['"]([^'"]*)scheduledRooms\.routes\.js['"];?[ \t]*\r?\n/m,
        replace: (m, dir) => `${m}import hubRoutes from '${dir}hub.routes.js';\n`,
      },
      {
        name: 'mount them under /hub',
        regex: /^([ \t]*)app\.use\(\s*['"]\/scheduled-rooms['"],\s*scheduledRoomsRoutes\s*\);[^\n]*\r?\n/m,
        replace: (m, indent) => `${m}${indent}app.use('/hub', hubRoutes); // Community\n`,
      },
    ],
  },
  {
    file: 'packages/core-client/src/index.ts',
    marker: 'hubApi',
    edits: [
      {
        name: 'export the community API',
        find: "export * from './api/profileApi.js';\n",
        replace: "export * from './api/profileApi.js';\nexport * from './api/hubApi.js';\n",
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
    if (n !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${n}. Nothing was changed in any patched file.`);
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
__CM_EOF__
node .community-patch.mjs
rm -f .community-patch.mjs

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
  echo "A file did not pass its check (see above). Undo with: bash community-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs server/test/hub/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs \
  apps/web/src/components/Landing/__checks__/*.check.mjs apps/web/src/components/Auth/__checks__/*.check.mjs \
  apps/web/src/components/Hub/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .community-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .community-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .community-test.log
else
  cat .community-test.log
  rm -f .community-test.log
  echo "The rule checks failed (see above). Undo with: bash community-install.sh --restore" >&2
  exit 1
fi

echo "--- database"
if SERVICE_ROLE=api npm run db:migrate; then
  touch server/src/server.js
  [ -f server/src/worker.js ] && touch server/src/worker.js
  echo
  echo "Community installed and migration 026 applied. The API restarts on its own;"
  echo "reload the browser tabs with Ctrl+Shift+R and open Community."
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh or npm run dev:infra), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  echo "(Until then the API refuses to start: it checks that the database matches the code.)"
  exit 1
fi