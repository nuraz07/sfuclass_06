#!/usr/bin/env bash
# messages-install.sh — Messages, reworked.
#
#   layout     edge to edge in three columns: chats · the chat · details
#   messages   reply, edit (your own, within CHAT_EDIT_WINDOW_MIN), copy,
#              delete for everyone; ↑ edits your last message; search in chat
#   profiles   click a name or picture to open the profile; the chat header
#              opens the contact info
#   per chat   mute (1 h … until turned on), pin (up to 5), what you share,
#              block / unblock, report, delete for me
#
# The lesson chat (components/Chat/ChatRooms.jsx) is not changed.
#
# Run from the project folder:   bash messages-install.sh
# Writes 14 files, patches 4, backs everything up in .messages-backup/<time>/,
# checks every file, runs the rule tests and applies migration 031 if the
# database is reachable. No container is started, stopped or pulled.
# Undo: bash messages-install.sh --restore   (the pinned_at column stays; unused)
set -euo pipefail

if [ ! -f server/src/messaging/ConversationService.js ] || [ ! -f packages/core-client/src/api/chatApi.ts ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one with server/, packages/ and apps/)." >&2
  exit 1
fi
command -v node >/dev/null || { echo "node is required." >&2; exit 1; }
if ls server/src/db/migrations/031_*.sql 2>/dev/null | grep -qv 031_conversation_pins.sql; then
  echo "Another migration 031 exists: $(ls server/src/db/migrations/031_*.sql | tr '\n' ' '). Nothing was changed." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/031_conversation_pins.sql
  server/src/messaging/conversationRules.js
  server/src/messaging/ConversationExtras.js
  server/test/messaging/conversationRules.check.mjs
  apps/web/src/components/Messenger/messengerModel.js
  apps/web/src/components/Messenger/Avatar.jsx
  apps/web/src/components/Messenger/Dialogs.jsx
  apps/web/src/components/Messenger/ProfileCard.jsx
  apps/web/src/components/Messenger/MessengerList.jsx
  apps/web/src/components/Messenger/MessengerThread.jsx
  apps/web/src/components/Messenger/ContactPanel.jsx
  apps/web/src/components/Messenger/messenger.css
  apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs
  apps/web/src/pages/MessagesPage.jsx
  server/src/messaging/models/Conversation.js
  server/src/messaging/ConversationService.js
  server/src/routes/messaging.routes.js
  packages/core-client/src/api/chatApi.ts
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .messages-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/031_conversation_pins.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  rmdir apps/web/src/components/Messenger/__checks__ apps/web/src/components/Messenger server/test/messaging 2>/dev/null || true
  echo "Restored from $FIRST. Migration 031 stays, because the database may already have it."
  exit 0
fi

BACKUP=".messages-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

restore_and_exit() {
  for f in "${TOUCHED[@]}"; do
    if [ -f "$BACKUP/$f" ]; then cp "$BACKUP/$f" "$f"; elif [ -f "$f" ]; then rm "$f"; fi
  done
  rm -f .messages-patch.mjs
  echo "$1 Every file was put back as it was." >&2
  exit 1
}

