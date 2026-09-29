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