echo "--- patching existing files"
cat > .messages-patch.mjs <<'__MSG_EOF__'
// Patches existing files for the Messages rework. Every anchor is checked in
// every file before anything is written; a second run changes nothing.
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'server/src/messaging/models/Conversation.js',
    marker: 'p.pinned_at',
    edits: [
      {
        name: 'list: read the pin',
        find: '            p.muted, p.muted_until, p.last_read_at, p.cleared_at, p.hidden_at,\n',
        replace: '            p.muted, p.muted_until, p.last_read_at, p.cleared_at, p.hidden_at, p.pinned_at,\n',
      },
    ],
  },
  {
    file: 'server/src/messaging/ConversationService.js',
    marker: 'pinnedAt',
    edits: [
      {
        name: 'view: pinnedAt',
        find: '    created,\n  };\n};\n',
        replace:
          '    created,\n' +
          '    // Messages (031): pinned to the top of this person\'s list.\n' +
          '    pinnedAt: row.pinned_at ? new Date(row.pinned_at).toISOString() : null,\n' +
          '  };\n};\n',
      },
    ],
  },
  {
    file: 'server/src/routes/messaging.routes.js',
    marker: 'ConversationExtras',
    edits: [
      {
        name: 'import',
        find: "import * as ConversationService from '../messaging/ConversationService.js';\n",
        replace:
          "import * as ConversationService from '../messaging/ConversationService.js';\n" +
          "import * as ConversationExtras from '../messaging/ConversationExtras.js';\n",
      },
      {
        name: 'details and pin',
        find: '/** Leave a group; for a direct chat this is the same as delete for me. */\n',
        replace:
          '/** Messages: the panel beside a chat — shared spaces, counts, the edit window. */\n' +
          'router.get(\n' +
          "  '/conversations/:id/details',\n" +
          '  validate({ params: idParam }),\n' +
          '  route(mapped(async (req) => ConversationExtras.details({ conversationId: req.params.id, viewerId: req.user.id }))),\n' +
          ');\n' +
          '\n' +
          '/** Messages: pin a chat to the top of my own list. */\n' +
          'router.put(\n' +
          "  '/conversations/:id/pin',\n" +
          '  validate({ params: idParam, body: z.object({ pinned: z.boolean() }) }),\n' +
          '  route(mapped(async (req) => ConversationExtras.setPinned({ conversationId: req.params.id, userId: req.user.id, pinned: req.body.pinned }))),\n' +
          ');\n' +
          '\n' +
          '/** Leave a group; for a direct chat this is the same as delete for me. */\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/api/chatApi.ts',
    marker: 'ConversationDetailsSchema',
    edits: [
      {
        name: 'view: pinnedAt',
        find: '    created: z.boolean().optional(),\n',
        replace: '    created: z.boolean().optional(),\n    pinnedAt: z.string().nullable().default(null),\n',
      },
      {
        name: 'details schema',
        find: 'const ConversationPageSchema = z.object({\n',
        replace:
          'export const ConversationDetailsSchema = z\n' +
          '  .object({\n' +
          '    conversationId: z.string(),\n' +
          '    startedAt: z.string().nullable().default(null),\n' +
          '    pinnedAt: z.string().nullable().default(null),\n' +
          '    messageCount: z.number().default(0),\n' +
          '    sharedSpaces: z\n' +
          '      .array(z.object({ spaceId: z.string(), name: z.string(), emoji: z.string().nullable().default(null) }).passthrough())\n' +
          '      .default([]),\n' +
          '    editWindowMin: z.number().default(0),\n' +
          '  })\n' +
          '  .passthrough();\n' +
          'export type ConversationDetails = z.infer<typeof ConversationDetailsSchema>;\n' +
          '\n' +
          'const ConversationPageSchema = z.object({\n',
      },
      {
        name: 'interface',
        find: '  archiveConversation(conversationId: string, archived: boolean): Promise<void>;\n',
        replace:
          '  archiveConversation(conversationId: string, archived: boolean): Promise<void>;\n' +
          '  /** Messages: shared spaces, counts and the edit window for the panel beside a chat. */\n' +
          '  conversationDetails(conversationId: string, signal?: AbortSignal): Promise<ConversationDetails>;\n' +
          '  /** Messages: pin or unpin a chat in my own list. */\n' +
          '  pinConversation(conversationId: string, pinned: boolean): Promise<ConversationView>;\n',
      },
      {
        name: 'calls',
        find: '  archiveConversation: async (conversationId, archived) => {\n',
        replace:
          '  conversationDetails: (conversationId, signal) =>\n' +
          '    http.get(`/messaging/conversations/${encodeURIComponent(conversationId)}/details`, { schema: ConversationDetailsSchema, signal }),\n' +
          '\n' +
          '  pinConversation: (conversationId, pinned) =>\n' +
          '    http.put(`/messaging/conversations/${encodeURIComponent(conversationId)}/pin`, { pinned }, { schema: ConversationViewSchema }),\n' +
          '\n' +
          '  archiveConversation: async (conversationId, archived) => {\n',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  let src;
  try {
    src = readFileSync(entry.file, 'utf8');
  } catch {
    console.error(`${entry.file}: not found. Nothing was changed in any file.`);
    process.exit(1);
  }
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const count = src.split(edit.find).length - 1;
    if (count !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed in any file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.replace(edit.find, () => edit.replace);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__MSG_EOF__
node .messages-patch.mjs || { rm -f .messages-patch.mjs; exit 1; }
rm -f .messages-patch.mjs

echo "--- writing new files"
mkdir -p server/src/db/migrations
cat > server/src/db/migrations/031_conversation_pins.sql <<'__MSG_EOF__'
-- 031_conversation_pins.sql  (Messages)
--
-- Per-person: a conversation pinned to the top of this person's list. Like
-- muted_until, hidden_at and cleared_at (020), it belongs to the participant
-- row; the other side never sees it.
--
-- Additive only.

alter table conversation_participants add column if not exists pinned_at timestamptz;
__MSG_EOF__
echo "wrote server/src/db/migrations/031_conversation_pins.sql"
mkdir -p server/src/messaging
cat > server/src/messaging/conversationRules.js <<'__MSG_EOF__'
// classroom-app/server/src/messaging/conversationRules.js
/**
 * Small rules for the Messages page  (Messages)
 *
 * Pure, tested in server/test/messaging/conversationRules.check.mjs.
 */

/** How many conversations someone can pin. Messengers keep this small on purpose. */
export const MAX_PINNED = 5;

/** Whether a message can still be edited: own, not deleted, inside the window (0 = always). */
export const canEdit = ({ authorId, viewerId, deletedAt = null, createdAt, windowMin, now = Date.now() }) => {
  if (!authorId || authorId !== viewerId || deletedAt) return false;
  if (!windowMin || windowMin <= 0) return true;
  const created = new Date(createdAt).getTime();
  if (Number.isNaN(created)) return false;
  return now - created <= windowMin * 60_000;
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

/** A space both people belong to, as the details panel shows it. */
export const toSharedSpace = (row) => ({
  spaceId: row.space_id,
  name: row.name ?? 'A space',
  emoji: row.emoji ?? null,
});

/** The details panel's data for one conversation. */
export const toDetails = ({ conversation, sharedSpaces = [], messageCount = 0, editWindowMin = 0 }) => ({
  conversationId: conversation.id,
  startedAt: iso(conversation.created_at),
  pinnedAt: iso(conversation.pinned_at),
  messageCount: Number(messageCount) || 0,
  sharedSpaces: sharedSpaces.map(toSharedSpace),
  editWindowMin: Number(editWindowMin) || 0,
});

export default { MAX_PINNED, canEdit, toSharedSpace, toDetails };
__MSG_EOF__
echo "wrote server/src/messaging/conversationRules.js"
mkdir -p server/src/messaging
cat > server/src/messaging/ConversationExtras.js <<'__MSG_EOF__'
// classroom-app/server/src/messaging/ConversationExtras.js
/**
 * The details of a conversation, and pinning  (Messages)
 *
 *   details    for the panel beside a chat: when it started, how many
 *              messages you can see, the spaces you share with the other
 *              person, and how long messages stay editable
 *   setPinned  pin a chat to the top of your own list (MAX_PINNED at most);
 *              only your participant row changes
 *
 * Who may ask: participants only (ConversationService.assertParticipant).
 */

import { ApiError } from '@classroom/contracts';
import { pool } from '../db/pool.js';
import { env } from '../config/env.js';
import * as ConversationService from './ConversationService.js';
import * as Rules from './conversationRules.js';

export const details = async ({ conversationId, viewerId }) => {
  await ConversationService.assertParticipant({ conversationId, userId: viewerId });

  const { rows } = await pool.query(
    `SELECT c.id, c.kind, c.created_at, p.pinned_at, p.cleared_at
       FROM conversations c
       JOIN conversation_participants p ON p.conversation_id = c.id AND p.user_id = $2
      WHERE c.id = $1`,
    [conversationId, viewerId],
  );
  const conversation = rows[0];
  if (!conversation) throw new ApiError('not_found', { detail: 'Conversation not found.' });

  const { rows: counted } = await pool.query(
    `SELECT count(*)::int AS n FROM messages
      WHERE conversation_id = $1 AND deleted_at IS NULL
        AND created_at > coalesce($2::timestamptz, '-infinity'::timestamptz)`,
    [conversationId, conversation.cleared_at],
  );

  // Spaces shared with everyone else in the conversation (for a direct chat:
  // the other person). Read through to_jsonb so a missing optional column
  // (emoji, archived_at) is simply null.
  const { rows: others } = await pool.query(
    `SELECT user_id FROM conversation_participants WHERE conversation_id = $1 AND user_id <> $2 AND left_at IS NULL`,
    [conversationId, viewerId],
  );
  let sharedSpaces = [];
  if (others.length > 0 && others.length <= 20) {
    const { rows: spaces } = await pool.query(
      `SELECT s.id AS space_id, s.name, to_jsonb(s) ->> 'emoji' AS emoji
         FROM spaces s
         JOIN space_memberships mine ON mine.space_id = s.id AND mine.user_id = $1
        WHERE (to_jsonb(s) ->> 'archived_at') IS NULL
          AND (SELECT count(DISTINCT o.user_id) FROM space_memberships o
                WHERE o.space_id = s.id AND o.user_id = ANY($2::uuid[])) = cardinality($2::uuid[])
        ORDER BY lower(s.name)
        LIMIT 20`,
      [viewerId, others.map((row) => row.user_id)],
    );
    sharedSpaces = spaces;
  }

  return Rules.toDetails({
    conversation,
    sharedSpaces,
    messageCount: counted[0]?.n ?? 0,
    editWindowMin: env.CHAT_EDIT_WINDOW_MIN ?? 0,
  });
};

export const setPinned = async ({ conversationId, userId, pinned }) => {
  await ConversationService.assertParticipant({ conversationId, userId });
  if (pinned) {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n FROM conversation_participants
        WHERE user_id = $1 AND pinned_at IS NOT NULL AND left_at IS NULL AND hidden_at IS NULL AND conversation_id <> $2`,
      [userId, conversationId],
    );
    if ((rows[0]?.n ?? 0) >= Rules.MAX_PINNED) {
      throw new ApiError('conflict', { detail: `You can pin up to ${Rules.MAX_PINNED} chats. Unpin one first.` });
    }
  }
  await pool.query(
    `UPDATE conversation_participants SET pinned_at = CASE WHEN $3 THEN coalesce(pinned_at, now()) ELSE NULL END
      WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId, Boolean(pinned)],
  );
  return ConversationService.getById({ conversationId, viewerId: userId });
};

export default { details, setPinned };
__MSG_EOF__
echo "wrote server/src/messaging/ConversationExtras.js"
mkdir -p server/test/messaging
cat > server/test/messaging/conversationRules.check.mjs <<'__MSG_EOF__'
// node --test server/test/messaging/conversationRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MAX_PINNED, canEdit, toDetails } from '../../src/messaging/conversationRules.js';

const NOW = Date.parse('2026-10-02T12:00:00Z');
const base = { authorId: 'u1', viewerId: 'u1', createdAt: '2026-10-02T11:50:00Z', windowMin: 15, now: NOW };

test('own messages are editable inside the window', () => {
  assert.equal(canEdit(base), true);
  assert.equal(canEdit({ ...base, createdAt: '2026-10-02T11:44:00Z' }), false, '16 minutes old');
  assert.equal(canEdit({ ...base, windowMin: 0, createdAt: '2020-01-01T00:00:00Z' }), true, '0 means always');
});

test('not someone else’s, not deleted, not without a date', () => {
  assert.equal(canEdit({ ...base, viewerId: 'u2' }), false);
  assert.equal(canEdit({ ...base, deletedAt: '2026-10-02T11:55:00Z' }), false);
  assert.equal(canEdit({ ...base, createdAt: 'nonsense' }), false);
  assert.equal(canEdit({ ...base, authorId: null }), false);
});

test('details view', () => {
  const view = toDetails({
    conversation: { id: 'c1', created_at: '2026-09-01T08:00:00Z', pinned_at: null },
    sharedSpaces: [{ space_id: 's1', name: 'Algebra', emoji: '➗' }, { space_id: 's2' }],
    messageCount: '12',
    editWindowMin: 15,
  });
  assert.deepEqual(view, {
    conversationId: 'c1', startedAt: '2026-09-01T08:00:00.000Z', pinnedAt: null, messageCount: 12,
    sharedSpaces: [{ spaceId: 's1', name: 'Algebra', emoji: '➗' }, { spaceId: 's2', name: 'A space', emoji: null }],
    editWindowMin: 15,
  });
  assert.ok(MAX_PINNED >= 3 && MAX_PINNED <= 10);
});
__MSG_EOF__
echo "wrote server/test/messaging/conversationRules.check.mjs"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/messengerModel.js <<'__MSG_EOF__'
/**
 * Pure helpers for the Messages page  (Messages)
 *
 * Tested in __checks__/messengerModel.check.mjs. The server decides what may
 * be edited, sent or seen; these only order, group and word things so the
 * page shows the same answer before it asks.
 */

const HOUR = 60 * 60 * 1000;

export const MUTE_CHOICES = [
  { id: '1h', label: 'For 1 hour', ms: HOUR },
  { id: '8h', label: 'For 8 hours', ms: 8 * HOUR },
  { id: '1d', label: 'For 1 day', ms: 24 * HOUR },
  { id: '1w', label: 'For 1 week', ms: 7 * 24 * HOUR },
  { id: 'on', label: 'Until I turn it back on', ms: null },
];

export const muteUntil = (choice, now = Date.now()) => (choice?.ms ? new Date(now + choice.ms).toISOString() : null);

export const REPORT_REASONS = [
  { value: 'harassment', label: 'Harassment or bullying' },
  { value: 'abuse', label: 'Abusive or hateful messages' },
  { value: 'spam', label: 'Spam' },
  { value: 'impersonation', label: 'Pretending to be someone else' },
  { value: 'nsfw', label: 'Sexual or shocking content' },
  { value: 'other', label: 'Something else' },
];

/** "MK" for "Mara Klein", "A" for "anna". */
export const initials = (name) => {
  const parts = String(name ?? '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  const letters = parts.length === 1 ? [parts[0][0]] : [parts[0][0], parts.at(-1)[0]];
  return letters.join('').toUpperCase();
};

/** A stable hue per person, so the same person always has the same colour. */
export const hueOf = (seed) => {
  let hash = 0;
  for (const char of String(seed ?? '')) hash = (hash * 31 + char.codePointAt(0)) >>> 0;
  return hash % 360;
};

/** Pinned first (most recently pinned on top), then by last activity. */
export const sortConversations = (list = []) => {
  const activity = (c) => Date.parse(c.lastMessageAt ?? c.createdAt) || 0;
  return [...list].sort((a, b) => {
    const pa = a.pinnedAt ? Date.parse(a.pinnedAt) : 0;
    const pb = b.pinnedAt ? Date.parse(b.pinnedAt) : 0;
    if (Boolean(pa) !== Boolean(pb)) return pa ? -1 : 1;
    if (pa && pb && pa !== pb) return pb - pa;
    return activity(b) - activity(a);
  });
};

/** Case- and accent-insensitive "contains". */
const fold = (text) => String(text ?? '').normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
export const matches = (text, query) => {
  const needle = fold(query).trim();
  return needle ? fold(text).includes(needle) : true;
};

/** Splits text around every match, for <mark>: [{ text, hit }]. */
export const highlightParts = (text, query) => {
  const source = String(text ?? '');
  const needle = fold(query).trim();
  if (!needle) return [{ text: source, hit: false }];
  const folded = fold(source);
  // Folding can change the length (ß, ligatures); highlight only when it did not.
  if (folded.length !== source.length) return [{ text: source, hit: folded.includes(needle) }];
  const parts = [];
  let at = 0;
  for (let index = folded.indexOf(needle); index !== -1; index = folded.indexOf(needle, index + needle.length)) {
    if (index > at) parts.push({ text: source.slice(at, index), hit: false });
    parts.push({ text: source.slice(index, index + needle.length), hit: true });
    at = index + needle.length;
  }
  if (at < source.length) parts.push({ text: source.slice(at), hit: false });
  return parts;
};

const startOfDay = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();

/** Today · Yesterday · Monday … for the last week · a date before that. */
export const dayLabel = (iso, now = new Date(), formatDate = (d) => d.toLocaleDateString()) => {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  const days = Math.round((startOfDay(now) - startOfDay(date)) / (24 * HOUR));
  if (days === 0) return 'Today';
  if (days === 1) return 'Yesterday';
  if (days > 1 && days < 7) return date.toLocaleDateString('en', { weekday: 'long' });
  return formatDate(date);
};

/** Messages of one author within this gap form one group (one name, one avatar). */
export const GROUP_GAP_MS = 5 * 60 * 1000;

/**
 * The thread as rows: day separators, and messages marked as the first or
 * last of a run by the same person.
 */
export const threadRows = (messages = []) => {
  const rows = [];
  let previous = null;
  let previousDay = null;
  for (const message of messages) {
    const date = new Date(message.createdAt);
    const day = Number.isNaN(date.getTime()) ? previousDay : startOfDay(date);
    if (day !== previousDay) {
      rows.push({ type: 'day', key: `day-${day}`, at: message.createdAt });
      previous = null;
      previousDay = day;
    }
    const authorId = message.author?.userId ?? null;
    const startsGroup =
      !previous || previous.author?.userId !== authorId || Date.parse(message.createdAt) - Date.parse(previous.createdAt) > GROUP_GAP_MS;
    if (!startsGroup && rows.at(-1)?.type === 'message') rows.at(-1).lastInGroup = false;
    rows.push({ type: 'message', key: message.clientMessageId ?? message.messageId, message, firstInGroup: startsGroup, lastInGroup: true });
    previous = message;
  }
  return rows;
};

/** Same rule as the server (conversationRules.canEdit): own, sent, not deleted, inside the window. */
export const canEdit = (message, { selfUserId, windowMin = 0, now = Date.now() } = {}) => {
  if (!message || message.author?.userId !== selfUserId || message.deletedAt || message.delivery !== 'sent') return false;
  if (!windowMin || windowMin <= 0) return true;
  const created = Date.parse(message.createdAt);
  return !Number.isNaN(created) && now - created <= windowMin * 60_000;
};

export const canDelete = (message, { selfUserId } = {}) =>
  Boolean(message) && message.author?.userId === selfUserId && !message.deletedAt && message.delivery === 'sent';

/** The newest message the person can still edit — what ↑ in an empty composer opens. */
export const lastEditable = (messages = [], options = {}) => {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (canEdit(messages[index], options)) return messages[index];
  }
  return null;
};

/** Ids of the messages whose text matches, oldest first. */
export const searchHits = (messages = [], query = '') =>
  query.trim() ? messages.filter((m) => !m.deletedAt && matches(m.body, query)).map((m) => m.messageId) : [];

/** "Muted until 14:30" or "Muted", or null. */
export const muteState = (item, now = Date.now()) => {
  if (!item?.muted) return null;
  if (!item.mutedUntil) return { forever: true };
  const until = Date.parse(item.mutedUntil);
  return until > now ? { until: item.mutedUntil } : null;
};

/** The first line of a message, for a reply chip or quote. */
export const snippet = (body, max = 90) => {
  const line = String(body ?? '').replace(/\s+/g, ' ').trim();
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
};
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/messengerModel.js"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/Avatar.jsx <<'__MSG_EOF__'
import { hueOf, initials } from './messengerModel.js';

/** A round picture, or initials on a colour that is always the same for the same person. */
export default function Avatar({ name, url = null, seed, size = 40, className = '' }) {
  const style = { width: size, height: size, fontSize: Math.round(size * 0.38), '--mx-hue': hueOf(seed ?? name) };
  return (
    <span className={`mx-avatar ${className}`.trim()} style={style} aria-hidden="true">
      {url ? <img src={url} alt="" /> : initials(name)}
    </span>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/Avatar.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/Dialogs.jsx <<'__MSG_EOF__'
import { useEffect, useRef, useState } from 'react';
import { REPORT_REASONS } from './messengerModel.js';

/**
 * Dialogs of the Messages page  (Messages)
 *
 * Native <dialog>: focus stays inside, Esc closes, the page behind is inert.
 */

export function useModal(onClose) {
  const ref = useRef(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog && !dialog.open) dialog.showModal?.();
    const onCancel = (event) => {
      event.preventDefault();
      onClose();
    };
    dialog?.addEventListener('cancel', onCancel);
    return () => dialog?.removeEventListener('cancel', onCancel);
  }, [onClose]);
  return ref;
}

/** "Are you sure?" with the consequence spelled out. */
export function ConfirmDialog({ title, body, confirmLabel, danger = false, onConfirm, onClose }) {
  const ref = useModal(onClose);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const confirm = async () => {
    setBusy(true);
    setError(null);
    try {
      await onConfirm();
      onClose();
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'That did not work. Try again.');
      setBusy(false);
    }
  };
  return (
    <dialog ref={ref} className="app-dialog mx-dialog" aria-labelledby="mx-confirm-title">
      <div className="app-dialog__body">
        <h2 id="mx-confirm-title">{title}</h2>
        {body ? <p>{body}</p> : null}
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button type="button" className={danger ? 'btn btn--danger' : 'btn btn--primary'} onClick={confirm} disabled={busy}>
            {busy ? 'One moment…' : confirmLabel}
          </button>
        </div>
      </div>
    </dialog>
  );
}

/** Report a person to the moderators of the organisation. */
export function ReportDialog({ person, profiles, onClose, onDone }) {
  const ref = useModal(onClose);
  const [reason, setReason] = useState('harassment');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const send = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await profiles.report({ userId: person.userId, reason, detail: note.trim() || undefined });
      onDone?.();
      onClose();
    } catch (cause) {
      setError(cause?.detail ?? 'The report was not sent. Try again.');
      setBusy(false);
    }
  };
  return (
    <dialog ref={ref} className="app-dialog mx-dialog" aria-labelledby="mx-report-title">
      <form className="app-dialog__body" onSubmit={send}>
        <h2 id="mx-report-title">Report {person.displayName}</h2>
        <p className="mx-muted">Moderators of your organisation see the report. {person.displayName} is not told who sent it.</p>
        <fieldset className="mx-radios">
          <legend className="mx-sr">Reason</legend>
          {REPORT_REASONS.map((option) => (
            <label key={option.value} className={reason === option.value ? 'is-on' : ''}>
              <input type="radio" name="reason" value={option.value} checked={reason === option.value} onChange={() => setReason(option.value)} />
              {option.label}
            </label>
          ))}
        </fieldset>
        <label className="app-dialog__field">
          What happened? (optional)
          <textarea value={note} maxLength={2000} rows={3} onChange={(event) => setNote(event.target.value)} />
        </label>
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button type="submit" className="btn btn--danger" disabled={busy}>
            {busy ? 'Sending…' : 'Send report'}
          </button>
        </div>
      </form>
    </dialog>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/Dialogs.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/ProfileCard.jsx <<'__MSG_EOF__'
import { useEffect, useState } from 'react';
import Avatar from './Avatar.jsx';
import { useModal } from './Dialogs.jsx';

/**
 * A person's profile  (Messages)
 *
 * What GET /profiles/:id answers for this viewer — the server already applies
 * the person's "who can see my profile" setting, so hidden parts simply do not
 * arrive. Used at the top of the details panel and in the dialog that opens
 * when you click someone's name or picture in a chat.
 */

const ROLE = { owner: 'Administrator', teacher: 'Teacher', learner: 'Learner' };

export function useProfile(profiles, userId, version = 0) {
  const [state, setState] = useState({ profile: null, error: null });
  useEffect(() => {
    if (!userId) return undefined;
    const controller = new AbortController();
    setState({ profile: null, error: null });
    profiles
      .get(userId, { signal: controller.signal })
      .then((profile) => setState({ profile, error: null }))
      .catch(() => !controller.signal.aborted && setState({ profile: null, error: 'This profile could not be loaded.' }));
    return () => controller.abort();
  }, [profiles, userId, version]);
  return state;
}

export function ProfileSummary({ person, profile, error, large = false }) {
  const name = profile?.displayName ?? person?.displayName ?? 'Unknown';
  return (
    <div className={large ? 'mx-profile mx-profile--large' : 'mx-profile'}>
      <Avatar name={name} url={profile?.avatarUrl ?? person?.avatarUrl ?? null} seed={person?.userId} size={large ? 88 : 64} />
      <div className="mx-profile__names">
        <strong className="mx-profile__name">{name}</strong>
        <span className="mx-muted">
          {[profile?.handle ? `@${profile.handle}` : null, ROLE[profile?.role] ?? null].filter(Boolean).join(' · ')}
        </span>
      </div>
      {profile?.headline ? <p className="mx-profile__headline">{profile.headline}</p> : null}
      {profile?.bio ? <p className="mx-profile__bio">{profile.bio}</p> : null}
      {profile?.links?.length ? (
        <ul className="mx-profile__links">
          {profile.links.map((link) => (
            <li key={link.url}>
              <a href={link.url} target="_blank" rel="noopener noreferrer">
                {link.label || link.url}
              </a>
            </li>
          ))}
        </ul>
      ) : null}
      {error ? <p className="mx-muted">{error}</p> : null}
      {!profile && !error ? <p className="mx-muted">Loading…</p> : null}
    </div>
  );
}

/** The dialog for anyone you click in a chat. "Message" opens (or creates) the chat with them. */
export function ProfileDialog({ person, profiles, selfUserId, onMessage, onClose }) {
  const ref = useModal(onClose);
  const { profile, error } = useProfile(profiles, person.userId);
  const isSelf = person.userId === selfUserId;
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState(null);
  const message = async () => {
    setBusy(true);
    setProblem(null);
    try {
      await onMessage(person);
      onClose();
    } catch (cause) {
      setProblem(cause?.detail ?? `You cannot write to ${person.displayName} right now.`);
      setBusy(false);
    }
  };
  return (
    <dialog ref={ref} className="app-dialog mx-dialog" aria-label={`Profile of ${person.displayName}`}>
      <div className="app-dialog__body">
        <ProfileSummary person={person} profile={profile} error={error} large />
        {profile && !isSelf && !profile.canMessage && profile.cannotMessageReason ? <p className="mx-muted">{profile.cannotMessageReason}</p> : null}
        {problem ? <p className="app-dialog__error" role="alert">{problem}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose}>
            Close
          </button>
          {!isSelf && onMessage ? (
            <button type="button" className="btn btn--primary" onClick={message} disabled={busy || (profile && !profile.canMessage)}>
              {busy ? 'Opening…' : 'Message'}
            </button>
          ) : null}
        </div>
      </div>
    </dialog>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/ProfileCard.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/MessengerList.jsx <<'__MSG_EOF__'
import { useMemo, useState } from 'react';
import { isMutedNow, otherParticipant, titleOf } from '@classroom/core-client';
import { formatDate, formatTime } from '../../lib/preferences.js';
import Avatar from './Avatar.jsx';
import { highlightParts, matches, sortConversations } from './messengerModel.js';

/**
 * The conversation list  (Messages)
 *
 * Pinned chats first, then by last activity. A filter box narrows the list by
 * name or by the last message. Unread chats are bold with a count; muted ones
 * show a bell and a grey count. Chats nobody has written in yet stay out,
 * except the one that is open.
 */

const shortTime = (iso) => {
  if (!iso) return '';
  const date = new Date(iso);
  return date.toDateString() === new Date().toDateString() ? formatTime(date) : formatDate(date);
};

function Highlight({ text, query }) {
  return highlightParts(text, query).map((part, index) => (part.hit ? <mark key={index}>{part.text}</mark> : <span key={index}>{part.text}</span>));
}

export default function MessengerList({ rooms, self, activeId, onOpen }) {
  const [filter, setFilter] = useState('');

  const items = useMemo(() => {
    const visible = rooms.conversations.filter((c) => c.lastMessageAt || c.unreadCount > 0 || c.conversationId === activeId || c.pinnedAt);
    return sortConversations(visible)
      .map((conversation) => ({ conversation, title: titleOf(conversation, self.userId) }))
      .filter(({ conversation, title }) => matches(title, filter) || matches(conversation.lastMessagePreview?.body, filter));
  }, [rooms.conversations, activeId, self.userId, filter]);

  const pinned = items.filter((item) => item.conversation.pinnedAt);
  const others = items.filter((item) => !item.conversation.pinnedAt);

  const row = ({ conversation, title }) => {
    const other = conversation.kind === 'direct' ? otherParticipant(conversation, self.userId) : null;
    const preview = conversation.lastMessagePreview;
    const muted = isMutedNow(conversation);
    const unread = conversation.unreadCount || 0;
    const active = conversation.conversationId === activeId;
    return (
      <li key={conversation.conversationId}>
        <button
          type="button"
          className={`mx-row${unread ? ' is-unread' : ''}${active ? ' is-active' : ''}`}
          aria-current={active ? 'true' : undefined}
          onClick={() => onOpen(conversation.conversationId)}
        >
          <Avatar name={title} url={other?.profile?.avatarUrl ?? null} seed={other?.userId ?? conversation.conversationId} size={46} />
          <span className="mx-row__main">
            <span className="mx-row__top">
              <span className="mx-row__name">
                <Highlight text={title} query={filter} />
              </span>
              <span className="mx-row__time">{shortTime(conversation.lastMessageAt ?? conversation.createdAt)}</span>
            </span>
            <span className="mx-row__bottom">
              <span className="mx-row__preview">
                {preview ? (
                  <>
                    {preview.authorId === self.userId ? <span className="mx-row__you">You: </span> : null}
                    <Highlight text={preview.body} query={filter} />
                  </>
                ) : (
                  'No messages yet'
                )}
              </span>
              <span className="mx-row__marks">
                {conversation.pinnedAt ? <span className="mx-row__icon" title="Pinned" aria-label="Pinned">📌</span> : null}
                {muted ? <span className="mx-row__icon" title="Muted" aria-label="Muted">🔕</span> : null}
                {unread ? (
                  <span className={`mx-badge${muted ? ' is-muted' : ''}`} aria-label={`${unread} unread`}>
                    {unread > 99 ? '99+' : unread}
                  </span>
                ) : null}
              </span>
            </span>
          </span>
        </button>
      </li>
    );
  };

  return (
    <nav className="mx-list" aria-label="Conversations">
      <div className="mx-list__search">
        <input type="search" placeholder="Search chats" aria-label="Search chats" value={filter} onChange={(event) => setFilter(event.target.value)} />
      </div>
      <div className="mx-list__scroll">
        {rooms.error && rooms.conversations.length === 0 ? (
          <div className="mx-list__notice">
            <p>Your chats could not be loaded.</p>
            <button type="button" className="btn" onClick={() => rooms.refresh()}>
              Try again
            </button>
          </div>
        ) : null}
        {rooms.loading && rooms.conversations.length === 0 ? <p className="mx-list__notice">Loading…</p> : null}
        {!rooms.loading && items.length === 0 && !rooms.error ? (
          <p className="mx-list__notice">{filter ? 'No chat matches.' : 'No conversations yet. Start one with “New message”.'}</p>
        ) : null}
        {pinned.length ? (
          <>
            <p className="mx-list__group">Pinned</p>
            <ul>{pinned.map(row)}</ul>
            {others.length ? <p className="mx-list__group">All chats</p> : null}
          </>
        ) : null}
        <ul>{others.map(row)}</ul>
      </div>
    </nav>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/MessengerList.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/MessengerThread.jsx <<'__MSG_EOF__'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useChat } from '@classroom/core-client';
import { formatDate, formatTime } from '../../lib/preferences.js';
import Avatar from './Avatar.jsx';
import { ConfirmDialog } from './Dialogs.jsx';
import { canDelete, canEdit, dayLabel, highlightParts, lastEditable, searchHits, snippet, threadRows } from './messengerModel.js';

/**
 * One conversation  (Messages)
 *
 *   messages   grouped by day and by person; names and pictures open the
 *              person's profile
 *   actions    on hover (or the ⋯ button on touch screens): Reply, Edit (your
 *              own, within the edit window), Copy, Delete (your own, for
 *              everyone). Edits and deletes reach the other side live.
 *   composer   Enter sends, Shift+Enter is a new line, ↑ in an empty composer
 *              edits your last message, Esc cancels a reply or an edit
 *   search     finds text in the loaded messages, highlights it and jumps
 *              between hits; "Load earlier" reaches further back
 *
 * Sending, editing and deleting go through useChat (core-client), the same as
 * everywhere else, so the server's rules (blocks, privacy, edit window) apply.
 */

const MAX_LENGTH = 4000;

function Text({ body, query }) {
  return highlightParts(body, query).map((part, index) => (part.hit ? <mark key={index}>{part.text}</mark> : <span key={index}>{part.text}</span>));
}

function AutoTextarea({ value, onChange, onKeyDown, placeholder, disabled, inputRef, label }) {
  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 180)}px`;
  }, [value, inputRef]);
  return (
    <textarea
      ref={inputRef}
      rows={1}
      value={value}
      maxLength={MAX_LENGTH}
      placeholder={placeholder}
      aria-label={label}
      disabled={disabled}
      onChange={onChange}
      onKeyDown={onKeyDown}
    />
  );
}

function MessageActions({ message, mine, editable, deletable, onReply, onEdit, onCopy, onDelete }) {
  if (message.deletedAt || message.delivery !== 'sent') return null;
  return (
    <span className={`mx-actions${mine ? ' is-mine' : ''}`} role="toolbar" aria-label="Message actions">
      <button type="button" onClick={onReply} title="Reply" aria-label="Reply">↩</button>
      {editable ? <button type="button" onClick={onEdit} title="Edit" aria-label="Edit">✎</button> : null}
      <button type="button" onClick={onCopy} title="Copy text" aria-label="Copy text">⧉</button>
      {deletable ? <button type="button" className="is-danger" onClick={onDelete} title="Delete" aria-label="Delete">🗑</button> : null}
    </span>
  );
}

export default function MessengerThread({ api, socket, self, conversation, title, other, editWindowMin, search, onSearchChange, searchOpen, onCloseSearch, onOpenProfile, disabledReason = '' }) {
  const target = useMemo(() => ({ kind: 'conversation', conversationId: conversation.conversationId }), [conversation.conversationId]);
  const { messages, loading, loadingOlder, hasMore, loadOlder, typingUserIds, throttledUntil, send, retry, edit, remove, setTyping, error } = useChat({
    api,
    socket: socket ?? undefined,
    target,
    self,
  });

  const [draft, setDraft] = useState('');
  const [replyTo, setReplyTo] = useState(null);
  const [editing, setEditing] = useState(null); // { messageId, text }
  const [editError, setEditError] = useState(null);
  const [confirmDelete, setConfirmDelete] = useState(null);
  const [notice, setNotice] = useState(null);
  const [hitIndex, setHitIndex] = useState(0);
  const scrollRef = useRef(null);
  const composerRef = useRef(null);
  const editRef = useRef(null);
  const stickToBottom = useRef(true);
  const noticeTimer = useRef(null);

  const rules = { selfUserId: self.userId, windowMin: editWindowMin };
  const rows = useMemo(() => threadRows(messages), [messages]);
  const byId = useMemo(() => new Map(messages.map((m) => [m.messageId, m])), [messages]);
  const hits = useMemo(() => searchHits(messages, search), [messages, search]);
  const throttled = throttledUntil !== null && throttledUntil > Date.now();
  const disabled = throttled || Boolean(disabledReason);

  const say = (text) => {
    window.clearTimeout(noticeTimer.current);
    setNotice(text);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 3500);
  };
  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);

  // Stay at the bottom while new messages arrive, unless the person scrolled up to read.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el && stickToBottom.current) el.scrollTop = el.scrollHeight;
  }, [messages.length]);
  const onScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    stickToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  };

  // A new chat: start at the bottom, composer focused, nothing half-done.
  useEffect(() => {
    stickToBottom.current = true;
    setDraft('');
    setReplyTo(null);
    setEditing(null);
    composerRef.current?.focus({ preventScroll: true });
  }, [conversation.conversationId]);

  // Search: jump to the newest hit, then wherever the arrows say.
  useEffect(() => setHitIndex(Math.max(0, hits.length - 1)), [search]); // eslint-disable-line react-hooks/exhaustive-deps
  const activeHit = hits.length ? hits[Math.min(hitIndex, hits.length - 1)] : null;
  useEffect(() => {
    if (!activeHit) return;
    stickToBottom.current = false;
    scrollRef.current?.querySelector(`[data-message-id="${CSS.escape(activeHit)}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }, [activeHit]);

  const jumpTo = (messageId) => {
    stickToBottom.current = false;
    const el = scrollRef.current?.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
    if (!el) return say('That message is further back. Load earlier messages to see it.');
    el.scrollIntoView({ block: 'center', behavior: 'smooth' });
    el.classList.add('is-flash');
    window.setTimeout(() => el.classList.remove('is-flash'), 1400);
    return undefined;
  };

  const submit = async () => {
    const body = draft.trim();
    if (!body || disabled) return;
    setDraft('');
    setTyping(false);
    stickToBottom.current = true;
    const reply = replyTo;
    setReplyTo(null);
    await send({ body, ...(reply ? { replyToId: reply.messageId } : {}) });
  };

  const startEdit = useCallback((message) => {
    setEditError(null);
    setEditing({ messageId: message.messageId, text: message.body });
    window.requestAnimationFrame(() => {
      const el = editRef.current;
      if (el) {
        el.focus();
        el.setSelectionRange(el.value.length, el.value.length);
      }
    });
  }, []);

  const saveEdit = async () => {
    const message = byId.get(editing.messageId);
    const text = editing.text.trim();
    if (!text) return setEditError('A message cannot be empty. Delete it instead.');
    if (text === message?.body) return setEditing(null);
    try {
      await edit(editing.messageId, text);
      setEditing(null);
      setEditError(null);
      composerRef.current?.focus();
    } catch (cause) {
      setEditError(cause?.detail ?? 'The change was not saved.');
    }
    return undefined;
  };

  const copy = async (message) => {
    try {
      await navigator.clipboard.writeText(message.body);
      say('Copied.');
    } catch {
      say('Copying is not allowed in this browser.');
    }
  };

  const onComposerKey = (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      submit();
    } else if (event.key === 'ArrowUp' && !draft) {
      const last = lastEditable(messages, rules);
      if (last) {
        event.preventDefault();
        startEdit(last);
      }
    } else if (event.key === 'Escape' && replyTo) {
      setReplyTo(null);
    }
  };

  const typingName = typingUserIds.length === 1 ? (typingUserIds[0] === other?.userId ? other?.profile?.displayName : 'Someone') : null;

  return (
    <div className="mx-thread">
      {searchOpen ? (
        <div className="mx-findbar" role="search">
          <input
            type="search"
            autoFocus
            placeholder="Search in this chat"
            aria-label="Search in this chat"
            value={search}
            onChange={(event) => onSearchChange(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') setHitIndex((i) => (event.shiftKey ? Math.min(hits.length - 1, i + 1) : Math.max(0, i - 1)));
              if (event.key === 'Escape') onCloseSearch();
            }}
          />
          <span className="mx-findbar__count" aria-live="polite">
            {search.trim() ? (hits.length ? `${Math.min(hitIndex, hits.length - 1) + 1} of ${hits.length}` : 'No results') : ''}
          </span>
          <button type="button" className="mx-iconbtn" disabled={!hits.length || hitIndex <= 0} onClick={() => setHitIndex((i) => Math.max(0, i - 1))} aria-label="Earlier result">↑</button>
          <button type="button" className="mx-iconbtn" disabled={!hits.length || hitIndex >= hits.length - 1} onClick={() => setHitIndex((i) => Math.min(hits.length - 1, i + 1))} aria-label="Later result">↓</button>
          <button type="button" className="mx-iconbtn" onClick={onCloseSearch} aria-label="Close search">×</button>
        </div>
      ) : null}

      <div className="mx-messages" ref={scrollRef} onScroll={onScroll}>
        <div className="mx-messages__inner">
          {hasMore ? (
            <button type="button" className="mx-loadmore" onClick={() => loadOlder()} disabled={loadingOlder}>
              {loadingOlder ? 'Loading…' : 'Load earlier messages'}
            </button>
          ) : null}
          {!loading && !hasMore ? (
            <div className="mx-start">
              <Avatar name={title} url={other?.profile?.avatarUrl ?? null} seed={other?.userId ?? conversation.conversationId} size={72} />
              <p className="mx-start__title">{title}</p>
              <p className="mx-muted">This is the start of your conversation{other ? ` with ${title}` : ''}.</p>
            </div>
          ) : null}
          {loading ? <p className="mx-muted mx-center">Loading messages…</p> : null}
          {error && !loading && messages.length === 0 ? <p className="mx-error mx-center">Messages could not be loaded.</p> : null}

          {rows.map((row) => {
            if (row.type === 'day') {
              return (
                <div key={row.key} className="mx-day" role="separator">
                  <span>{dayLabel(row.at, new Date(), formatDate)}</span>
                </div>
              );
            }
            const { message, firstInGroup, lastInGroup } = row;
            const mine = message.author?.userId === self.userId;
            const author = message.author ?? { userId: null, displayName: 'Unknown' };
            const reply = message.replyToId ? byId.get(message.replyToId) : null;
            const isEditing = editing?.messageId === message.messageId;
            const isHit = activeHit === message.messageId;
            return (
              <div
                key={row.key}
                data-message-id={message.messageId}
                className={[
                  'mx-msg',
                  mine ? 'is-mine' : 'is-theirs',
                  firstInGroup ? 'is-first' : '',
                  lastInGroup ? 'is-last' : '',
                  message.delivery === 'failed' ? 'is-failed' : '',
                  message.delivery === 'sending' ? 'is-sending' : '',
                  isHit ? 'is-hit' : '',
                ].filter(Boolean).join(' ')}
              >
                {!mine ? (
                  <span className="mx-msg__gutter">
                    {lastInGroup ? (
                      <button type="button" className="mx-msg__avatar" onClick={() => onOpenProfile(author)} aria-label={`Profile of ${author.displayName}`}>
                        <Avatar name={author.displayName} url={author.avatarUrl ?? null} seed={author.userId} size={32} />
                      </button>
                    ) : null}
                  </span>
                ) : null}
                <div className="mx-msg__col">
                  {!mine && firstInGroup ? (
                    <button type="button" className="mx-msg__author" onClick={() => onOpenProfile(author)}>
                      {author.displayName}
                    </button>
                  ) : null}
                  <div className="mx-msg__line">
                    <div className="mx-bubble">
                      {message.replyToId ? (
                        <button type="button" className="mx-quote" onClick={() => jumpTo(message.replyToId)}>
                          <strong>{reply ? (reply.author?.userId === self.userId ? 'You' : reply.author?.displayName) : 'Reply'}</strong>
                          <span>{reply ? (reply.deletedAt ? 'Message deleted' : snippet(reply.body)) : 'to an earlier message'}</span>
                        </button>
                      ) : null}
                      {isEditing ? (
                        <form
                          className="mx-edit"
                          onSubmit={(event) => {
                            event.preventDefault();
                            saveEdit();
                          }}
                        >
                          <AutoTextarea
                            inputRef={editRef}
                            label="Edit message"
                            value={editing.text}
                            onChange={(event) => setEditing({ ...editing, text: event.target.value })}
                            onKeyDown={(event) => {
                              if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
                                event.preventDefault();
                                saveEdit();
                              }
                              if (event.key === 'Escape') {
                                event.stopPropagation();
                                setEditing(null);
                                setEditError(null);
                                composerRef.current?.focus();
                              }
                            }}
                          />
                          <span className="mx-edit__hint">
                            Enter to save · Esc to cancel
                            <span className="mx-edit__buttons">
                              <button type="button" className="mx-textbtn" onClick={() => setEditing(null)}>Cancel</button>
                              <button type="submit" className="mx-textbtn is-primary">Save</button>
                            </span>
                          </span>
                          {editError ? <span className="mx-error">{editError}</span> : null}
                        </form>
                      ) : message.deletedAt ? (
                        <em className="mx-deleted">This message was deleted</em>
                      ) : (
                        <span className="mx-bubble__text">
                          <Text body={message.body} query={search} />
                        </span>
                      )}
                      {!isEditing ? (
                        <span className="mx-bubble__meta">
                          {message.editedAt && !message.deletedAt ? <span>edited · </span> : null}
                          {message.delivery === 'sending' ? 'Sending…' : formatTime(new Date(message.createdAt))}
                        </span>
                      ) : null}
                    </div>
                    {!isEditing ? (
                      <MessageActions
                        message={message}
                        mine={mine}
                        editable={canEdit(message, rules)}
                        deletable={canDelete(message, rules)}
                        onReply={() => {
                          setReplyTo(message);
                          composerRef.current?.focus();
                        }}
                        onEdit={() => startEdit(message)}
                        onCopy={() => copy(message)}
                        onDelete={() => setConfirmDelete(message)}
                      />
                    ) : null}
                  </div>
                  {message.delivery === 'failed' ? (
                    <button type="button" className="mx-retry" onClick={() => retry(message.clientMessageId)}>
                      Not sent. Tap to try again.
                    </button>
                  ) : null}
                </div>
              </div>
            );
          })}
          {typingUserIds.length ? <p className="mx-typing">{typingName ? `${typingName} is typing…` : 'Someone is typing…'}</p> : null}
        </div>
      </div>

      {notice ? <p className="mx-toast" role="status">{notice}</p> : null}

      <div className="mx-composer">
        {disabledReason ? <p className="mx-composer__notice">{disabledReason}</p> : null}
        {replyTo ? (
          <div className="mx-replychip">
            <span>
              <strong>Replying to {replyTo.author?.userId === self.userId ? 'yourself' : replyTo.author?.displayName}</strong>
              <span>{snippet(replyTo.body)}</span>
            </span>
            <button type="button" className="mx-iconbtn" onClick={() => setReplyTo(null)} aria-label="Cancel reply">×</button>
          </div>
        ) : null}
        <form
          className="mx-composer__row"
          onSubmit={(event) => {
            event.preventDefault();
            submit();
          }}
        >
          <AutoTextarea
            inputRef={composerRef}
            label={`Message ${title}`}
            placeholder={throttled ? 'Slow down a little — you can write again in a moment' : `Message ${title}`}
            value={draft}
            disabled={disabled}
            onChange={(event) => {
              setDraft(event.target.value);
              setTyping(event.target.value.length > 0);
            }}
            onKeyDown={onComposerKey}
          />
          <button type="submit" className="mx-send" disabled={!draft.trim() || disabled} aria-label="Send">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12l16-8-6 16-2.5-6.5L4 12z" /></svg>
          </button>
        </form>
        <p className="mx-composer__hint">Enter to send · Shift+Enter for a new line · ↑ to edit your last message</p>
      </div>

      {confirmDelete ? (
        <ConfirmDialog
          title="Delete this message?"
          body={`It is removed for everyone in this chat and shows as “This message was deleted”. ${snippet(confirmDelete.body, 60) ? `“${snippet(confirmDelete.body, 60)}”` : ''}`}
          confirmLabel="Delete for everyone"
          danger
          onConfirm={() => remove(confirmDelete.messageId)}
          onClose={() => setConfirmDelete(null)}
        />
      ) : null}
    </div>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/MessengerThread.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/ContactPanel.jsx <<'__MSG_EOF__'
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { isMutedNow } from '@classroom/core-client';
import { formatDate, formatTime } from '../../lib/preferences.js';
import Avatar from './Avatar.jsx';
import { ProfileSummary, useProfile } from './ProfileCard.jsx';
import { ConfirmDialog, ReportDialog } from './Dialogs.jsx';
import { MUTE_CHOICES, muteState, muteUntil } from './messengerModel.js';

/**
 * Details of a conversation  (Messages)
 *
 * Beside the chat on wide screens, as a sheet on narrow ones:
 *   the person      profile as they allow it to be seen
 *   quick actions   search in the chat, mute, pin
 *   notifications   mute for 1 h / 8 h / 1 day / 1 week / until turned on
 *   in common       the spaces you share (links into Community)
 *   about           since when, how many messages you can see
 *   privacy         block or unblock, report, delete the chat for you
 * For a group: its members, each opening their profile.
 */

function Section({ title, children }) {
  return (
    <section className="mx-panel__section">
      {title ? <h3>{title}</h3> : null}
      {children}
    </section>
  );
}

export default function ContactPanel({ conversation, title, other, self, api, profiles, rooms, onClose, onSearch, onOpenProfile, onDeleted, onBlockedChange }) {
  const [details, setDetails] = useState(null);
  const [profileVersion, setProfileVersion] = useState(0);
  const { profile, error } = useProfile(profiles, other?.userId ?? null, profileVersion);
  const [dialog, setDialog] = useState(null); // 'block' · 'unblock' · 'report' · 'delete'
  const [status, setStatus] = useState(null);
  const [showMute, setShowMute] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    setDetails(null);
    api
      .conversationDetails(conversation.conversationId, controller.signal)
      .then(setDetails)
      .catch(() => !controller.signal.aborted && setDetails({ sharedSpaces: [], messageCount: 0, startedAt: conversation.createdAt, failed: true }));
    return () => controller.abort();
  }, [api, conversation.conversationId, conversation.createdAt]);

  const run = async (fn, done) => {
    setStatus(null);
    try {
      await fn();
      if (done) setStatus({ text: done });
    } catch (cause) {
      setStatus({ error: true, text: cause?.detail ?? cause?.message ?? 'That did not work. Try again.' });
    }
  };

  const mute = muteState(conversation);
  const muted = isMutedNow(conversation);
  const pinned = Boolean(conversation.pinnedAt);
  const blocked = Boolean(profile?.isBlockedByViewer);

  const togglePin = () =>
    run(async () => {
      await api.pinConversation(conversation.conversationId, !pinned);
      await rooms.refresh();
    }, pinned ? 'Unpinned.' : 'Pinned to the top of your chats.');

  return (
    <aside className="mx-panel" aria-label="Chat details">
      <header className="mx-panel__head">
        <strong>{other ? 'Contact info' : 'Group info'}</strong>
        <button type="button" className="mx-iconbtn" onClick={onClose} aria-label="Close details">×</button>
      </header>

      <div className="mx-panel__scroll">
        <Section>
          {other ? (
            <ProfileSummary person={{ userId: other.userId, displayName: other.profile?.displayName ?? title, avatarUrl: other.profile?.avatarUrl }} profile={profile} error={error} large />
          ) : (
            <div className="mx-profile mx-profile--large">
              <Avatar name={title} seed={conversation.conversationId} size={88} />
              <strong className="mx-profile__name">{title}</strong>
              <span className="mx-muted">{conversation.participants.length} members</span>
            </div>
          )}
          <div className="mx-quick">
            <button type="button" onClick={onSearch}>
              <span aria-hidden="true">⌕</span>Search
            </button>
            <button type="button" onClick={() => setShowMute((value) => !value)} aria-expanded={showMute}>
              <span aria-hidden="true">{muted ? '🔕' : '🔔'}</span>
              {muted ? 'Muted' : 'Mute'}
            </button>
            <button type="button" onClick={togglePin} aria-pressed={pinned}>
              <span aria-hidden="true">📌</span>
              {pinned ? 'Unpin' : 'Pin'}
            </button>
          </div>
          {status ? <p className={status.error ? 'mx-error' : 'mx-ok'} role="status">{status.text}</p> : null}
        </Section>

        <Section title="Notifications">
          <p className="mx-muted">
            {mute
              ? mute.forever
                ? 'Muted until you turn notifications back on.'
                : `Muted until ${formatDate(mute.until)}, ${formatTime(mute.until)}.`
              : 'You are notified about new messages.'}
          </p>
          {muted ? (
            <button type="button" className="btn" onClick={() => run(() => rooms.unmute(conversation.conversationId), 'Notifications are on again.')}>
              Turn notifications back on
            </button>
          ) : null}
          {showMute || !muted ? (
            <div className="mx-options" role="group" aria-label="Mute">
              {MUTE_CHOICES.map((choice) => (
                <button
                  key={choice.id}
                  type="button"
                  onClick={() =>
                    run(async () => {
                      await rooms.mute(conversation.conversationId, muteUntil(choice));
                      setShowMute(false);
                    }, 'Muted.')
                  }
                >
                  {`Mute ${choice.label.charAt(0).toLowerCase()}${choice.label.slice(1)}`}
                </button>
              ))}
            </div>
          ) : null}
        </Section>

        {other ? (
          <Section title="In common">
            {details === null ? <p className="mx-muted">Loading…</p> : null}
            {details?.sharedSpaces?.length ? (
              <ul className="mx-spaces">
                {details.sharedSpaces.map((space) => (
                  <li key={space.spaceId}>
                    <Link to={`/community/spaces/${space.spaceId}`}>
                      <span aria-hidden="true">{space.emoji ?? '◎'}</span>
                      {space.name}
                    </Link>
                  </li>
                ))}
              </ul>
            ) : null}
            {details && !details.sharedSpaces?.length ? <p className="mx-muted">No spaces in common.</p> : null}
          </Section>
        ) : (
          <Section title="Members">
            <ul className="mx-members">
              {conversation.participants.map((participant) => (
                <li key={participant.userId}>
                  <button type="button" onClick={() => onOpenProfile({ userId: participant.userId, displayName: participant.profile?.displayName ?? 'Unknown', avatarUrl: participant.profile?.avatarUrl ?? null })}>
                    <Avatar name={participant.profile?.displayName} url={participant.profile?.avatarUrl} seed={participant.userId} size={34} />
                    <span>{participant.userId === self.userId ? 'You' : participant.profile?.displayName}</span>
                  </button>
                </li>
              ))}
            </ul>
          </Section>
        )}

        <Section title="About this chat">
          <dl className="mx-facts">
            <dt>Started</dt>
            <dd>{(details?.startedAt ?? conversation.createdAt) ? formatDate(details?.startedAt ?? conversation.createdAt) : '—'}</dd>
            <dt>Messages</dt>
            <dd>{details ? details.messageCount : '…'}</dd>
            {details?.editWindowMin ? (
              <>
                <dt>Editing</dt>
                <dd>Your messages can be edited for {details.editWindowMin} minutes</dd>
              </>
            ) : null}
          </dl>
        </Section>

        <Section title="Privacy and support">
          <div className="mx-danger-list">
            {other ? (
              blocked ? (
                <button type="button" onClick={() => setDialog('unblock')}>
                  Unblock {title}
                </button>
              ) : (
                <button type="button" className="is-danger" onClick={() => setDialog('block')}>
                  Block {title}
                </button>
              )
            ) : null}
            {other ? (
              <button type="button" className="is-danger" onClick={() => setDialog('report')}>
                Report {title}
              </button>
            ) : null}
            <button type="button" className="is-danger" onClick={() => setDialog('delete')}>
              Delete chat for me
            </button>
          </div>
        </Section>
      </div>

      {dialog === 'block' ? (
        <ConfirmDialog
          title={`Block ${title}?`}
          body={`${title} can no longer send you messages, and you cannot write to them. They are not told. You can unblock them here or in Settings → Privacy.`}
          confirmLabel="Block"
          danger
          onConfirm={async () => {
            await profiles.block({ userId: other.userId });
            setProfileVersion((v) => v + 1);
            onBlockedChange?.(true);
            setStatus({ text: `${title} is blocked.` });
          }}
          onClose={() => setDialog(null)}
        />
      ) : null}
      {dialog === 'unblock' ? (
        <ConfirmDialog
          title={`Unblock ${title}?`}
          body={`You can write to each other again, as their privacy settings allow.`}
          confirmLabel="Unblock"
          onConfirm={async () => {
            await profiles.unblock(other.userId);
            setProfileVersion((v) => v + 1);
            onBlockedChange?.(false);
            setStatus({ text: `${title} is no longer blocked.` });
          }}
          onClose={() => setDialog(null)}
        />
      ) : null}
      {dialog === 'report' ? (
        <ReportDialog person={{ userId: other.userId, displayName: title }} profiles={profiles} onDone={() => setStatus({ text: 'Thank you. The report was sent to the moderators.' })} onClose={() => setDialog(null)} />
      ) : null}
      {dialog === 'delete' ? (
        <ConfirmDialog
          title="Delete this chat for you?"
          body={`It disappears from your list only — ${title} keeps it. If a new message arrives, the chat comes back without the old messages.`}
          confirmLabel="Delete for me"
          danger
          onConfirm={async () => {
            await rooms.remove(conversation.conversationId);
            onDeleted();
          }}
          onClose={() => setDialog(null)}
        />
      ) : null}
    </aside>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/ContactPanel.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/messenger.css <<'__MSG_EOF__'
/* Messages — see pages/MessagesPage.jsx and components/Messenger/.
   Edge to edge below the top bar, in three columns; colours from the app's
   variables (styles/theme.css). */

.app .app__content:has(.mx-page) { max-width: none; padding: 0; }

.mx-page {
  --mx-list: 360px;
  --mx-panel: 360px;
  --mx-line: var(--color-border, #dbe4e1);
  display: grid;
  grid-template-columns: var(--mx-list) minmax(0, 1fr);
  height: calc(100dvh - var(--mx-top, 60px));
  min-height: 420px;
  background: var(--color-surface, #fff);
  border-top: 1px solid var(--mx-line);
  overflow: hidden;
  animation: none;
}
.mx-page.has-panel.is-wide { grid-template-columns: var(--mx-list) minmax(0, 1fr) var(--mx-panel); }
.mx-page.is-narrow { grid-template-columns: minmax(0, 1fr); }
@media (min-width: 1500px) { .mx-page { --mx-list: 400px; --mx-panel: 380px; } }

.mx-muted { color: var(--color-muted, #5d6f73); }
.mx-error { color: var(--color-danger, #c93636); }
.mx-ok { color: var(--color-live, #1e9a77); }
.mx-center { text-align: center; }
.mx-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
.mx-page mark { background: var(--app-sun, #ffd54a); color: var(--app-sun-ink, #2a2206); border-radius: 3px; padding: 0 1px; }

.mx-avatar {
  display: inline-grid; place-items: center; flex: 0 0 auto; border-radius: 50%; overflow: hidden;
  background: hsl(var(--mx-hue, 210) 55% 88%); color: hsl(var(--mx-hue, 210) 45% 28%); font-weight: 700; letter-spacing: 0.02em;
}
.mx-avatar img { width: 100%; height: 100%; object-fit: cover; }

.mx-iconbtn {
  display: inline-grid; place-items: center; width: 38px; height: 38px; border: 0; border-radius: 10px;
  background: transparent; color: var(--color-text, #15272c); font-size: 19px; line-height: 1; cursor: pointer;
}
.mx-iconbtn:hover:not(:disabled), .mx-iconbtn.is-on { background: var(--color-surface-2, #f1f5f4); }
.mx-iconbtn.is-on { color: var(--color-accent, #2f63d6); }
.mx-iconbtn:disabled { opacity: 0.35; cursor: default; }
.mx-textbtn { border: 0; background: none; color: var(--color-muted, #5d6f73); font: inherit; font-size: 13px; font-weight: 700; cursor: pointer; padding: 2px 6px; border-radius: 6px; }
.mx-textbtn.is-primary { color: var(--color-accent, #2f63d6); }
.mx-textbtn:hover { background: var(--color-surface-2, #f1f5f4); }

.mx-badge { display: inline-grid; place-items: center; min-width: 20px; height: 20px; padding: 0 6px; border-radius: 999px; background: var(--color-accent, #2f63d6); color: #fff; font-size: 12px; font-weight: 700; }
.mx-badge.is-muted { background: #9aa8ab; }

/* ---------------------------------------------------------------- columns */
.mx-col { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
.mx-col--list { border-right: 1px solid var(--mx-line); background: var(--color-surface, #fff); }
.mx-col--chat { background: var(--color-surface-2, #f1f5f4); }
.mx-col__head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 16px 16px 10px 20px; }
.mx-col__head h1 { margin: 0; display: flex; align-items: center; gap: 10px; font-size: 24px; }
.mx-newbtn { width: 40px; height: 40px; border: 0; border-radius: 12px; background: var(--color-accent, #2f63d6); color: #fff; font-size: 18px; cursor: pointer; box-shadow: 0 8px 20px -12px rgba(47, 99, 214, 0.9); }
.mx-newbtn:hover { filter: brightness(1.08); }
.mx-col--list .msg-new { margin: 0 12px 10px; }

/* ---------------------------------------------------------------- list */
.mx-list { display: flex; flex-direction: column; min-height: 0; flex: 1; }
.mx-list__search { padding: 0 12px 10px; }
.mx-list__search input { width: 100%; box-sizing: border-box; padding: 10px 14px; border-radius: 999px; border: 1px solid var(--mx-line); background: var(--color-surface-2, #f1f5f4); font: inherit; font-size: 14.5px; }
.mx-list__scroll { flex: 1; min-height: 0; overflow-y: auto; padding: 0 8px 12px; }
.mx-list__scroll ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
.mx-list__group { margin: 10px 12px 6px; font-size: 12px; font-weight: 700; letter-spacing: 0.05em; text-transform: uppercase; color: var(--color-muted, #5d6f73); }
.mx-list__notice { padding: 16px 12px; margin: 0; color: var(--color-muted, #5d6f73); display: grid; gap: 8px; justify-items: start; }
.mx-row {
  display: flex; align-items: center; gap: 12px; width: 100%; padding: 10px 12px; border: 0; border-radius: 14px;
  background: transparent; color: inherit; font: inherit; text-align: left; cursor: pointer; transition: background-color 0.15s ease;
}
.mx-row:hover { background: var(--color-surface-2, #f1f5f4); }
.mx-row.is-active { background: rgba(47, 99, 214, 0.1); }
.mx-row__main { flex: 1; min-width: 0; display: grid; gap: 3px; }
.mx-row__top, .mx-row__bottom { display: flex; align-items: center; gap: 8px; min-width: 0; }
.mx-row__name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 700; font-size: 15px; }
.mx-row__time { flex: 0 0 auto; font-size: 12.5px; color: var(--color-muted, #5d6f73); }
.mx-row__preview { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; color: var(--color-muted, #5d6f73); }
.mx-row__you { color: var(--color-muted, #5d6f73); }
.mx-row__marks { display: inline-flex; align-items: center; gap: 4px; flex: 0 0 auto; }
.mx-row__icon { font-size: 12px; opacity: 0.75; }
.mx-row.is-unread .mx-row__preview { color: var(--color-text, #15272c); font-weight: 700; }
.mx-row.is-unread .mx-row__time { color: var(--color-accent, #2f63d6); font-weight: 700; }

/* ---------------------------------------------------------------- chat header */
.mx-chathead { display: flex; align-items: center; gap: 8px; padding: 10px 14px; background: var(--color-surface, #fff); border-bottom: 1px solid var(--mx-line); min-height: 64px; box-sizing: border-box; }
.mx-chathead__who { display: flex; align-items: center; gap: 12px; flex: 1; min-width: 0; padding: 4px 8px; border: 0; border-radius: 12px; background: transparent; color: inherit; font: inherit; text-align: left; cursor: pointer; }
.mx-chathead__who:hover { background: var(--color-surface-2, #f1f5f4); }
.mx-chathead__who > span:last-child { display: grid; min-width: 0; }
.mx-chathead__who strong { font-size: 16px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mx-chathead__who .mx-muted { font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mx-chathead__actions { display: inline-flex; gap: 2px; }

/* ---------------------------------------------------------------- thread */
.mx-thread { position: relative; display: flex; flex-direction: column; flex: 1; min-height: 0; }
.mx-findbar { display: flex; align-items: center; gap: 6px; padding: 8px 14px; background: var(--color-surface, #fff); border-bottom: 1px solid var(--mx-line); }
.mx-findbar input { flex: 1; min-width: 0; padding: 8px 12px; border-radius: 10px; border: 1px solid var(--mx-line); font: inherit; font-size: 14.5px; }
.mx-findbar__count { min-width: 74px; text-align: right; font-size: 13px; color: var(--color-muted, #5d6f73); }
.mx-messages { flex: 1; min-height: 0; overflow-y: auto; overscroll-behavior: contain; }
.mx-messages__inner { display: flex; flex-direction: column; gap: 2px; max-width: 920px; margin: 0 auto; padding: 18px 24px 12px; }
.mx-loadmore { align-self: center; margin-bottom: 10px; padding: 6px 14px; border-radius: 999px; border: 1px solid var(--mx-line); background: var(--color-surface, #fff); font: inherit; font-size: 13.5px; cursor: pointer; }
.mx-start { display: grid; justify-items: center; gap: 4px; padding: 24px 0 18px; text-align: center; }
.mx-start p { margin: 0; }
.mx-start__title { font-weight: 700; font-size: 18px; margin-top: 6px !important; }
.mx-day { display: flex; justify-content: center; margin: 14px 0 8px; position: sticky; top: 6px; z-index: 1; }
.mx-day span { padding: 4px 12px; border-radius: 999px; background: rgba(255, 255, 255, 0.92); border: 1px solid var(--mx-line); font-size: 12.5px; font-weight: 700; color: var(--color-muted, #5d6f73); box-shadow: 0 2px 6px -4px rgba(20, 38, 43, 0.3); }

.mx-msg { display: flex; gap: 8px; align-items: flex-end; }
.mx-msg.is-first { margin-top: 10px; }
.mx-msg.is-mine { justify-content: flex-end; }
.mx-msg__gutter { width: 32px; flex: 0 0 32px; }
.mx-msg__avatar { padding: 0; border: 0; background: none; cursor: pointer; border-radius: 50%; }
.mx-msg__col { display: flex; flex-direction: column; min-width: 0; max-width: min(72%, 640px); }
.mx-msg.is-mine .mx-msg__col { align-items: flex-end; }
.mx-msg__author { align-self: flex-start; margin: 0 0 3px 12px; padding: 0; border: 0; background: none; font: inherit; font-size: 13px; font-weight: 700; color: hsl(210 45% 35%); cursor: pointer; }
.mx-msg__author:hover { text-decoration: underline; }
.mx-msg__line { display: flex; align-items: center; gap: 6px; max-width: 100%; }
.mx-msg.is-mine .mx-msg__line { flex-direction: row-reverse; }

.mx-bubble {
  position: relative; display: grid; gap: 4px; min-width: 64px; max-width: 100%; padding: 8px 12px 6px; border-radius: 18px;
  background: var(--color-surface, #fff); color: var(--color-text, #15272c); box-shadow: 0 1px 1px rgba(20, 38, 43, 0.08);
  overflow-wrap: anywhere; transition: box-shadow 0.3s ease;
}
.mx-msg.is-theirs:not(.is-last) .mx-bubble { border-bottom-left-radius: 6px; }
.mx-msg.is-theirs:not(.is-first) .mx-bubble { border-top-left-radius: 6px; }
.mx-msg.is-mine .mx-bubble { background: var(--color-accent, #2f63d6); color: #fff; }
.mx-msg.is-mine:not(.is-last) .mx-bubble { border-bottom-right-radius: 6px; }
.mx-msg.is-mine:not(.is-first) .mx-bubble { border-top-right-radius: 6px; }
.mx-msg.is-sending .mx-bubble { opacity: 0.7; }
.mx-msg.is-failed .mx-bubble { background: #fde3e3; color: var(--color-text, #15272c); }
.mx-msg.is-hit .mx-bubble, .mx-msg.is-flash .mx-bubble { box-shadow: 0 0 0 3px var(--app-sun, #ffd54a); }
.mx-bubble__text { white-space: pre-wrap; font-size: 15px; line-height: 1.45; }
.mx-bubble__meta { justify-self: end; font-size: 11.5px; opacity: 0.7; white-space: nowrap; }
.mx-deleted { opacity: 0.7; font-size: 14px; }
.mx-quote { display: grid; gap: 1px; padding: 6px 10px; border: 0; border-left: 3px solid currentColor; border-radius: 8px; background: rgba(20, 38, 43, 0.06); color: inherit; font: inherit; font-size: 13px; text-align: left; cursor: pointer; }
.mx-msg.is-mine .mx-quote { background: rgba(255, 255, 255, 0.18); }
.mx-quote span { opacity: 0.85; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mx-retry { align-self: flex-end; margin-top: 2px; border: 0; background: none; color: var(--color-danger, #c93636); font: inherit; font-size: 12.5px; cursor: pointer; }
.mx-typing { margin: 8px 0 0 40px; font-size: 13px; font-style: italic; color: var(--color-muted, #5d6f73); }

.mx-actions { display: inline-flex; gap: 2px; padding: 2px; border-radius: 10px; background: var(--color-surface, #fff); border: 1px solid var(--mx-line); box-shadow: 0 4px 12px -8px rgba(20, 38, 43, 0.4); opacity: 0; transition: opacity 0.15s ease; }
.mx-actions button { width: 30px; height: 30px; border: 0; border-radius: 8px; background: none; color: var(--color-text, #15272c); font-size: 14px; cursor: pointer; }
.mx-actions button:hover { background: var(--color-surface-2, #f1f5f4); }
.mx-actions button.is-danger:hover { background: #fdecec; }
.mx-msg:hover .mx-actions, .mx-msg:focus-within .mx-actions { opacity: 1; }
@media (hover: none) { .mx-actions { opacity: 0.9; } }

.mx-edit { display: grid; gap: 4px; min-width: min(420px, 60vw); }
.mx-edit textarea { width: 100%; box-sizing: border-box; resize: none; border: 0; border-radius: 10px; padding: 6px 8px; font: inherit; font-size: 15px; line-height: 1.45; background: #fff; color: var(--color-text, #15272c); }
.mx-edit__hint { display: flex; justify-content: space-between; align-items: center; gap: 8px; font-size: 12px; opacity: 0.85; }
.mx-msg.is-mine .mx-edit .mx-textbtn { color: #fff; }
.mx-msg.is-mine .mx-edit .mx-textbtn:hover { background: rgba(255, 255, 255, 0.18); }
.mx-msg.is-mine .mx-edit .mx-error { color: #ffe0e0; }

.mx-toast { position: absolute; left: 50%; bottom: 96px; transform: translateX(-50%); z-index: 5; margin: 0; padding: 8px 14px; border-radius: 10px; background: var(--color-text, #15272c); color: #fff; font-size: 13.5px; }

/* ---------------------------------------------------------------- composer */
.mx-composer { padding: 10px 24px 12px; background: var(--color-surface, #fff); border-top: 1px solid var(--mx-line); }
.mx-composer > * { max-width: 920px; margin-left: auto; margin-right: auto; }
.mx-composer__row { display: flex; align-items: flex-end; gap: 10px; }
.mx-composer textarea {
  flex: 1; min-width: 0; box-sizing: border-box; resize: none; max-height: 180px; padding: 11px 16px; border-radius: 22px;
  border: 1px solid var(--mx-line); background: var(--color-surface-2, #f1f5f4); font: inherit; font-size: 15px; line-height: 1.4;
}
.mx-composer textarea:focus { background: #fff; }
.mx-send { display: grid; place-items: center; width: 44px; height: 44px; flex: 0 0 auto; border: 0; border-radius: 50%; background: var(--color-accent, #2f63d6); cursor: pointer; transition: transform 0.2s ease, opacity 0.2s ease; }
.mx-send svg { width: 20px; height: 20px; fill: #fff; }
.mx-send:disabled { opacity: 0.35; cursor: default; }
.mx-send:not(:disabled):hover { transform: scale(1.05); }
.mx-composer__hint { margin: 6px auto 0; font-size: 12px; color: var(--color-muted, #5d6f73); }
.mx-composer__notice { margin: 0 auto 8px; padding: 8px 12px; border-radius: 10px; background: #fff3c4; color: #6b4c00; font-size: 14px; }
.mx-replychip { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; padding: 6px 6px 6px 12px; border-left: 3px solid var(--color-accent, #2f63d6); border-radius: 10px; background: var(--color-surface-2, #f1f5f4); }
.mx-replychip > span { display: grid; flex: 1; min-width: 0; font-size: 13px; }
.mx-replychip > span span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--color-muted, #5d6f73); }

/* ---------------------------------------------------------------- empty states */
.mx-empty { flex: 1; display: grid; place-content: center; justify-items: center; gap: 8px; padding: 24px; text-align: center; }
.mx-empty p { margin: 0; }
.mx-empty__icon { font-size: 44px; }
.mx-empty__title { font-weight: 700; font-size: 18px; }

/* ---------------------------------------------------------------- details panel */
.mx-panel { display: flex; flex-direction: column; min-height: 0; background: var(--color-surface, #fff); border-left: 1px solid var(--mx-line); }
.mx-panel__head { display: flex; align-items: center; justify-content: space-between; padding: 12px 14px 12px 20px; min-height: 64px; box-sizing: border-box; border-bottom: 1px solid var(--mx-line); }
.mx-panel__scroll { flex: 1; min-height: 0; overflow-y: auto; }
.mx-panel__section { display: grid; gap: 10px; padding: 18px 20px; border-bottom: 1px solid var(--mx-line); }
.mx-panel__section:last-child { border-bottom: 0; }
.mx-panel__section h3 { margin: 0; font-size: 13px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--color-muted, #5d6f73); }
.mx-panel__section p { margin: 0; }
.mx-scrim { display: none; }

.mx-profile { display: grid; justify-items: center; gap: 6px; text-align: center; }
.mx-profile__names { display: grid; gap: 2px; }
.mx-profile__name { font-size: 18px; }
.mx-profile--large .mx-profile__name { font-size: 20px; }
.mx-profile__headline { margin: 4px 0 0; font-weight: 700; }
.mx-profile__bio { margin: 0; white-space: pre-wrap; color: var(--color-muted, #5d6f73); text-align: left; justify-self: stretch; }
.mx-profile__links { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 6px 12px; justify-content: center; }
.mx-profile__links a { color: var(--color-accent, #2f63d6); }

.mx-quick { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 6px; }
.mx-quick button { display: grid; justify-items: center; gap: 4px; padding: 10px 6px; border: 1px solid var(--mx-line); border-radius: 12px; background: var(--color-surface, #fff); color: var(--color-text, #15272c); font: inherit; font-size: 13px; cursor: pointer; }
.mx-quick button span { font-size: 18px; color: var(--color-accent, #2f63d6); }
.mx-quick button:hover, .mx-quick button[aria-pressed='true'], .mx-quick button[aria-expanded='true'] { background: rgba(47, 99, 214, 0.08); border-color: rgba(47, 99, 214, 0.35); }
.mx-options { display: grid; gap: 4px; }
.mx-options button { padding: 8px 12px; border: 1px solid var(--mx-line); border-radius: 10px; background: var(--color-surface, #fff); font: inherit; font-size: 14px; text-align: left; cursor: pointer; }
.mx-options button:hover { background: var(--color-surface-2, #f1f5f4); }
.mx-spaces, .mx-members { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; }
.mx-spaces a { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border-radius: 10px; color: var(--color-text, #15272c); text-decoration: none; font-weight: 700; }
.mx-spaces a:hover { background: var(--color-surface-2, #f1f5f4); }
.mx-members button { display: flex; align-items: center; gap: 10px; width: 100%; padding: 6px 8px; border: 0; border-radius: 10px; background: none; font: inherit; text-align: left; cursor: pointer; }
.mx-members button:hover { background: var(--color-surface-2, #f1f5f4); }
.mx-facts { display: grid; grid-template-columns: auto 1fr; gap: 6px 14px; margin: 0; font-size: 14px; }
.mx-facts dt { color: var(--color-muted, #5d6f73); }
.mx-facts dd { margin: 0; }
.mx-danger-list { display: grid; gap: 2px; }
.mx-danger-list button { padding: 10px 8px; border: 0; border-radius: 10px; background: none; color: var(--color-text, #15272c); font: inherit; font-size: 14.5px; text-align: left; cursor: pointer; }
.mx-danger-list button.is-danger { color: var(--color-danger, #c93636); }
.mx-danger-list button:hover { background: var(--color-surface-2, #f1f5f4); }

.mx-dialog { width: min(460px, 94vw); }
.mx-radios { display: grid; gap: 4px; border: 0; margin: 0; padding: 0; }
.mx-radios label { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border: 1px solid var(--mx-line, #dbe4e1); border-radius: 10px; cursor: pointer; font-size: 14.5px; }
.mx-radios label.is-on { border-color: var(--color-accent, #2f63d6); background: rgba(47, 99, 214, 0.06); }
.mx-dialog textarea { padding: 10px 12px; border-radius: 12px; border: 1px solid var(--color-border, #dbe4e1); font: inherit; font-weight: 400; resize: vertical; }

/* ---------------------------------------------------------------- narrower screens */
@media (max-width: 1240px) {
  .mx-page.has-panel.is-wide { grid-template-columns: var(--mx-list) minmax(0, 1fr); }
  .mx-page.has-panel .mx-scrim { display: block; position: fixed; inset: 0; z-index: 64; border: 0; background: rgba(20, 38, 43, 0.3); cursor: pointer; }
  .mx-page.has-panel .mx-panel { position: fixed; z-index: 65; top: 0; right: 0; bottom: 0; width: min(400px, 92vw); box-shadow: -24px 0 60px -30px rgba(20, 38, 43, 0.6); animation: mx-slide 0.3s cubic-bezier(0.16, 1, 0.3, 1) both; }
}
@keyframes mx-slide { from { transform: translateX(24px); opacity: 0; } to { transform: none; opacity: 1; } }
@media (max-width: 1100px) { .mx-page { --mx-list: 320px; } .mx-messages__inner, .mx-composer { padding-left: 14px; padding-right: 14px; } }
@media (max-width: 899px) {
  .mx-msg__col { max-width: 84%; }
  .mx-composer__hint { display: none; }
  .mx-col__head { padding-left: 16px; }
}
@media (prefers-reduced-motion: reduce) {
  .mx-panel { animation: none !important; }
  .mx-row, .mx-actions, .mx-send, .mx-bubble { transition: none; }
}
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/messenger.css"
mkdir -p apps/web/src/components/Messenger/__checks__
cat > apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs <<'__MSG_EOF__'
// node --test apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  initials, hueOf, sortConversations, matches, highlightParts, dayLabel, threadRows, canEdit, canDelete,
  lastEditable, searchHits, muteState, muteUntil, MUTE_CHOICES, snippet,
} from '../messengerModel.js';

test('initials and stable colours', () => {
  assert.equal(initials('Mara Klein'), 'MK');
  assert.equal(initials('  anna '), 'A');
  assert.equal(initials('Jean Paul van Dyke'), 'JD');
  assert.equal(initials(''), '?');
  assert.equal(hueOf('u1'), hueOf('u1'));
  assert.ok(hueOf('u1') >= 0 && hueOf('u1') < 360);
});

test('pinned first, newest pin on top, then by activity', () => {
  const list = [
    { conversationId: 'a', lastMessageAt: '2026-10-02T10:00:00Z' },
    { conversationId: 'b', lastMessageAt: '2026-09-01T10:00:00Z', pinnedAt: '2026-09-10T00:00:00Z' },
    { conversationId: 'c', lastMessageAt: '2026-10-02T11:00:00Z' },
    { conversationId: 'd', createdAt: '2026-08-01T00:00:00Z', pinnedAt: '2026-09-20T00:00:00Z' },
  ];
  assert.deepEqual(sortConversations(list).map((c) => c.conversationId), ['d', 'b', 'c', 'a']);
});

test('search ignores case and accents; highlights every hit', () => {
  assert.equal(matches('Café crème', 'CAFE'), true);
  assert.equal(matches('Hello', 'bye'), false);
  assert.equal(matches('anything', '  '), true);
  assert.deepEqual(highlightParts('the cat and the CAT', 'cat'), [
    { text: 'the ', hit: false }, { text: 'cat', hit: true }, { text: ' and the ', hit: false }, { text: 'CAT', hit: true },
  ]);
  assert.deepEqual(highlightParts('plain', ''), [{ text: 'plain', hit: false }]);
});

test('day labels', () => {
  const now = new Date(2026, 9, 15, 12);
  assert.equal(dayLabel(new Date(2026, 9, 15, 8).toISOString(), now), 'Today');
  assert.equal(dayLabel(new Date(2026, 9, 14, 23).toISOString(), now), 'Yesterday');
  assert.equal(dayLabel(new Date(2026, 9, 12, 9).toISOString(), now), 'Monday');
  assert.equal(dayLabel(new Date(2026, 8, 1).toISOString(), now, () => 'old'), 'old');
});

test('thread rows: day separators and groups by author within five minutes', () => {
  const m = (id, author, at) => ({ messageId: id, author: { userId: author }, createdAt: at });
  const rows = threadRows([
    m('1', 'a', '2026-10-01T10:00:00'), m('2', 'a', '2026-10-01T10:02:00'), m('3', 'b', '2026-10-01T10:03:00'),
    m('4', 'b', '2026-10-01T10:20:00'), m('5', 'b', '2026-10-02T09:00:00'),
  ]);
  assert.deepEqual(rows.map((r) => (r.type === 'day' ? 'D' : `${r.message.messageId}${r.firstInGroup ? 'F' : ''}${r.lastInGroup ? 'L' : ''}`)),
    ['D', '1F', '2L', '3FL', '4FL', 'D', '5FL']);
});

test('edit and delete follow the server rule', () => {
  const now = Date.parse('2026-10-02T12:00:00Z');
  const mine = { author: { userId: 'me' }, delivery: 'sent', createdAt: '2026-10-02T11:55:00Z' };
  const o = { selfUserId: 'me', windowMin: 15, now };
  assert.equal(canEdit(mine, o), true);
  assert.equal(canEdit({ ...mine, createdAt: '2026-10-02T11:40:00Z' }, o), false);
  assert.equal(canEdit({ ...mine, delivery: 'sending' }, o), false);
  assert.equal(canEdit({ ...mine, deletedAt: 'x' }, o), false);
  assert.equal(canEdit({ ...mine, author: { userId: 'other' } }, o), false);
  assert.equal(canEdit({ ...mine, createdAt: '2020-01-01T00:00:00Z' }, { ...o, windowMin: 0 }), true);
  assert.equal(canDelete(mine, o), true);
  assert.equal(canDelete({ ...mine, author: { userId: 'x' } }, o), false);
  const list = [{ ...mine, messageId: '1' }, { ...mine, messageId: '2', author: { userId: 'x' } }, { ...mine, messageId: '3', delivery: 'failed' }];
  assert.equal(lastEditable(list, o).messageId, '1');
  assert.equal(lastEditable([], o), null);
});

test('search hits skip deleted messages', () => {
  const list = [{ messageId: '1', body: 'Homework due' }, { messageId: '2', body: 'homework?', deletedAt: 'x' }, { messageId: '3', body: 'HOMEWORK done' }];
  assert.deepEqual(searchHits(list, 'homework'), ['1', '3']);
  assert.deepEqual(searchHits(list, ''), []);
});

test('mutes and snippets', () => {
  const now = Date.parse('2026-10-02T12:00:00Z');
  assert.equal(muteState({ muted: false }, now), null);
  assert.deepEqual(muteState({ muted: true }, now), { forever: true });
  assert.deepEqual(muteState({ muted: true, mutedUntil: '2026-10-02T13:00:00Z' }, now), { until: '2026-10-02T13:00:00Z' });
  assert.equal(muteState({ muted: true, mutedUntil: '2026-10-02T11:00:00Z' }, now), null);
  assert.equal(muteUntil(MUTE_CHOICES[0], now), '2026-10-02T13:00:00.000Z');
  assert.equal(muteUntil(MUTE_CHOICES.at(-1), now), null);
  assert.equal(snippet('a   b\nc'), 'a b c');
  assert.equal(snippet('x'.repeat(100), 10), `${'x'.repeat(9)}…`);
});
__MSG_EOF__
echo "wrote apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs"
mkdir -p apps/web/src/pages
cat > apps/web/src/pages/MessagesPage.jsx <<'__MSG_EOF__'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createChatApi, createProfileApi, isMutedNow, otherParticipant, titleOf, useConversations, useCore } from '@classroom/core-client';
import Avatar from '../components/Messenger/Avatar.jsx';
import MessengerList from '../components/Messenger/MessengerList.jsx';
import MessengerThread from '../components/Messenger/MessengerThread.jsx';
import ContactPanel from '../components/Messenger/ContactPanel.jsx';
import { ProfileDialog, useProfile } from '../components/Messenger/ProfileCard.jsx';
import '../components/Chat/messages.css';
import '../components/Messenger/messenger.css';

/**
 * Messages  (F6 · Messages)
 *
 * A messenger across the whole width of the window, in three columns:
 *
 *   chats      pinned first, then by activity; search; unread and muted marks
 *   the chat   messages grouped by day and person, with reply, edit, copy
 *              and delete; search inside the chat
 *   details    the person (or the group), notifications, pin, what you have
 *              in common, block, report, delete for me — opened with ⓘ
 *
 * Narrow screens show one column at a time. Your conversations only: the
 * everyone-chat ("General") belongs to live rooms. The lesson's own chat
 * (components/Chat/ChatRooms.jsx) is not touched by this page.
 */

const WIDE = '(min-width: 900px)';

function useWide() {
  const [wide, setWide] = useState(() => typeof window !== 'undefined' && window.matchMedia?.(WIDE).matches);
  useEffect(() => {
    const query = window.matchMedia?.(WIDE);
    if (!query) return undefined;
    const onChange = () => setWide(query.matches);
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }, []);
  return Boolean(wide);
}

function NewMessage({ onOpen, onClose }) {
  const { http } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const [q, setQ] = useState('');
  const [results, setResults] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const inputRef = useRef(null);

  useEffect(() => {
    inputRef.current?.focus();
    const onKey = (event) => event.key === 'Escape' && onClose();
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);

  useEffect(() => {
    if (q.trim().length < 2) {
      setResults([]);
      return undefined;
    }
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      try {
        const { items } = await profiles.search({ q: q.trim(), limit: 8 }, controller.signal);
        setResults(items);
      } catch {
        if (!controller.signal.aborted) setResults([]);
      }
    }, 200);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [q, profiles]);

  const open = async (person) => {
    setBusy(true);
    setError(null);
    try {
      await onOpen(person);
    } catch (cause) {
      setError(cause?.detail ?? `You cannot write to ${person.displayName} right now.`);
      setBusy(false);
    }
  };

  return (
    <div className="msg-new" role="dialog" aria-label="New message">
      <div className="msg-new__head">
        <p className="msg-new__title">New message</p>
        <button type="button" className="msg-iconbtn" aria-label="Close" onClick={onClose}>
          ×
        </button>
      </div>
      <input
        ref={inputRef}
        className="msg-new__search"
        type="search"
        placeholder="Search for a person by name"
        value={q}
        onChange={(event) => setQ(event.target.value)}
        aria-label="Search for a person"
      />
      {q.trim().length >= 2 && results.length === 0 ? <p className="msg-new__hint">Nobody found.</p> : null}
      {q.trim().length < 2 ? <p className="msg-new__hint">Type at least two letters.</p> : null}
      <ul className="msg-new__results">
        {results.map((person) => (
          <li key={person.userId}>
            <button type="button" disabled={busy} onClick={() => open(person)}>
              <span className="msg-new__avatar" aria-hidden="true">
                {person.avatarUrl ? <img src={person.avatarUrl} alt="" /> : person.displayName.charAt(0).toUpperCase()}
              </span>
              <span>{person.displayName}</span>
            </button>
          </li>
        ))}
      </ul>
      {error ? <p className="msg-new__error" role="alert">{error}</p> : null}
    </div>
  );
}

export default function MessagesPage() {
  const { http, chatSocket, session } = useCore();
  const { conversationId } = useParams();
  const navigate = useNavigate();
  const wide = useWide();
  const pageRef = useRef(null);

  const api = useMemo(() => createChatApi(http), [http]);
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const self = useMemo(
    () => ({ userId: session?.userId ?? '', displayName: session?.displayName ?? 'You', avatarUrl: session?.avatarUrl ?? null }),
    [session],
  );

  const rooms = useConversations({ api, socket: chatSocket ?? undefined, selfUserId: self.userId, enabled: Boolean(self.userId) });

  const [composing, setComposing] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [profileOf, setProfileOf] = useState(null);
  const [editWindowMin, setEditWindowMin] = useState(0);
  const [blockVersion, setBlockVersion] = useState(0);

  // The open chat counts as read and gets no notifications (useConversations).
  const { setOpen } = rooms;
  useEffect(() => {
    setOpen(conversationId ?? null);
    return () => setOpen(null);
  }, [conversationId, setOpen]);

  // A different chat: close search, keep the details panel as it was.
  useEffect(() => {
    setSearch('');
    setSearchOpen(false);
  }, [conversationId]);

  // Fill the window below the top bar exactly, whatever is above us.
  useLayoutEffect(() => {
    const fit = () => {
      const el = pageRef.current;
      if (el) el.style.setProperty('--mx-top', `${Math.max(0, Math.round(el.getBoundingClientRect().top + window.scrollY))}px`);
    };
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  const conversation = conversationId ? rooms.conversations.find((c) => c.conversationId === conversationId) ?? null : null;
  const title = conversation ? titleOf(conversation, self.userId) : '';
  const other = conversation?.kind === 'direct' ? otherParticipant(conversation, self.userId) : null;
  const { profile: otherProfile } = useProfile(profiles, other?.userId ?? null, blockVersion);

  // The edit window comes with the details (server: CHAT_EDIT_WINDOW_MIN).
  useEffect(() => {
    if (!conversationId) return undefined;
    const controller = new AbortController();
    api
      .conversationDetails(conversationId, controller.signal)
      .then((details) => setEditWindowMin(details.editWindowMin))
      .catch(() => undefined);
    return () => controller.abort();
  }, [api, conversationId]);

  const open = useCallback((id) => navigate(`/messages/${id}`), [navigate]);
  const back = () => navigate('/messages');

  const openWith = async (person) => {
    const created = await api.openDirect(person.userId);
    await rooms.refresh?.();
    setComposing(false);
    open(created.conversationId);
  };

  const unread = rooms.conversations.reduce((sum, item) => sum + (isMutedNow(item) ? 0 : item.unreadCount || 0), 0);
  const blockedReason = otherProfile?.isBlockedByViewer
    ? `You blocked ${title}. Unblock them in the chat details to write again.`
    : otherProfile && !otherProfile.canMessage && otherProfile.cannotMessageReason
      ? otherProfile.cannotMessageReason
      : '';

  const showList = wide || !conversationId;
  const showChat = wide || Boolean(conversationId);
  const showPanel = Boolean(conversation && detailsOpen);

  return (
    <section ref={pageRef} className={`mx-page${showPanel ? ' has-panel' : ''}${wide ? ' is-wide' : ' is-narrow'}`}>
      {showList ? (
        <div className="mx-col mx-col--list">
          <header className="mx-col__head">
            <h1>
              Messages {unread > 0 ? <span className="mx-badge">{unread > 99 ? '99+' : unread}</span> : null}
            </h1>
            <button type="button" className="mx-newbtn" onClick={() => setComposing((value) => !value)} aria-expanded={composing} title="New message">
              <span aria-hidden="true">✎</span>
              <span className="mx-sr">New message</span>
            </button>
          </header>
          {composing ? <NewMessage onOpen={openWith} onClose={() => setComposing(false)} /> : null}
          <MessengerList rooms={rooms} self={self} activeId={conversationId ?? null} onOpen={open} />
        </div>
      ) : null}

      {showChat ? (
        <div className="mx-col mx-col--chat">
          {conversation ? (
            <>
              <header className="mx-chathead">
                {!wide ? (
                  <button type="button" className="mx-iconbtn" onClick={back} aria-label="Back to chats">
                    ←
                  </button>
                ) : null}
                <button type="button" className="mx-chathead__who" onClick={() => setDetailsOpen(true)} title={other ? 'Contact info' : 'Group info'}>
                  <Avatar name={title} url={otherProfile?.avatarUrl ?? other?.profile?.avatarUrl ?? null} seed={other?.userId ?? conversation.conversationId} size={40} />
                  <span>
                    <strong>{title}</strong>
                    <span className="mx-muted">
                      {[
                        other ? otherProfile?.headline ?? null : `${conversation.participants.length} members`,
                        isMutedNow(conversation) ? 'Muted' : null,
                        conversation.pinnedAt ? 'Pinned' : null,
                      ]
                        .filter(Boolean)
                        .join(' · ') || 'Click for contact info'}
                    </span>
                  </span>
                </button>
                <span className="mx-chathead__actions">
                  <button type="button" className={`mx-iconbtn${searchOpen ? ' is-on' : ''}`} onClick={() => setSearchOpen((value) => !value)} aria-label="Search in this chat" title="Search in this chat">
                    ⌕
                  </button>
                  <button type="button" className={`mx-iconbtn${detailsOpen ? ' is-on' : ''}`} onClick={() => setDetailsOpen((value) => !value)} aria-label="Chat details" aria-expanded={detailsOpen} title="Chat details">
                    ⓘ
                  </button>
                </span>
              </header>
              <MessengerThread
                key={conversation.conversationId}
                api={api}
                socket={chatSocket}
                self={self}
                conversation={conversation}
                title={title}
                other={other}
                editWindowMin={editWindowMin}
                search={searchOpen ? search : ''}
                searchOpen={searchOpen}
                onSearchChange={setSearch}
                onCloseSearch={() => {
                  setSearch('');
                  setSearchOpen(false);
                }}
                onOpenProfile={(person) => setProfileOf(person)}
                disabledReason={blockedReason}
              />
            </>
          ) : conversationId && !rooms.loading ? (
            <div className="mx-empty">
              <p className="mx-empty__title">This chat is no longer in your list</p>
              <button type="button" className="btn" onClick={back}>
                Back to your chats
              </button>
            </div>
          ) : (
            <div className="mx-empty">
              <span className="mx-empty__icon" aria-hidden="true">💬</span>
              <p className="mx-empty__title">Your messages</p>
              <p className="mx-muted">Choose a conversation, or start a new one.</p>
              <button type="button" className="btn btn--primary" onClick={() => setComposing(true)}>
                New message
              </button>
            </div>
          )}
        </div>
      ) : null}

      {showPanel ? (
        <>
          <button type="button" className="mx-scrim" aria-label="Close details" onClick={() => setDetailsOpen(false)} />
          <ContactPanel
            conversation={conversation}
            title={title}
            other={other}
            self={self}
            api={api}
            profiles={profiles}
            rooms={rooms}
            onClose={() => setDetailsOpen(false)}
            onSearch={() => {
              setSearchOpen(true);
              if (!wide) setDetailsOpen(false);
            }}
            onOpenProfile={(person) => setProfileOf(person)}
            onBlockedChange={() => setBlockVersion((v) => v + 1)}
            onDeleted={() => {
              setDetailsOpen(false);
              back();
            }}
          />
        </>
      ) : null}

      {profileOf ? (
        <ProfileDialog
          person={profileOf}
          profiles={profiles}
          selfUserId={self.userId}
          onMessage={profileOf.userId === other?.userId ? null : openWith}
          onClose={() => setProfileOf(null)}
        />
      ) : null}
    </section>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/pages/MessagesPage.jsx"

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
[ "$FAILED" -eq 0 ] || restore_and_exit "A file did not pass its check (see above)."

echo "--- rule tests (node --test)"
CHECKS=$(find server/test apps/web/src -name '*.check.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
if node --test $CHECKS > .messages-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .messages-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .messages-test.log
else
  cat .messages-test.log
  rm -f .messages-test.log
  restore_and_exit "The rule tests failed (see above)."
fi

echo "--- database (migration 031)"
if SERVICE_ROLE=api npm run db:migrate >/tmp/messages-migrate.log 2>&1; then
  echo "ok  migration 031 applied"
else
  tail -5 /tmp/messages-migrate.log
  echo
  echo "The files are installed, but the database did not answer, so 031 is not applied yet."
  echo "Once your services run (./dev-up.sh), apply it with:  SERVICE_ROLE=api npm run db:migrate"
  echo "Until then, the chats list and pinning answer with an error."
  exit 1
fi

echo
echo "Messages is installed. Nothing was started; the API and Vite reload on their own."
echo "Reload the browser with Ctrl+Shift+R and open Messages."