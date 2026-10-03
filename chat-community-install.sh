#!/usr/bin/env bash
# chat-community-install.sh — fixes Messages' look and rebuilds the Community chat.
#
#   Messages    the previous installer replaced messenger.css with only its
#               last part, so the page lost its whole design; the full
#               stylesheet is back
#   Community   the whole width (no empty margins); the chat fills the window
#               with a panel for Members (count, who, roles, profiles) and
#               Shared (media · files · voice)
#   space chat  the same building blocks as Messages: reactions, files and
#               pictures, voice messages, reply, edit, search; no calls (rooms
#               are for that). Delete: your own messages for everyone; owners
#               and moderators remove others' ("Removed by a moderator",
#               logged); members never delete others'. Edits, deletions and
#               reactions reach every open chat. Calm mode and the late-night
#               nudge stay.
#
# Run from the project folder:   bash chat-community-install.sh
# Needs chat-blocks-install.sh first. Writes 9 files, patches 4, backs up into
# .chat-community-backup/<time>/, checks every file (stylesheets included),
# runs the rule tests and applies migration 033 if the database is reachable.
# No container is started, stopped or pulled.
# Undo: bash chat-community-install.sh --restore
set -euo pipefail

if [ ! -f apps/web/src/components/ChatKit/Composer.jsx ] || ! grep -q message_files server/src/files/FileService.js 2>/dev/null; then
  echo "Run this from the project folder, after chat-blocks-install.sh." >&2
  exit 1
fi
command -v node >/dev/null || { echo "node is required." >&2; exit 1; }
if ls server/src/db/migrations/033_*.sql 2>/dev/null | grep -qv 033_space_chat_extras.sql; then
  echo "Another migration 033 exists: $(ls server/src/db/migrations/033_*.sql | tr '\n' ' '). Nothing was changed." >&2
  exit 1
fi

TOUCHED=(
  apps/web/src/components/Messenger/messenger.css
  apps/web/src/components/ChatKit/Composer.jsx
  server/src/db/migrations/033_space_chat_extras.sql
  server/src/hub/spaceChatRules.js
  server/src/hub/SpaceChat.js
  server/test/hub/spaceChatRules.check.mjs
  apps/web/src/components/Hub/SpaceChat.jsx
  apps/web/src/components/Hub/spaceChat.css
  apps/web/src/components/Hub/hubWide.css
  server/src/routes/hub.routes.js
  server/src/files/FileService.js
  packages/core-client/src/api/hubApi.ts
  apps/web/src/pages/CommunityPage.jsx
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .chat-community-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/033_space_chat_extras.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  echo "Restored from $FIRST. Migration 033 stays, because the database may already have it."
  exit 0
fi

BACKUP=".chat-community-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

restore_and_exit() {
  for f in "${TOUCHED[@]}"; do
    if [ -f "$BACKUP/$f" ]; then cp "$BACKUP/$f" "$f"; elif [ -f "$f" ]; then rm "$f"; fi
  done
  rm -f .chat-community-patch.mjs .chat-community-css.mjs
  echo "$1 Every file was put back as it was." >&2
  exit 1
}

echo "--- patching existing files"
cat > .chat-community-patch.mjs <<'__CC_EOF__'
// Patches existing files for the Community rework. Every anchor is checked in
// every file before anything is written; a second run changes nothing.
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'server/src/routes/hub.routes.js',
    marker: 'SpaceChat.js',
    edits: [
      {
        name: 'import the new space chat',
        find: "import * as Extras from '../hub/HubExtras.js';\n",
        replace:
          "import * as Extras from '../hub/HubExtras.js';\n" +
          "import * as SpaceChat from '../hub/SpaceChat.js';\n" +
          '\n' +
          '/** A space chat message: text, files or one voice message, optionally a reply. */\n' +
          'const SpaceChatSendSchema = z\n' +
          '  .object({\n' +
          "    body: z.string().trim().max(2000).default(''),\n" +
          '    fileIds: z.array(z.string().uuid()).max(10).default([]),\n' +
          '    voice: z.object({ durationMs: z.number().int().min(0).max(900_000) }).nullish(),\n' +
          '    replyToId: z.string().uuid().nullish(),\n' +
          '  })\n' +
          '  .strict();\n',
      },
      {
        name: 'list: every change since the cursor',
        find: "  handle((req, res, viewer) => Extras.listMessages({ viewer, spaceId: req.params.id, after: req.query.after ?? null })),\n",
        replace: "  handle((req, res, viewer) => SpaceChat.list({ viewer, spaceId: req.params.id, after: (req.validatedQuery ?? req.query).after ?? null })),\n",
      },
      {
        name: 'send: text, files, voice, reply',
        find: '    return Extras.sendMessage({ viewer, spaceId: req.params.id, input: parse(Rules.ChatMessageSchema, req.body) });\n',
        replace: '    return SpaceChat.send({ viewer, spaceId: req.params.id, input: parse(SpaceChatSendSchema, req.body) });\n',
      },
      {
        name: 'delete own · remove as moderator; edit; react; shared media',
        find: "router.delete('/chat/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Extras.removeMessage({ viewer, messageId: req.params.id })));\n",
        replace:
          "router.delete('/chat/:id', validate({ params: spaceParam }), handle((req, res, viewer) => SpaceChat.remove({ viewer, messageId: req.params.id })));\n" +
          '\n' +
          'router.patch(\n' +
          "  '/chat/:id',\n" +
          '  validate({ params: spaceParam, body: z.object({ body: z.string().trim().min(1).max(2000) }) }),\n' +
          '  handle((req, res, viewer) => SpaceChat.edit({ viewer, messageId: req.params.id, body: req.body.body })),\n' +
          ');\n' +
          '\n' +
          'router.post(\n' +
          "  '/chat/:id/reactions',\n" +
          "  rateLimit({ key: 'hub:react', points: 120, durationSec: 60, by: ['user'] }),\n" +
          "  validate({ params: spaceParam, body: z.object({ emoji: z.string().min(1).max(16), action: z.enum(['add', 'remove']).default('add') }) }),\n" +
          '  handle((req, res, viewer) => SpaceChat.react({ viewer, messageId: req.params.id, emoji: req.body.emoji, action: req.body.action })),\n' +
          ');\n' +
          '\n' +
          'router.get(\n' +
          "  '/spaces/:id/chat/media',\n" +
          "  validate({ params: spaceParam, query: z.object({ kind: z.enum(['media', 'files', 'voice']).default('media'), before: z.string().datetime({ offset: true }).optional() }).passthrough() }),\n" +
          '  handle((req, res, viewer) => {\n' +
          '    const query = req.validatedQuery ?? req.query;\n' +
          "    return SpaceChat.media({ viewer, spaceId: req.params.id, kind: query.kind ?? 'media', before: query.before ?? null });\n" +
          '  }),\n' +
          ');\n',
      },
    ],
  },
  {
    file: 'server/src/files/FileService.js',
    marker: 'space_message_files',
    edits: [
      {
        name: 'members of a space may open files sent in its chat',
        find: '               WHERE mf.file_id = f.id))`,\n',
        replace:
          '               WHERE mf.file_id = f.id)\n' +
          '            OR EXISTS (\n' +
          '              -- Community (033): a file sent in a space chat, for whoever can read that chat.\n' +
          '              SELECT 1 FROM space_message_files smf\n' +
          '                JOIN space_messages sm2 ON sm2.id = smf.message_id AND sm2.deleted_at IS NULL\n' +
          '                JOIN spaces s2 ON s2.id = sm2.space_id AND s2.tenant_id = $3\n' +
          '                LEFT JOIN space_memberships ms2 ON ms2.space_id = s2.id AND ms2.user_id = $2\n' +
          "               WHERE smf.file_id = f.id AND (ms2.user_id IS NOT NULL OR s2.access = 'open')))`,\n",
      },
    ],
  },
  {
    file: 'packages/core-client/src/api/hubApi.ts',
    marker: 'reactChat',
    edits: [
      {
        name: 'interface',
        find: '  sendChat(spaceId: string, body: string): Promise<HubMessage>;\n  removeChat(messageId: string): Promise<unknown>;\n',
        replace:
          '  sendChat(\n' +
          '    spaceId: string,\n' +
          '    input: string | { body?: string; fileIds?: string[]; voice?: { durationMs: number }; replyToId?: string | null },\n' +
          '  ): Promise<HubMessage>;\n' +
          '  removeChat(messageId: string): Promise<unknown>;\n' +
          '  /** Community: edit your own message, within the edit window. */\n' +
          '  editChat(messageId: string, body: string): Promise<HubMessage>;\n' +
          '  /** Community: add or remove one emoji. */\n' +
          "  reactChat(messageId: string, input: { emoji: string; action: 'add' | 'remove' }): Promise<{ messageId: string; emoji: string; count: number; reacted: boolean; names: string[] }>;\n" +
          '  /** Community: pictures and videos · files · voice messages of a space chat. */\n' +
          "  chatMedia(spaceId: string, query?: { kind?: 'media' | 'files' | 'voice'; before?: string | null }, signal?: AbortSignal): Promise<{ items: Array<Record<string, unknown>>; nextBefore: string | null }>;\n",
      },
      {
        name: 'calls',
        find: '  sendChat: (spaceId, body) => http.post(`/hub/spaces/${enc(spaceId)}/chat`, { body }, { schema: HubMessageSchema, ...once }),\n',
        replace:
          '  sendChat: (spaceId, input) =>\n' +
          "    http.post(`/hub/spaces/${enc(spaceId)}/chat`, typeof input === 'string' ? { body: input } : input, { schema: HubMessageSchema, ...once }),\n" +
          '  editChat: (messageId, body) => http.patch(`/hub/chat/${enc(messageId)}`, { body }, { schema: HubMessageSchema }),\n' +
          '  reactChat: (messageId, input) => http.post(`/hub/chat/${enc(messageId)}/reactions`, input, { retry: { attempts: 1 } }),\n' +
          '  chatMedia: (spaceId, query = {}, signal) =>\n' +
          "    http.get(`/hub/spaces/${enc(spaceId)}/chat/media`, { query: { kind: query.kind ?? 'media', ...(query.before ? { before: query.before } : {}) }, signal }),\n",
      },
    ],
  },
  {
    file: 'apps/web/src/pages/CommunityPage.jsx',
    marker: 'hubWide.css',
    edits: [
      {
        name: 'full width',
        find: "import '../components/Hub/hub.css';\n",
        replace: "import '../components/Hub/hub.css';\nimport '../components/Hub/hubWide.css';\n",
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
__CC_EOF__
node .chat-community-patch.mjs || { rm -f .chat-community-patch.mjs; exit 1; }
rm -f .chat-community-patch.mjs

echo "--- writing files"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/messenger.css <<'__CC_EOF__'
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

/* ---------------------------------------------------------------- shared media (details panel) */
.mx-shared { display: grid; gap: 10px; }
.mx-tabs { display: grid; grid-template-columns: repeat(3, 1fr); padding: 3px; border-radius: 10px; background: var(--color-surface-2, #f1f5f4); }
.mx-tabs button { padding: 7px 6px; border: 0; border-radius: 8px; background: none; font: inherit; font-size: 13.5px; font-weight: 700; color: var(--color-muted, #5d6f73); cursor: pointer; }
.mx-tabs button.is-on { background: var(--color-surface, #fff); color: var(--color-text, #15272c); box-shadow: 0 1px 3px rgba(20, 38, 43, 0.12); }
.mx-shared__grid { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(3, 1fr); gap: 4px; }
.mx-shared__grid a { display: grid; place-items: center; aspect-ratio: 1; border-radius: 8px; overflow: hidden; background: #0d1a1e; }
.mx-shared__grid img { width: 100%; height: 100%; object-fit: cover; }
.mx-shared__video { color: #fff; font-size: 22px; }
.mx-shared__list { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.mx-shared__list li { display: flex; align-items: center; gap: 10px; }
.mx-shared__list li.mx-shared__voice { display: grid; gap: 2px; }
.mx-shared__text { display: grid; min-width: 0; font-size: 14px; }
.mx-shared__text a { color: var(--color-text, #15272c); font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mx-shared__text .mx-muted { font-size: 12.5px; }
.mx-composer .ck-composer__hint { max-width: 920px; margin: 0 auto; }
@media (max-width: 899px) { .mx-composer .ck-composer__hint { display: none; } }
__CC_EOF__
echo "wrote apps/web/src/components/Messenger/messenger.css"
mkdir -p apps/web/src/components/ChatKit
cat > apps/web/src/components/ChatKit/Composer.jsx <<'__CC_EOF__'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { uploadFile } from '../../lib/files.js';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { CHAT_ACCEPT, attachProblem, formatDuration, recorderFormat } from './chatKitModel.js';

/**
 * The composer  (chat kit)
 *
 *   text        Enter sends, Shift+Enter is a new line; grows up to six lines
 *   files       📎, drag-and-drop onto the chat, or paste; each uploads at once
 *               through the normal upload checks and shows its progress; the
 *               message can be sent when all are ready
 *   voice       🎤 when there is nothing to send: records, shows the time, and
 *               sends or cancels; the recording is an ordinary upload too
 *
 * The caller decides what "send" means (onSend({ body, files, voice })), so the
 * same composer serves Messages and the community chat. `below(draft, clear)`
 * renders something under it that needs the draft (the late-night nudge).
 */

const MAX_VOICE_MS = 15 * 60 * 1000;

let stagedSeq = 0;

export function useAttachments(files) {
  const [staged, setStaged] = useState([]);
  const controllers = useRef(new Map());

  // The current list, for add(): a state updater has to stay pure (React may
  // run it twice in development), so uploads are started from here instead.
  const stagedRef = useRef([]);
  useEffect(() => {
    stagedRef.current = staged;
  }, [staged]);

  const add = useCallback(
    (list) => {
      const errors = [];
      const picked = [];
      let count = stagedRef.current.length;
      for (const file of list) {
        const problem = attachProblem(file, { staged: count });
        if (problem) {
          errors.push(problem);
          continue;
        }
        count += 1;
        picked.push({ id: `s${(stagedSeq += 1)}`, file, progress: 0, phase: 'starting', result: null, error: null });
      }
      if (!picked.length) return errors;
      stagedRef.current = [...stagedRef.current, ...picked];
      setStaged((current) => [...current, ...picked]);
      for (const item of picked) {
        const controller = new AbortController();
        controllers.current.set(item.id, controller);
        const patch = (change) => setStaged((current) => current.map((s) => (s.id === item.id ? { ...s, ...change } : s)));
        uploadFile({ files, file: item.file, signal: controller.signal, onProgress: (progress) => patch({ progress }), onPhase: (phase) => patch({ phase }) })
          .then((result) => patch({ result, phase: 'ready', progress: 1 }))
          .catch((cause) => !controller.signal.aborted && patch({ error: cause.message, phase: 'failed' }))
          .finally(() => controllers.current.delete(item.id));
      }
      return errors;
    },
    [files],
  );

  const remove = useCallback((id) => {
    controllers.current.get(id)?.abort();
    stagedRef.current = stagedRef.current.filter((s) => s.id !== id);
    setStaged((current) => current.filter((s) => s.id !== id));
  }, []);

  const clear = useCallback(() => {
    for (const controller of controllers.current.values()) controller.abort();
    controllers.current.clear();
    stagedRef.current = [];
    setStaged([]);
  }, []);

  useEffect(() => () => controllers.current.forEach((c) => c.abort()), []);

  const ready = staged.filter((s) => s.result).map((s) => s.result);
  const busy = staged.some((s) => !s.result && !s.error);
  return { staged, add, remove, clear, ready, busy };
}

function useRecorder() {
  const [state, setState] = useState('idle'); // idle · recording · sending
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState(null);
  const recorder = useRef(null);
  const chunks = useRef([]);
  const startedAt = useRef(0);
  const stream = useRef(null);
  const timer = useRef(null);
  const resolveStop = useRef(null);

  const release = () => {
    window.clearInterval(timer.current);
    stream.current?.getTracks().forEach((track) => track.stop());
    stream.current = null;
  };
  useEffect(() => () => release(), []);

  const start = async () => {
    setError(null);
    const format = recorderFormat(globalThis.MediaRecorder?.isTypeSupported?.bind(globalThis.MediaRecorder));
    if (!format || !navigator.mediaDevices?.getUserMedia) {
      setError('This browser cannot record voice messages.');
      return;
    }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    } catch {
      setError('The microphone is not available. Allow it in the browser and try again.');
      return;
    }
    chunks.current = [];
    const rec = new MediaRecorder(stream.current, { mimeType: format.mimeType, audioBitsPerSecond: 48_000 });
    rec.ondataavailable = (event) => event.data?.size && chunks.current.push(event.data);
    rec.onstop = () => {
      const durationMs = Date.now() - startedAt.current;
      const blob = new Blob(chunks.current, { type: format.mimeType.split(';')[0] });
      release();
      resolveStop.current?.({ blob, durationMs, ext: format.ext });
    };
    recorder.current = rec;
    startedAt.current = Date.now();
    rec.start(250);
    setElapsed(0);
    setState('recording');
    timer.current = window.setInterval(() => {
      const ms = Date.now() - startedAt.current;
      setElapsed(ms);
      if (ms >= MAX_VOICE_MS) recorder.current?.state === 'recording' && recorder.current.stop();
    }, 200);
  };

  const stop = () =>
    new Promise((resolve) => {
      resolveStop.current = resolve;
      if (recorder.current?.state === 'recording') recorder.current.stop();
      else resolve(null);
    });

  const cancel = () => {
    resolveStop.current = null;
    if (recorder.current?.state === 'recording') recorder.current.stop();
    release();
    setState('idle');
  };

  return { state, setState, elapsed, error, setError, start, stop, cancel };
}

export default function Composer({ files, placeholder, disabled = false, disabledReason = '', onSend, onTyping, onArrowUp, onEscape, top = null, below = null, inputRef: externalRef = null, hint = true }) {
  const [draft, setDraft] = useState('');
  const [notice, setNotice] = useState(null);
  const [dragging, setDragging] = useState(false);
  const ownRef = useRef(null);
  const inputRef = externalRef ?? ownRef;
  const pickerRef = useRef(null);
  const attachments = useAttachments(files);
  const voice = useRecorder();

  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 180)}px`;
  }, [draft, inputRef]);

  const addFiles = (list) => {
    const errors = attachments.add([...list]);
    setNotice(errors.length ? errors.join(' ') : null);
  };

  // Drop onto the chat area (the composer's parent listens through these).
  useEffect(() => {
    const area = inputRef.current?.closest('[data-ck-dropzone]');
    if (!area || disabled) return undefined;
    let depth = 0;
    const hasFiles = (event) => [...(event.dataTransfer?.types ?? [])].includes('Files');
    const enter = (event) => hasFiles(event) && (depth += 1, setDragging(true), event.preventDefault());
    const over = (event) => hasFiles(event) && event.preventDefault();
    const leave = () => (depth = Math.max(0, depth - 1)) === 0 && setDragging(false);
    const drop = (event) => {
      if (!hasFiles(event)) return;
      event.preventDefault();
      depth = 0;
      setDragging(false);
      addFiles(event.dataTransfer.files);
    };
    area.addEventListener('dragenter', enter);
    area.addEventListener('dragover', over);
    area.addEventListener('dragleave', leave);
    area.addEventListener('drop', drop);
    return () => {
      area.removeEventListener('dragenter', enter);
      area.removeEventListener('dragover', over);
      area.removeEventListener('dragleave', leave);
      area.removeEventListener('drop', drop);
    };
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const canSend = !disabled && !attachments.busy && (draft.trim() || attachments.ready.length) && voice.state === 'idle';

  const send = async () => {
    if (!canSend) return;
    const body = draft.trim();
    const ready = attachments.ready;
    setDraft('');
    attachments.clear();
    onTyping?.(false);
    setNotice(null);
    try {
      await onSend({ body, files: ready });
    } catch (cause) {
      setNotice(cause?.detail ?? cause?.message ?? 'Not sent.');
    }
  };

  const sendVoice = async () => {
    const recording = await voice.stop();
    if (!recording) return;
    if (recording.durationMs < 700 || recording.blob.size === 0) {
      voice.setState('idle');
      setNotice('That was too short. Hold on a little longer.');
      return;
    }
    voice.setState('sending');
    try {
      const file = new File([recording.blob], `Voice message.${recording.ext}`, { type: recording.blob.type });
      const uploaded = await uploadFile({ files, file });
      await onSend({ body: '', files: [uploaded], voice: { durationMs: Math.round(recording.durationMs) } });
      setNotice(null);
    } catch (cause) {
      setNotice(cause?.message ?? 'The voice message was not sent.');
    } finally {
      voice.setState('idle');
    }
  };

  const showMic = !draft.trim() && attachments.staged.length === 0;

  return (
    <div className={`ck-composer${dragging ? ' is-dragging' : ''}`}>
      {dragging ? <div className="ck-dropveil">Drop to attach</div> : null}
      {disabledReason ? <p className="ck-composer__notice">{disabledReason}</p> : null}
      {top}
      {attachments.staged.length ? (
        <ul className="ck-tray" aria-label="Attachments">
          {attachments.staged.map((item) => (
            <li key={item.id} className={`ck-tray__item${item.error ? ' is-failed' : ''}${item.result ? ' is-ready' : ''}`}>
              <span className="ck-tray__icon" aria-hidden="true">{iconFor(item.result?.kind ?? 'document')}</span>
              <span className="ck-tray__text">
                <span className="ck-tray__name" title={item.file.name}>{item.file.name}</span>
                <span className="ck-tray__meta">
                  {item.error ? item.error : item.result ? fileMeta(item.result) : item.phase === 'checking' ? 'Checking…' : `${Math.round(item.progress * 100)} %`}
                </span>
                {!item.result && !item.error ? <i className="ck-tray__bar" style={{ transform: `scaleX(${item.progress})` }} /> : null}
              </span>
              <button type="button" onClick={() => attachments.remove(item.id)} aria-label={`Remove ${item.file.name}`}>×</button>
            </li>
          ))}
        </ul>
      ) : null}
      {notice || voice.error ? (
        <p className="ck-composer__error" role="alert">
          {notice ?? voice.error}
          <button type="button" onClick={() => (setNotice(null), voice.setError(null))} aria-label="Dismiss">×</button>
        </p>
      ) : null}

      {voice.state === 'idle' ? (
        <form
          className="ck-composer__row"
          onSubmit={(event) => {
            event.preventDefault();
            send();
          }}
        >
          <button type="button" className="ck-round ck-round--ghost" onClick={() => pickerRef.current?.click()} disabled={disabled} aria-label="Attach files" title="Attach files">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16.5 6.5l-7.8 7.8a2 2 0 102.8 2.8l7.8-7.8a4 4 0 10-5.7-5.7l-8 8a6 6 0 108.5 8.5l6.6-6.6" /></svg>
          </button>
          <input ref={pickerRef} type="file" multiple hidden accept={CHAT_ACCEPT.map((ext) => `.${ext}`).join(',')} onChange={(event) => (addFiles(event.target.files), (event.target.value = ''))} />
          <textarea
            ref={inputRef}
            rows={1}
            value={draft}
            maxLength={4000}
            placeholder={placeholder}
            aria-label={placeholder}
            disabled={disabled}
            onChange={(event) => {
              setDraft(event.target.value);
              onTyping?.(event.target.value.length > 0);
            }}
            onPaste={(event) => {
              const pasted = [...(event.clipboardData?.files ?? [])];
              if (pasted.length) {
                event.preventDefault();
                addFiles(pasted);
              }
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                send();
              } else if (event.key === 'ArrowUp' && !draft && onArrowUp?.()) {
                event.preventDefault();
              } else if (event.key === 'Escape') {
                onEscape?.();
              }
            }}
          />
          {showMic ? (
            <button type="button" className="ck-round ck-round--accent" onClick={voice.start} disabled={disabled} aria-label="Record a voice message" title="Record a voice message">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15a3 3 0 003-3V6a3 3 0 10-6 0v6a3 3 0 003 3zm5-3a5 5 0 01-10 0H5a7 7 0 006 6.9V21h2v-2.1A7 7 0 0019 12h-2z" /></svg>
            </button>
          ) : (
            <button type="submit" className="ck-round ck-round--accent" disabled={!canSend} aria-label={attachments.busy ? 'Uploading…' : 'Send'} title={attachments.busy ? 'Waiting for the upload' : 'Send'}>
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12l16-8-6 16-2.5-6.5L4 12z" /></svg>
            </button>
          )}
        </form>
      ) : (
        <div className="ck-recording" role="group" aria-label="Voice message">
          <button type="button" className="ck-round ck-round--ghost" onClick={voice.cancel} disabled={voice.state === 'sending'} aria-label="Cancel voice message" title="Cancel">
            🗑
          </button>
          <span className="ck-recording__dot" aria-hidden="true" />
          <span className="ck-recording__time" aria-live="off">{formatDuration(voice.elapsed)}</span>
          <span className="ck-recording__label">{voice.state === 'sending' ? 'Sending…' : 'Recording'}</span>
          <button type="button" className="ck-round ck-round--accent" onClick={sendVoice} disabled={voice.state === 'sending'} aria-label="Send voice message" title="Send">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12l16-8-6 16-2.5-6.5L4 12z" /></svg>
          </button>
        </div>
      )}
      {below ? below(draft, () => setDraft('')) : null}
      {hint ? <p className="ck-composer__hint">Enter to send · Shift+Enter for a new line · drop files to attach</p> : null}
    </div>
  );
}
__CC_EOF__
echo "wrote apps/web/src/components/ChatKit/Composer.jsx"
mkdir -p server/src/db/migrations
cat > server/src/db/migrations/033_space_chat_extras.sql <<'__CC_EOF__'
-- 033_space_chat_extras.sql  (Community: the space chat gets the chat's building blocks)
--
--   space_messages.updated_at    moves on every change (new, edit, delete,
--                                reaction), so an open chat catches up on all
--                                of them, not only on new messages
--   space_messages.edited_at     "edited"
--   space_messages.reply_to_id   replies quote the message they answer
--   space_message_reactions      one row per person and emoji
--   space_message_files          files from the upload pipeline (files, 029);
--                                voice_duration_ms marks a voice message
--
-- Additive only. Existing messages get updated_at = created_at.

alter table space_messages add column if not exists updated_at  timestamptz;
alter table space_messages add column if not exists edited_at   timestamptz;
alter table space_messages add column if not exists reply_to_id uuid references space_messages (id) on delete set null;
update space_messages set updated_at = coalesce(deleted_at, created_at) where updated_at is null;
alter table space_messages alter column updated_at set default now();
alter table space_messages alter column updated_at set not null;
create index if not exists space_messages_updated_idx on space_messages (space_id, updated_at);

create table if not exists space_message_reactions (
  message_id uuid        not null references space_messages (id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  emoji      text        not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

create table if not exists space_message_files (
  message_id        uuid     not null references space_messages (id) on delete cascade,
  file_id           uuid     not null references files (id) on delete cascade,
  position          smallint not null default 0,
  voice_duration_ms integer  check (voice_duration_ms is null or voice_duration_ms between 0 and 900000),
  primary key (message_id, file_id)
);
create index if not exists space_message_files_file_idx on space_message_files (file_id);
__CC_EOF__
echo "wrote server/src/db/migrations/033_space_chat_extras.sql"
mkdir -p server/src/hub
cat > server/src/hub/spaceChatRules.js <<'__CC_EOF__'
// classroom-app/server/src/hub/spaceChatRules.js
/**
 * Who may do what in a space chat  (Community)
 *
 * Pure, tested in server/test/hub/spaceChatRules.check.mjs. The same rules
 * people know from group chats:
 *
 *   delete    your own messages, for everyone ("This message was deleted")
 *   remove    owners and moderators may remove anyone's message ("Removed by a
 *             moderator"); members never delete other people's messages
 *   edit      your own text, within the edit window, never someone else's
 */

export const isModerator = (membership) => membership?.role === 'owner' || membership?.role === 'moderator';

/** 'author' · 'moderator' · null — how this viewer may take a message down. */
export const removalBy = ({ authorId, viewerId, membership }) => {
  if (authorId && authorId === viewerId) return 'author';
  if (isModerator(membership)) return 'moderator';
  return null;
};

export const canEdit = ({ authorId, viewerId, deletedAt = null, createdAt, body = '', windowMin = 0, now = Date.now() }) => {
  if (!authorId || authorId !== viewerId || deletedAt || !String(body).trim()) return false;
  if (!windowMin || windowMin <= 0) return true;
  const created = new Date(createdAt).getTime();
  return !Number.isNaN(created) && now - created <= windowMin * 60_000;
};

/** How a removed message reads, from who removed it. */
export const deletedByRole = ({ deletedBy, authorId }) => (!deletedBy ? null : deletedBy === authorId ? 'author' : 'moderator');

export default { isModerator, removalBy, canEdit, deletedByRole };
__CC_EOF__
echo "wrote server/src/hub/spaceChatRules.js"
mkdir -p server/src/hub
cat > server/src/hub/SpaceChat.js <<'__CC_EOF__'
// classroom-app/server/src/hub/SpaceChat.js
/**
 * The chat of a space  (Community)
 *
 * Replaces the chat part of HubExtras with the same building blocks as
 * Messages (messaging/ChatExtras.js), minus calls — those are what rooms are for:
 *
 *   list      the newest 80, or everything that changed after a cursor — new
 *             messages, edits, deletions and reactions alike (updated_at,
 *             033), so an open chat never shows something stale
 *   send      text, files (pictures, videos, documents) or one voice message,
 *             optionally as a reply; calm mode and posting blocks as before
 *   edit      your own text, within CHAT_EDIT_WINDOW_MIN
 *   remove    your own message ("deleted"), or anyone's as owner or moderator
 *             ("removed by a moderator", logged); members never delete others'
 *   react     one emoji at a time, at most 12 different per person
 *   media     pictures and videos · files · voice messages of the chat
 *
 * Members are told something changed (hub:chat) and fetch the changes; with no
 * live connection they catch up on their next poll.
 */

import { pool } from '../db/pool.js';
import { env } from '../config/env.js';
import { logger } from '../observability/logger.js';
import { internals } from './HubService.js';
import * as HubRules from './hubRules.js';
import * as Part3 from './partRules.js';
import * as Rules from './spaceChatRules.js';
import * as Extras from '../messaging/chatExtrasRules.js';
import * as Files from '../files/FileService.js';

const log = logger.child({ component: 'space-chat' });
const { loadSpace, notBlocked, iso, fail, logAction } = internals;

const LIMIT = 80;
const LIVE_FANOUT_LIMIT = 150;
const CURSOR = (column) => `to_char(${column} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

const requireFullView = async (viewer, spaceId) => {
  const loaded = await loadSpace(viewer, spaceId);
  if (HubRules.viewOf(loaded.space, loaded.membership) !== 'full') fail('forbidden', 'Join the space to see this.');
  return loaded;
};

const messageRow = async (messageId) => {
  const { rows } = await pool.query(`SELECT * FROM space_messages WHERE id = $1`, [messageId]);
  if (!rows[0]) fail('not_found', 'No such message');
  return rows[0];
};

/** Tell the other members something changed; best effort. */
const signal = async (spaceId, exceptUserId) => {
  try {
    const { rows } = await pool.query(
      `SELECT user_id FROM space_memberships WHERE space_id = $1 AND user_id <> $2 LIMIT ${LIVE_FANOUT_LIMIT}`,
      [spaceId, exceptUserId],
    );
    const { pushToUser } = await import('../realtime/userEvents.js');
    await Promise.all(rows.map((row) => pushToUser(row.user_id, 'hub:chat', { spaceId })));
  } catch (cause) {
    log.debug({ err: cause }, 'chat live signal not sent; members catch up on their next fetch');
  }
};

const touch = (messageId) => pool.query(`UPDATE space_messages SET updated_at = now() WHERE id = $1`, [messageId]);

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

const toFile = (row) => ({
  ...Files.toView(row),
  voice: row.voice_duration_ms !== null && row.voice_duration_ms !== undefined,
  durationMs: row.voice_duration_ms ?? null,
});

const extrasFor = async (ids, viewerId) => {
  const result = new Map(ids.map((id) => [id, { files: [], rows: [] }]));
  if (!ids.length) return result;
  const [{ rows: files }, { rows: reactions }] = await Promise.all([
    pool.query(
      `SELECT mf.message_id, mf.position, mf.voice_duration_ms, f.*
         FROM space_message_files mf JOIN files f ON f.id = mf.file_id
        WHERE mf.message_id = ANY($1::uuid[]) AND f.deleted_at IS NULL AND f.status = 'ready'
        ORDER BY mf.message_id, mf.position`,
      [ids],
    ),
    pool.query(
      `SELECT r.message_id, r.emoji, r.user_id, r.created_at, u.display_name
         FROM space_message_reactions r JOIN users u ON u.id = r.user_id
        WHERE r.message_id = ANY($1::uuid[]) ORDER BY r.created_at`,
      [ids],
    ),
  ]);
  for (const row of files) result.get(row.message_id)?.files.push(toFile(row));
  for (const row of reactions) result.get(row.message_id)?.rows.push(row);
  for (const [, entry] of result) entry.reactions = Extras.summariseReactions(entry.rows, viewerId);
  return result;
};

const toViews = async (rows, viewer, membership) => {
  const live = rows.filter((row) => !row.deleted_at).map((row) => row.id);
  const extras = await extrasFor(live, viewer.userId);
  return rows.map((row) => {
    const deleted = Boolean(row.deleted_at);
    const entry = extras.get(row.id);
    const removeAs = deleted ? null : Rules.removalBy({ authorId: row.author_id, viewerId: viewer.userId, membership });
    return {
      messageId: row.id,
      body: deleted ? '' : row.body,
      author: { userId: row.author_id, displayName: row.display_name ?? 'Someone', you: row.author_id === viewer.userId },
      createdAt: iso(row.created_at),
      editedAt: deleted ? null : iso(row.edited_at),
      deletedAt: iso(row.deleted_at),
      deletedBy: Rules.deletedByRole({ deletedBy: row.deleted_at ? row.deleted_by ?? row.author_id : null, authorId: row.author_id }),
      replyToId: row.reply_to_id ?? null,
      files: entry?.files ?? [],
      reactions: entry?.reactions ?? [],
      cursor: row.cursor,
      canRemove: Boolean(removeAs),
      removeAs,
      canEdit: Rules.canEdit({ authorId: row.author_id, viewerId: viewer.userId, deletedAt: row.deleted_at, createdAt: row.created_at, body: row.body, windowMin: env.CHAT_EDIT_WINDOW_MIN ?? 15 }),
    };
  });
};

const SELECT = `m.id, m.author_id, m.body, m.created_at, m.updated_at, m.edited_at, m.deleted_at, m.deleted_by, m.reply_to_id,
                ${CURSOR('m.updated_at')} AS cursor, u.display_name`;

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

/**
 * Without `after`: the newest 80 messages, oldest first. With `after`: every
 * message that changed since (new, edited, deleted, reacted to), in the order
 * they changed. nextCursor is the newest change seen.
 */
export const list = async ({ viewer, spaceId, after = null }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  let rows;
  if (after) {
    ({ rows } = await pool.query(
      `SELECT ${SELECT} FROM space_messages m JOIN users u ON u.id = m.author_id
        WHERE m.space_id = $1 AND m.updated_at > $3::timestamptz AND ${notBlocked('m.author_id', '$2')}
        ORDER BY m.updated_at ASC LIMIT 200`,
      [spaceId, viewer.userId, after],
    ));
  } else {
    ({ rows } = await pool.query(
      `SELECT * FROM (
         SELECT ${SELECT} FROM space_messages m JOIN users u ON u.id = m.author_id
          WHERE m.space_id = $1 AND ${notBlocked('m.author_id', '$2')}
          ORDER BY m.created_at DESC LIMIT ${LIMIT}) latest
        ORDER BY created_at ASC`,
      [spaceId, viewer.userId],
    ));
  }
  const { rows: newest } = await pool.query(`SELECT ${CURSOR('max(updated_at)')} AS cursor FROM space_messages WHERE space_id = $1`, [spaceId]);
  const items = await toViews(rows, viewer, membership);
  return {
    items,
    nextCursor: newest[0]?.cursor ?? after,
    calmSeconds: space.chatSlowSeconds ?? 0,
    canModerate: Rules.isModerator(membership),
    postingBlocked: HubRules.postingBlockedBecause(space, membership),
    editWindowMin: env.CHAT_EDIT_WINDOW_MIN ?? 15,
    serverTime: new Date().toISOString(),
  };
};

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

const checkFiles = async ({ viewer, fileIds = [], voice = null }) => {
  const ids = [...new Set(fileIds)];
  if (!ids.length) return { ids, durationMs: null };
  if (ids.length > Extras.MAX_FILES_PER_MESSAGE) fail('validation_failed', `Up to ${Extras.MAX_FILES_PER_MESSAGE} files per message.`);
  const { rows } = await pool.query(
    `SELECT id, kind FROM files WHERE id = ANY($1::uuid[]) AND owner_id = $2 AND tenant_id = $3 AND status = 'ready' AND deleted_at IS NULL`,
    [ids, viewer.userId, viewer.tenantId],
  );
  if (rows.length !== ids.length) fail('validation_failed', 'One of the files is not ready yet or is no longer available. Upload it again.');
  let durationMs = null;
  if (voice) {
    if (ids.length !== 1 || !['audio', 'video'].includes(rows[0].kind)) fail('validation_failed', 'A voice message is one recording.');
    durationMs = Extras.voiceDuration(voice.durationMs);
  }
  return { ids, durationMs };
};

export const send = async ({ viewer, spaceId, input }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const blocked = HubRules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);
  const body = String(input.body ?? '').trim();
  const fileIds = input.fileIds ?? [];
  if (!body && !fileIds.length) fail('validation_failed', 'A message needs text or a file.');

  if (space.chatSlowSeconds > 0 && !Rules.isModerator(membership)) {
    const { rows: last } = await pool.query(
      `SELECT max(created_at) AS at FROM space_messages WHERE space_id = $1 AND author_id = $2 AND deleted_at IS NULL`,
      [spaceId, viewer.userId],
    );
    const wait = Part3.calmWait({ slowSeconds: space.chatSlowSeconds, lastPostAt: last[0]?.at });
    if (wait > 0) fail('forbidden', Part3.calmMessage(wait));
  }

  if (input.replyToId) {
    const { rows } = await pool.query(`SELECT 1 FROM space_messages WHERE id = $1 AND space_id = $2`, [input.replyToId, spaceId]);
    if (!rows[0]) fail('validation_failed', 'The message you reply to is not in this space.');
  }
  const checked = await checkFiles({ viewer, fileIds, voice: input.voice ?? null });

  const { rows } = await pool.query(
    `INSERT INTO space_messages (space_id, author_id, body, reply_to_id) VALUES ($1, $2, $3, $4) RETURNING id`,
    [spaceId, viewer.userId, body, input.replyToId ?? null],
  );
  const messageId = rows[0].id;
  if (checked.ids.length) {
    await pool.query(
      `INSERT INTO space_message_files (message_id, file_id, position, voice_duration_ms)
       SELECT $1, f.id, f.position - 1, $3 FROM unnest($2::uuid[]) WITH ORDINALITY AS f(id, position)
       ON CONFLICT DO NOTHING`,
      [messageId, checked.ids, checked.durationMs],
    );
  }
  void signal(spaceId, viewer.userId);
  return view(viewer, membership, messageId);
};

const view = async (viewer, membership, messageId) => {
  const { rows } = await pool.query(`SELECT ${SELECT} FROM space_messages m JOIN users u ON u.id = m.author_id WHERE m.id = $1`, [messageId]);
  return (await toViews(rows, viewer, membership))[0];
};

// ---------------------------------------------------------------------------
// Edit, remove, react
// ---------------------------------------------------------------------------

export const edit = async ({ viewer, messageId, body }) => {
  const row = await messageRow(messageId);
  const { membership } = await requireFullView(viewer, row.space_id);
  const text = String(body ?? '').trim();
  if (!text) fail('validation_failed', 'A message cannot be empty. Delete it instead.');
  if (row.author_id !== viewer.userId) fail('forbidden', 'You can only edit your own messages.');
  if (row.deleted_at) fail('gone', 'This message was deleted.');
  const windowMin = env.CHAT_EDIT_WINDOW_MIN ?? 15;
  if (!Rules.canEdit({ authorId: row.author_id, viewerId: viewer.userId, createdAt: row.created_at, body: row.body, windowMin })) {
    fail('conflict', `Messages can be edited for ${windowMin} minutes after sending.`);
  }
  await pool.query(`UPDATE space_messages SET body = $2, edited_at = now(), updated_at = now() WHERE id = $1`, [messageId, text]);
  void signal(row.space_id, viewer.userId);
  return view(viewer, membership, messageId);
};

export const remove = async ({ viewer, messageId }) => {
  const row = await messageRow(messageId);
  if (row.deleted_at) return { removed: true };
  const { membership } = await requireFullView(viewer, row.space_id);
  const as = Rules.removalBy({ authorId: row.author_id, viewerId: viewer.userId, membership });
  if (!as) fail('forbidden', 'You can only delete your own messages.');
  await pool.query(`UPDATE space_messages SET deleted_at = now(), deleted_by = $2, updated_at = now() WHERE id = $1`, [messageId, viewer.userId]);
  if (as === 'moderator') await logAction(row.space_id, viewer.userId, 'chat.remove');
  void signal(row.space_id, viewer.userId);
  return { removed: true, as };
};

export const react = async ({ viewer, messageId, emoji, action = 'add' }) => {
  if (!Extras.isEmoji(emoji)) fail('validation_failed', 'A reaction is one emoji.');
  const row = await messageRow(messageId);
  if (row.deleted_at) fail('gone', 'This message was deleted.');
  await requireFullView(viewer, row.space_id);
  if (action === 'remove') {
    await pool.query(`DELETE FROM space_message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3`, [messageId, viewer.userId, emoji]);
  } else {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n FROM space_message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji <> $3`,
      [messageId, viewer.userId, emoji],
    );
    if ((rows[0]?.n ?? 0) >= Extras.MAX_REACTIONS_PER_PERSON) fail('conflict', 'That is enough reactions on one message.');
    await pool.query(`INSERT INTO space_message_reactions (message_id, user_id, emoji) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, [messageId, viewer.userId, emoji]);
  }
  await touch(messageId);
  const { rows: current } = await pool.query(
    `SELECT r.emoji, r.user_id, r.created_at, u.display_name FROM space_message_reactions r JOIN users u ON u.id = r.user_id
      WHERE r.message_id = $1 AND r.emoji = $2 ORDER BY r.created_at`,
    [messageId, emoji],
  );
  void signal(row.space_id, viewer.userId);
  const summary = Extras.summariseReactions(current, viewer.userId)[0] ?? { emoji, count: 0, reacted: false, names: [] };
  return { messageId, ...summary };
};

// ---------------------------------------------------------------------------
// Everything shared in the chat
// ---------------------------------------------------------------------------

const GALLERY_WHERE = {
  voice: 'mf.voice_duration_ms IS NOT NULL',
  media: "mf.voice_duration_ms IS NULL AND f.kind IN ('image', 'video')",
  files: "mf.voice_duration_ms IS NULL AND f.kind NOT IN ('image', 'video')",
};

export const media = async ({ viewer, spaceId, kind = 'media', before = null, limit = 60 }) => {
  if (!Extras.MEDIA_KINDS.includes(kind)) fail('validation_failed', 'Unknown kind.');
  await requireFullView(viewer, spaceId);
  const size = Math.min(Math.max(Number(limit) || 60, 1), 200);
  const { rows } = await pool.query(
    `SELECT mf.voice_duration_ms, f.*, m.id AS message_id, m.created_at AS sent_at, m.author_id, u.display_name AS author_name
       FROM space_message_files mf
       JOIN space_messages m ON m.id = mf.message_id
       JOIN files f ON f.id = mf.file_id
       LEFT JOIN users u ON u.id = m.author_id
      WHERE m.space_id = $1 AND m.deleted_at IS NULL AND f.deleted_at IS NULL AND f.status = 'ready'
        AND ($2::timestamptz IS NULL OR m.created_at < $2)
        AND ${notBlocked('m.author_id', '$4')}
        AND ${GALLERY_WHERE[kind]}
      ORDER BY m.created_at DESC, mf.position
      LIMIT $3`,
    [spaceId, before, size + 1, viewer.userId],
  );
  const page = rows.slice(0, size);
  return {
    items: page.map((row) => ({ ...toFile(row), messageId: row.message_id, sentAt: iso(row.sent_at), authorId: row.author_id, authorName: row.author_name ?? 'Someone' })),
    nextBefore: rows.length > size ? iso(page.at(-1).sent_at) : null,
  };
};

export default { list, send, edit, remove, react, media };
__CC_EOF__
echo "wrote server/src/hub/SpaceChat.js"
mkdir -p server/test/hub
cat > server/test/hub/spaceChatRules.check.mjs <<'__CC_EOF__'
// node --test server/test/hub/spaceChatRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { removalBy, canEdit, deletedByRole } from '../../src/hub/spaceChatRules.js';

test('delete own, moderators remove, members never delete others', () => {
  assert.equal(removalBy({ authorId: 'a', viewerId: 'a', membership: { role: 'member' } }), 'author');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'a', membership: { role: 'owner' } }), 'author');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: { role: 'moderator' } }), 'moderator');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: { role: 'owner' } }), 'moderator');
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: { role: 'member' } }), null);
  assert.equal(removalBy({ authorId: 'a', viewerId: 'b', membership: null }), null);
});

test('edit only own text inside the window', () => {
  const now = Date.parse('2026-10-03T12:00:00Z');
  const base = { authorId: 'a', viewerId: 'a', body: 'hi', createdAt: '2026-10-03T11:55:00Z', windowMin: 15, now };
  assert.equal(canEdit(base), true);
  assert.equal(canEdit({ ...base, viewerId: 'b' }), false);
  assert.equal(canEdit({ ...base, body: '  ' }), false);
  assert.equal(canEdit({ ...base, deletedAt: 'x' }), false);
  assert.equal(canEdit({ ...base, createdAt: '2026-10-03T11:30:00Z' }), false);
  assert.equal(canEdit({ ...base, createdAt: '2020-01-01T00:00:00Z', windowMin: 0 }), true);
});

test('who removed it', () => {
  assert.equal(deletedByRole({ deletedBy: null, authorId: 'a' }), null);
  assert.equal(deletedByRole({ deletedBy: 'a', authorId: 'a' }), 'author');
  assert.equal(deletedByRole({ deletedBy: 'm', authorId: 'a' }), 'moderator');
});
__CC_EOF__
echo "wrote server/test/hub/spaceChatRules.check.mjs"
mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/SpaceChat.jsx <<'__CC_EOF__'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { createChatApi, createFilesApi, createProfileApi, useCore } from '@classroom/core-client';
import { onUserEvent } from '../../lib/userEvents.js';
import { formatDate, formatTime } from '../../lib/preferences.js';
import { CALM_CHOICES, calmLabel } from './hubModel.js';
import LateNightNudge from './LateNightNudge.jsx';
import Avatar from '../Messenger/Avatar.jsx';
import { ProfileDialog } from '../Messenger/ProfileCard.jsx';
import { ConfirmDialog } from '../Messenger/Dialogs.jsx';
import SharedMedia from '../Messenger/SharedMedia.jsx';
import { dayLabel, highlightParts, searchHits, snippet, threadRows } from '../Messenger/messengerModel.js';
import Composer from '../ChatKit/Composer.jsx';
import MessageFiles from '../ChatKit/MessageFiles.jsx';
import { ReactionChips, ReactionPicker } from '../ChatKit/Reactions.jsx';
import { filesLabel, toggleAction } from '../ChatKit/chatKitModel.js';
import '../ChatKit/chatkit.css';
import './spaceChat.css';

/**
 * The chat of a space  (Community)
 *
 * The same building blocks as Messages — reactions, files and pictures, voice
 * messages, reply, edit, search, everything shared — without calls: those are
 * what the space's rooms are for.
 *
 *   beside the chat   Members (how many, who, their role; a name opens the
 *                     profile, from where you can write privately) and Shared
 *                     (media · files · voice of this chat)
 *   deleting          your own messages, for everyone; owners and moderators
 *                     may remove anyone's ("Removed by a moderator")
 *   staying current   the server says which messages changed — new, edited,
 *                     deleted or reacted to — so every open chat shows the same
 *   kept              calm mode, paused posting, the late-night nudge
 */

const POLL_MS = 5_000;
const ROLE_LABEL = { owner: 'Owner', moderator: 'Moderator' };
const WIDE_PANEL = '(min-width: 1280px)';

let localSeq = 0;

function Text({ body, query }) {
  return highlightParts(body, query).map((part, index) => (part.hit ? <mark key={index}>{part.text}</mark> : <span key={index}>{part.text}</span>));
}

/** Incoming changes into the list: replace what we have, add what is new, keep the order. */
export const mergeChanges = (current, incoming) => {
  if (!incoming.length) return current;
  const list = [...current];
  const index = new Map(list.map((m, i) => [m.messageId, i]));
  const oldest = list.find((m) => !m.local)?.createdAt ?? null;
  for (const message of incoming) {
    if (index.has(message.messageId)) list[index.get(message.messageId)] = message;
    else if (!oldest || message.createdAt >= oldest) {
      list.push(message);
      index.set(message.messageId, list.length - 1);
    }
  }
  return list.sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0));
};

function MembersPanel({ hub, space, selfUserId, onOpenProfile }) {
  const [members, setMembers] = useState(null);
  useEffect(() => {
    const controller = new AbortController();
    hub
      .members(space.spaceId, controller.signal)
      .then(setMembers)
      .catch(() => !controller.signal.aborted && setMembers({ listVisible: false, count: space.memberCount ?? 0, items: [] }));
    return () => controller.abort();
  }, [hub, space.spaceId, space.memberCount]);
  if (!members) return <p className="sc-muted">Loading…</p>;
  const order = { owner: 0, moderator: 1 };
  const items = [...members.items].sort((a, b) => (order[a.role] ?? 2) - (order[b.role] ?? 2) || a.displayName.localeCompare(b.displayName));
  return (
    <div className="sc-members">
      <p className="sc-members__count">
        <strong>{members.count}</strong> {members.count === 1 ? 'member' : 'members'}
      </p>
      {!members.listVisible ? <p className="sc-muted">Only moderators see who is in this space.</p> : null}
      <ul>
        {items.map((member) => (
          <li key={member.userId}>
            <button type="button" onClick={() => onOpenProfile({ userId: member.userId, displayName: member.displayName })}>
              <Avatar name={member.displayName} seed={member.userId} size={36} />
              <span className="sc-members__name">
                {member.displayName}
                {member.userId === selfUserId || member.you ? <span className="sc-muted"> (you)</span> : null}
              </span>
              {ROLE_LABEL[member.role] ? <span className={`sc-role sc-role--${member.role}`}>{ROLE_LABEL[member.role]}</span> : null}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default function SpaceChat({ hub, space }) {
  const core = useCore();
  const { http, session } = core;
  const navigate = useNavigate();
  const files = useMemo(() => createFilesApi(http), [http]);
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const chatApi = useMemo(() => createChatApi(http), [http]);
  const selfUserId = session?.userId ?? '';

  const [items, setItems] = useState(null);
  const [state, setState] = useState({ blocked: null, calmSeconds: 0, canModerate: false, editWindowMin: 15 });
  const [replyTo, setReplyTo] = useState(null);
  const [editing, setEditing] = useState(null);
  const [editError, setEditError] = useState(null);
  const [pickerFor, setPickerFor] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [profileOf, setProfileOf] = useState(null);
  const [notice, setNotice] = useState(null);
  const [searchOpen, setSearchOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [hitIndex, setHitIndex] = useState(0);
  const [panel, setPanel] = useState(() => (typeof window !== 'undefined' && window.matchMedia?.(WIDE_PANEL).matches ? 'members' : null));
  const cursor = useRef(null);
  const busy = useRef(false);
  const listRef = useRef(null);
  const rootRef = useRef(null);
  const nearBottom = useRef(true);
  const noticeTimer = useRef(null);
  const composerRef = useRef(null);
  const editRef = useRef(null);

  const say = (text) => {
    window.clearTimeout(noticeTimer.current);
    setNotice(text);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 3500);
  };
  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);

  // Fill the window below the space's header and tabs.
  useLayoutEffect(() => {
    const fit = () => {
      const el = rootRef.current;
      if (el) el.style.setProperty('--sc-top', `${Math.max(0, Math.round(el.getBoundingClientRect().top + window.scrollY))}px`);
    };
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  const fetchChanges = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    try {
      const page = await hub.chat(space.spaceId, cursor.current);
      setItems((current) => (cursor.current === null || current === null ? page.items : mergeChanges(current, page.items)));
      cursor.current = page.nextCursor ?? cursor.current;
      setState({ blocked: page.postingBlocked, calmSeconds: page.calmSeconds ?? 0, canModerate: Boolean(page.canModerate), editWindowMin: page.editWindowMin ?? 15 });
    } catch {
      setItems((current) => current ?? []);
    } finally {
      busy.current = false;
    }
  }, [hub, space.spaceId]);

  // The live signal needs the core; a new core object must not restart the chat.
  const coreRef = useRef(core);
  coreRef.current = core;

  useEffect(() => {
    cursor.current = null;
    setItems(null);
    fetchChanges();
    const timer = window.setInterval(() => document.visibilityState === 'visible' && fetchChanges(), POLL_MS);
    const off = onUserEvent(coreRef.current, 'hub:chat', (payload) => {
      if (!payload?.spaceId || payload.spaceId === space.spaceId) fetchChanges();
    });
    return () => {
      window.clearInterval(timer);
      off();
    };
  }, [fetchChanges, space.spaceId]);

  useLayoutEffect(() => {
    const list = listRef.current;
    if (list && nearBottom.current) list.scrollTop = list.scrollHeight;
  }, [items?.length]);
  const onScroll = () => {
    const list = listRef.current;
    if (list) nearBottom.current = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
  };

  const messages = items ?? [];
  const byId = useMemo(() => new Map(messages.map((m) => [m.messageId, m])), [messages]);
  const rows = useMemo(
    () => threadRows(messages.map((m) => ({ ...m, author: { ...m.author, userId: m.author.userId } }))),
    [messages],
  );
  const hits = useMemo(() => searchHits(messages, searchOpen ? search : ''), [messages, search, searchOpen]);
  useEffect(() => setHitIndex(Math.max(0, hits.length - 1)), [search]); // eslint-disable-line react-hooks/exhaustive-deps
  const activeHit = hits.length ? hits[Math.min(hitIndex, hits.length - 1)] : null;
  useEffect(() => {
    if (!activeHit) return;
    nearBottom.current = false;
    listRef.current?.querySelector(`[data-message-id="${CSS.escape(activeHit)}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }, [activeHit]);

  const replace = (message) => setItems((current) => (current ?? []).map((m) => (m.messageId === message.messageId ? { ...m, ...message } : m)));

  const send = async ({ body, files: ready, voice }) => {
    nearBottom.current = true;
    const reply = replyTo;
    setReplyTo(null);
    const localId = `local-${(localSeq += 1)}`;
    const optimistic = {
      messageId: localId, local: true, sending: true, body,
      author: { userId: selfUserId, displayName: session?.displayName ?? 'You', you: true },
      createdAt: new Date().toISOString(), files: ready.map((f) => ({ ...f, voice: Boolean(voice), durationMs: voice?.durationMs ?? null })),
      reactions: [], replyToId: reply?.messageId ?? null,
    };
    setItems((current) => [...(current ?? []), optimistic]);
    try {
      const saved = await hub.sendChat(space.spaceId, { body, fileIds: ready.map((f) => f.fileId), ...(voice ? { voice } : {}), ...(reply ? { replyToId: reply.messageId } : {}) });
      setItems((current) => mergeChanges((current ?? []).filter((m) => m.messageId !== localId), [saved]));
    } catch (cause) {
      setItems((current) => (current ?? []).filter((m) => m.messageId !== localId));
      throw cause;
    }
  };

  const startEdit = (message) => {
    setEditError(null);
    setEditing({ messageId: message.messageId, text: message.body });
    window.requestAnimationFrame(() => editRef.current?.focus());
  };
  const saveEdit = async () => {
    const text = editing.text.trim();
    if (!text) return setEditError('A message cannot be empty. Delete it instead.');
    if (text === byId.get(editing.messageId)?.body) return setEditing(null);
    try {
      replace(await hub.editChat(editing.messageId, text));
      setEditing(null);
    } catch (cause) {
      setEditError(cause?.detail ?? 'The change was not saved.');
    }
    return undefined;
  };

  const toggleReaction = async (message, emoji) => {
    try {
      const result = await hub.reactChat(message.messageId, { emoji, action: toggleAction(message.reactions, emoji) });
      setItems((current) =>
        (current ?? []).map((m) => {
          if (m.messageId !== message.messageId) return m;
          const others = (m.reactions ?? []).filter((r) => r.emoji !== emoji);
          if (!result.count) return { ...m, reactions: others };
          const position = (m.reactions ?? []).findIndex((r) => r.emoji === emoji);
          const next = [...others];
          next.splice(position === -1 ? next.length : position, 0, { emoji, count: result.count, reacted: result.reacted, names: result.names ?? [] });
          return { ...m, reactions: next };
        }),
      );
    } catch (cause) {
      say(cause?.detail ?? 'The reaction was not saved.');
    }
  };

  const remove = async (message) => {
    const result = await hub.removeChat(message.messageId);
    replace({ messageId: message.messageId, body: '', files: [], reactions: [], deletedAt: new Date().toISOString(), deletedBy: result?.as ?? message.removeAs, canRemove: false, canEdit: false });
  };

  const copy = async (message) => {
    try {
      await navigator.clipboard.writeText(message.body);
      say('Copied.');
    } catch {
      say('Copying is not allowed in this browser.');
    }
  };

  const messagePrivately = async (person) => {
    const conversation = await chatApi.openDirect(person.userId);
    navigate(`/messages/${conversation.conversationId}`);
  };

  const lastEditable = () => [...messages].reverse().find((m) => m.canEdit && m.author.userId === selfUserId) ?? null;
  const mediaApi = useMemo(() => ({ media: (id, query, signal) => hub.chatMedia(id, query, signal) }), [hub]);

  return (
    <div className={`sc${panel ? ' has-panel' : ''}`} ref={rootRef}>
      <section className="sc-chat" aria-label={`Chat of ${space.name}`}>
        <header className="sc-head">
          <div className="sc-head__who">
            <strong>Chat</strong>
            <button type="button" className="sc-head__count" onClick={() => setPanel(panel === 'members' ? null : 'members')}>
              {space.memberCount ?? '…'} {space.memberCount === 1 ? 'member' : 'members'}
            </button>
            {state.calmSeconds > 0 ? <span className="sc-calm">🌿 {calmLabel(state.calmSeconds)}</span> : null}
          </div>
          <div className="sc-head__actions">
            {state.canModerate ? (
              <select
                className="sc-select"
                value={state.calmSeconds}
                aria-label="Calm mode for the chat"
                onChange={async (event) => {
                  const seconds = Number(event.target.value);
                  await hub.setChatCalm(space.spaceId, seconds).catch(() => undefined);
                  setState((current) => ({ ...current, calmSeconds: seconds }));
                }}
              >
                {CALM_CHOICES.map((choice) => (
                  <option key={choice.seconds} value={choice.seconds}>
                    {choice.seconds ? `Calm: ${choice.label}` : 'Calm mode off'}
                  </option>
                ))}
              </select>
            ) : null}
            <button type="button" className={`sc-iconbtn${searchOpen ? ' is-on' : ''}`} onClick={() => (setSearchOpen((v) => !v), setSearch(''))} aria-label="Search in this chat" title="Search in this chat">⌕</button>
            <button type="button" className={`sc-iconbtn${panel === 'members' ? ' is-on' : ''}`} onClick={() => setPanel(panel === 'members' ? null : 'members')} aria-label="Members" title="Members">👥</button>
            <button type="button" className={`sc-iconbtn${panel === 'shared' ? ' is-on' : ''}`} onClick={() => setPanel(panel === 'shared' ? null : 'shared')} aria-label="Shared in this chat" title="Media, files and voice">🖼</button>
          </div>
        </header>

        {searchOpen ? (
          <div className="sc-findbar" role="search">
            <input
              type="search"
              autoFocus
              placeholder="Search in this chat"
              aria-label="Search in this chat"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter') setHitIndex((i) => (event.shiftKey ? Math.min(hits.length - 1, i + 1) : Math.max(0, i - 1)));
                if (event.key === 'Escape') (setSearchOpen(false), setSearch(''));
              }}
            />
            <span className="sc-muted">{search.trim() ? (hits.length ? `${Math.min(hitIndex, hits.length - 1) + 1} of ${hits.length}` : 'No results') : ''}</span>
          </div>
        ) : null}

        <div className="sc-messages" ref={listRef} onScroll={onScroll} data-ck-dropzone>
          <div className="sc-messages__inner">
            {items === null ? <p className="sc-muted sc-center">Loading…</p> : null}
            {items?.length === 0 ? (
              <div className="sc-start">
                <Avatar name={space.name} seed={space.spaceId} size={64} />
                <p className="sc-start__title">Welcome to the chat of {space.name}</p>
                <p className="sc-muted">Say hello, share a picture or ask something quick. Longer questions fit better in Threads.</p>
              </div>
            ) : null}
            {rows.map((row) => {
              if (row.type === 'day') return <div key={row.key} className="sc-day" role="separator"><span>{dayLabel(row.at, new Date(), formatDate)}</span></div>;
              const { message, firstInGroup, lastInGroup } = row;
              const mine = message.author.userId === selfUserId;
              const reply = message.replyToId ? byId.get(message.replyToId) : null;
              const isEditing = editing?.messageId === message.messageId;
              return (
                <div key={row.key} data-message-id={message.messageId} className={['sc-msg', mine ? 'is-mine' : 'is-theirs', firstInGroup ? 'is-first' : '', lastInGroup ? 'is-last' : '', message.sending ? 'is-sending' : '', activeHit === message.messageId ? 'is-hit' : ''].filter(Boolean).join(' ')}>
                  {!mine ? (
                    <span className="sc-msg__gutter">
                      {lastInGroup ? (
                        <button type="button" className="sc-avatarbtn" onClick={() => setProfileOf(message.author)} aria-label={`Profile of ${message.author.displayName}`}>
                          <Avatar name={message.author.displayName} seed={message.author.userId} size={32} />
                        </button>
                      ) : null}
                    </span>
                  ) : null}
                  <div className="sc-msg__col">
                    {!mine && firstInGroup ? (
                      <button type="button" className="sc-msg__author" onClick={() => setProfileOf(message.author)}>{message.author.displayName}</button>
                    ) : null}
                    <div className="sc-msg__line">
                      <div className="sc-bubble">
                        {message.replyToId ? (
                          <span className="sc-quote">
                            <strong>{reply ? (reply.author.userId === selfUserId ? 'You' : reply.author.displayName) : 'Reply'}</strong>
                            <span>{reply ? (reply.deletedAt ? 'Message deleted' : snippet(reply.body) || filesLabel(reply.files)) : 'to an earlier message'}</span>
                          </span>
                        ) : null}
                        {isEditing ? (
                          <form className="sc-edit" onSubmit={(event) => (event.preventDefault(), saveEdit())}>
                            <textarea
                              ref={editRef}
                              rows={2}
                              aria-label="Edit message"
                              value={editing.text}
                              maxLength={2000}
                              onChange={(event) => setEditing({ ...editing, text: event.target.value })}
                              onKeyDown={(event) => {
                                if (event.key === 'Enter' && !event.shiftKey) (event.preventDefault(), saveEdit());
                                if (event.key === 'Escape') (event.stopPropagation(), setEditing(null));
                              }}
                            />
                            <span className="sc-edit__hint">Enter to save · Esc to cancel</span>
                            {editError ? <span className="sc-error">{editError}</span> : null}
                          </form>
                        ) : message.deletedAt ? (
                          <em className="sc-deleted">{message.deletedBy === 'moderator' ? 'Removed by a moderator' : 'This message was deleted'}</em>
                        ) : (
                          <>
                            <MessageFiles files={message.files ?? []} mine={mine} />
                            {message.body ? <span className="sc-bubble__text"><Text body={message.body} query={searchOpen ? search : ''} /></span> : null}
                          </>
                        )}
                        {!isEditing ? (
                          <span className="sc-bubble__meta">
                            {message.editedAt && !message.deletedAt ? 'edited · ' : ''}
                            {message.sending ? 'Sending…' : formatTime(new Date(message.createdAt))}
                          </span>
                        ) : null}
                      </div>
                      {pickerFor === message.messageId ? <ReactionPicker align={mine ? 'end' : 'start'} onPick={(emoji) => toggleReaction(message, emoji)} onClose={() => setPickerFor(null)} /> : null}
                      {!message.deletedAt && !message.local && !isEditing ? (
                        <span className="sc-actions" role="toolbar" aria-label="Message actions">
                          <button type="button" onClick={() => setPickerFor(message.messageId)} aria-label="React" title="React">☺</button>
                          <button type="button" onClick={() => (setReplyTo(message), composerRef.current?.focus())} aria-label="Reply" title="Reply">↩</button>
                          {message.canEdit && mine ? <button type="button" onClick={() => startEdit(message)} aria-label="Edit" title="Edit">✎</button> : null}
                          {message.body ? <button type="button" onClick={() => copy(message)} aria-label="Copy text" title="Copy text">⧉</button> : null}
                          {message.removeAs ? (
                            <button type="button" className="is-danger" onClick={() => setConfirm(message)} aria-label={message.removeAs === 'moderator' ? 'Remove as moderator' : 'Delete'} title={message.removeAs === 'moderator' ? 'Remove as moderator' : 'Delete'}>🗑</button>
                          ) : null}
                        </span>
                      ) : null}
                    </div>
                    {!message.deletedAt ? <ReactionChips reactions={message.reactions ?? []} mine={mine} onToggle={(emoji) => toggleReaction(message, emoji)} /> : null}
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {notice ? <p className="sc-toast" role="status">{notice}</p> : null}

        <div className="sc-composer">
          <Composer
            files={files}
            inputRef={composerRef}
            placeholder={`Message ${space.name}`}
            disabled={Boolean(state.blocked)}
            disabledReason={state.blocked ?? ''}
            onSend={send}
            onArrowUp={() => {
              const last = lastEditable();
              if (last) startEdit(last);
              return Boolean(last);
            }}
            onEscape={() => setReplyTo(null)}
            top={
              replyTo ? (
                <div className="sc-replychip">
                  <span>
                    <strong>Replying to {replyTo.author.userId === selfUserId ? 'yourself' : replyTo.author.displayName}</strong>
                    <span>{snippet(replyTo.body) || filesLabel(replyTo.files)}</span>
                  </span>
                  <button type="button" className="sc-iconbtn" onClick={() => setReplyTo(null)} aria-label="Cancel reply">×</button>
                </div>
              ) : null
            }
            below={(draft, clear) =>
              state.blocked ? null : (
                <div className="sc-nudge">
                  <LateNightNudge hub={hub} build={() => (draft.trim() ? { kind: 'chat', targetId: space.spaceId, body: draft.trim() } : null)} onScheduled={clear} />
                </div>
              )
            }
          />
        </div>
      </section>

      {panel ? (
        <>
          <button type="button" className="sc-scrim" aria-label="Close panel" onClick={() => setPanel(null)} />
          <aside className="sc-panel" aria-label={panel === 'members' ? 'Members' : 'Shared in this chat'}>
            <div className="sc-panel__tabs" role="tablist">
              <button type="button" role="tab" aria-selected={panel === 'members'} className={panel === 'members' ? 'is-on' : ''} onClick={() => setPanel('members')}>Members</button>
              <button type="button" role="tab" aria-selected={panel === 'shared'} className={panel === 'shared' ? 'is-on' : ''} onClick={() => setPanel('shared')}>Shared</button>
              <button type="button" className="sc-iconbtn" onClick={() => setPanel(null)} aria-label="Close panel">×</button>
            </div>
            <div className="sc-panel__body">
              {panel === 'members' ? <MembersPanel hub={hub} space={space} selfUserId={selfUserId} onOpenProfile={setProfileOf} /> : <SharedMedia api={mediaApi} conversationId={space.spaceId} refreshKey={messages.length} />}
            </div>
          </aside>
        </>
      ) : null}

      {confirm ? (
        <ConfirmDialog
          title={confirm.removeAs === 'moderator' ? `Remove ${confirm.author.displayName}'s message?` : 'Delete this message?'}
          body={
            confirm.removeAs === 'moderator'
              ? 'Everyone sees “Removed by a moderator” instead. The removal is noted in the space’s log.'
              : 'It is removed for everyone, with its files, and shows as “This message was deleted”.'
          }
          confirmLabel={confirm.removeAs === 'moderator' ? 'Remove' : 'Delete for everyone'}
          danger
          onConfirm={() => remove(confirm)}
          onClose={() => setConfirm(null)}
        />
      ) : null}
      {profileOf ? <ProfileDialog person={profileOf} profiles={profiles} selfUserId={selfUserId} onMessage={messagePrivately} onClose={() => setProfileOf(null)} /> : null}
    </div>
  );
}
__CC_EOF__
echo "wrote apps/web/src/components/Hub/SpaceChat.jsx"
mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/spaceChat.css <<'__CC_EOF__'
/* The chat of a space — see components/Hub/SpaceChat.jsx.
   Same look as Messages; colours from the app's variables (styles/theme.css). */

.sc {
  --sc-line: var(--color-border, #dbe4e1);
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 16px;
  height: calc(100dvh - var(--sc-top, 260px) - 20px);
  min-height: 460px;
}
.sc.has-panel { grid-template-columns: minmax(0, 1fr) 320px; }
.sc-muted { color: var(--color-muted, #5d6f73); }
.sc-error { color: var(--color-danger, #c93636); font-size: 13px; }
.sc-center { text-align: center; }
.sc mark { background: var(--app-sun, #ffd54a); color: var(--app-sun-ink, #2a2206); border-radius: 3px; padding: 0 1px; }

.sc-chat {
  position: relative; display: flex; flex-direction: column; min-width: 0; min-height: 0; border-radius: 20px; overflow: hidden;
  background: var(--color-surface, #fff); border: 1px solid var(--sc-line); box-shadow: var(--app-shadow, 0 10px 30px -18px rgba(20, 38, 43, 0.22));
}

/* ---------------------------------------------------------------- header */
.sc-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 14px 12px 20px; border-bottom: 1px solid var(--sc-line); min-height: 60px; box-sizing: border-box; }
.sc-head__who { display: flex; align-items: center; gap: 12px; min-width: 0; flex-wrap: wrap; }
.sc-head__who strong { font-size: 17px; }
.sc-head__count { border: 0; background: var(--color-surface-2, #f1f5f4); color: var(--color-text, #15272c); font: inherit; font-size: 13.5px; font-weight: 700; padding: 5px 12px; border-radius: 999px; cursor: pointer; }
.sc-head__count:hover { background: rgba(47, 99, 214, 0.1); color: var(--color-accent, #2f63d6); }
.sc-calm { font-size: 13px; color: var(--color-live, #1e9a77); font-weight: 700; }
.sc-head__actions { display: flex; align-items: center; gap: 4px; }
.sc-select { padding: 7px 10px; border-radius: 10px; border: 1px solid var(--sc-line); font: inherit; font-size: 13.5px; margin-right: 6px; }
.sc-iconbtn { display: inline-grid; place-items: center; width: 38px; height: 38px; border: 0; border-radius: 10px; background: transparent; color: var(--color-text, #15272c); font-size: 18px; line-height: 1; cursor: pointer; }
.sc-iconbtn:hover, .sc-iconbtn.is-on { background: var(--color-surface-2, #f1f5f4); }
.sc-iconbtn.is-on { box-shadow: inset 0 0 0 1px rgba(47, 99, 214, 0.35); }
.sc-findbar { display: flex; align-items: center; gap: 10px; padding: 8px 14px; border-bottom: 1px solid var(--sc-line); }
.sc-findbar input { flex: 1; padding: 8px 12px; border-radius: 10px; border: 1px solid var(--sc-line); font: inherit; font-size: 14.5px; }

/* ---------------------------------------------------------------- messages */
.sc-messages { flex: 1; min-height: 0; overflow-y: auto; overscroll-behavior: contain; background: linear-gradient(180deg, var(--color-surface-2, #f1f5f4), #f7faf9); }
.sc-messages__inner { display: flex; flex-direction: column; gap: 2px; max-width: 980px; margin: 0 auto; padding: 18px 24px 12px; }
.sc-start { display: grid; justify-items: center; gap: 6px; padding: 40px 12px; text-align: center; }
.sc-start p { margin: 0; max-width: 46ch; }
.sc-start__title { font-weight: 700; font-size: 18px; margin-top: 6px !important; }
.sc-day { display: flex; justify-content: center; margin: 14px 0 8px; position: sticky; top: 6px; z-index: 1; }
.sc-day span { padding: 4px 12px; border-radius: 999px; background: rgba(255, 255, 255, 0.95); border: 1px solid var(--sc-line); font-size: 12.5px; font-weight: 700; color: var(--color-muted, #5d6f73); }

.sc-msg { display: flex; gap: 8px; align-items: flex-end; }
.sc-msg.is-first { margin-top: 10px; }
.sc-msg.is-mine { justify-content: flex-end; }
.sc-msg__gutter { width: 32px; flex: 0 0 32px; }
.sc-avatarbtn { padding: 0; border: 0; background: none; border-radius: 50%; cursor: pointer; }
.sc-msg__col { display: flex; flex-direction: column; min-width: 0; max-width: min(72%, 640px); }
.sc-msg.is-mine .sc-msg__col { align-items: flex-end; }
.sc-msg__author { align-self: flex-start; margin: 0 0 3px 12px; padding: 0; border: 0; background: none; font: inherit; font-size: 13px; font-weight: 700; color: hsl(210 45% 35%); cursor: pointer; }
.sc-msg__author:hover { text-decoration: underline; }
.sc-msg__line { position: relative; display: flex; align-items: center; gap: 6px; max-width: 100%; }
.sc-msg.is-mine .sc-msg__line { flex-direction: row-reverse; }

.sc-bubble { display: grid; gap: 4px; min-width: 64px; max-width: 100%; padding: 8px 12px 6px; border-radius: 18px; background: #fff; color: var(--color-text, #15272c); box-shadow: 0 1px 1px rgba(20, 38, 43, 0.08); overflow-wrap: anywhere; }
.sc-msg.is-theirs:not(.is-last) .sc-bubble { border-bottom-left-radius: 6px; }
.sc-msg.is-theirs:not(.is-first) .sc-bubble { border-top-left-radius: 6px; }
.sc-msg.is-mine .sc-bubble { background: var(--color-accent, #2f63d6); color: #fff; }
.sc-msg.is-mine:not(.is-last) .sc-bubble { border-bottom-right-radius: 6px; }
.sc-msg.is-mine:not(.is-first) .sc-bubble { border-top-right-radius: 6px; }
.sc-msg.is-sending .sc-bubble { opacity: 0.7; }
.sc-msg.is-hit .sc-bubble { box-shadow: 0 0 0 3px var(--app-sun, #ffd54a); }
.sc-bubble__text { white-space: pre-wrap; font-size: 15px; line-height: 1.45; }
.sc-bubble__meta { justify-self: end; font-size: 11.5px; opacity: 0.7; white-space: nowrap; }
.sc-deleted { opacity: 0.7; font-size: 14px; }
.sc-quote { display: grid; gap: 1px; padding: 6px 10px; border-left: 3px solid currentColor; border-radius: 8px; background: rgba(20, 38, 43, 0.06); font-size: 13px; }
.sc-msg.is-mine .sc-quote { background: rgba(255, 255, 255, 0.18); }
.sc-quote span { opacity: 0.85; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.sc-actions { display: inline-flex; gap: 2px; padding: 2px; border-radius: 10px; background: #fff; border: 1px solid var(--sc-line); box-shadow: 0 4px 12px -8px rgba(20, 38, 43, 0.4); opacity: 0; transition: opacity 0.15s ease; }
.sc-actions button { width: 30px; height: 30px; border: 0; border-radius: 8px; background: none; color: var(--color-text, #15272c); font-size: 14px; cursor: pointer; }
.sc-actions button:hover { background: var(--color-surface-2, #f1f5f4); }
.sc-actions button.is-danger:hover { background: #fdecec; }
.sc-msg:hover .sc-actions, .sc-msg:focus-within .sc-actions { opacity: 1; }
@media (hover: none) { .sc-actions { opacity: 0.9; } }

.sc-edit { display: grid; gap: 4px; min-width: min(420px, 60vw); }
.sc-edit textarea { width: 100%; box-sizing: border-box; resize: none; border: 0; border-radius: 10px; padding: 6px 8px; font: inherit; font-size: 15px; background: #fff; color: var(--color-text, #15272c); }
.sc-edit__hint { font-size: 12px; opacity: 0.85; }
.sc-toast { position: absolute; left: 50%; bottom: 110px; transform: translateX(-50%); z-index: 5; margin: 0; padding: 8px 14px; border-radius: 10px; background: var(--color-text, #15272c); color: #fff; font-size: 13.5px; }

/* ---------------------------------------------------------------- composer */
.sc-composer { padding: 10px 24px 12px; border-top: 1px solid var(--sc-line); background: var(--color-surface, #fff); }
.sc-composer > * { max-width: 980px; margin: 0 auto; }
.sc-replychip { display: flex; align-items: center; gap: 8px; padding: 6px 6px 6px 12px; border-left: 3px solid var(--color-accent, #2f63d6); border-radius: 10px; background: var(--color-surface-2, #f1f5f4); }
.sc-replychip > span { display: grid; flex: 1; min-width: 0; font-size: 13px; }
.sc-replychip > span span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--color-muted, #5d6f73); }
.sc-nudge:empty { display: none; }

/* ---------------------------------------------------------------- side panel */
.sc-panel { display: flex; flex-direction: column; min-height: 0; border-radius: 20px; background: var(--color-surface, #fff); border: 1px solid var(--sc-line); box-shadow: var(--app-shadow, none); overflow: hidden; }
.sc-panel__tabs { display: flex; align-items: center; gap: 4px; padding: 10px; border-bottom: 1px solid var(--sc-line); }
.sc-panel__tabs [role='tab'] { flex: 1; padding: 8px 6px; border: 0; border-radius: 10px; background: none; font: inherit; font-size: 14px; font-weight: 700; color: var(--color-muted, #5d6f73); cursor: pointer; }
.sc-panel__tabs [role='tab'].is-on { background: var(--color-surface-2, #f1f5f4); color: var(--color-text, #15272c); }
.sc-panel__body { flex: 1; min-height: 0; overflow-y: auto; padding: 14px 16px; }
.sc-scrim { display: none; }
.sc-members { display: grid; gap: 10px; }
.sc-members__count { margin: 0; font-size: 14px; color: var(--color-muted, #5d6f73); }
.sc-members__count strong { color: var(--color-text, #15272c); font-size: 18px; }
.sc-members ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
.sc-members button { display: flex; align-items: center; gap: 10px; width: 100%; padding: 7px 8px; border: 0; border-radius: 12px; background: none; font: inherit; text-align: left; color: var(--color-text, #15272c); cursor: pointer; }
.sc-members button:hover { background: var(--color-surface-2, #f1f5f4); }
.sc-members__name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14.5px; }
.sc-role { padding: 2px 8px; border-radius: 999px; font-size: 11.5px; font-weight: 700; background: var(--color-surface-2, #f1f5f4); color: var(--color-muted, #5d6f73); }
.sc-role--owner { background: var(--app-sun-soft, #fff3c4); color: var(--app-sun-ink, #2a2206); }
.sc-role--moderator { background: rgba(30, 154, 119, 0.12); color: var(--color-live, #1e9a77); }

@media (max-width: 1279px) {
  .sc.has-panel { grid-template-columns: minmax(0, 1fr); }
  .sc.has-panel .sc-scrim { display: block; position: fixed; inset: 0; z-index: 64; border: 0; background: rgba(20, 38, 43, 0.3); cursor: pointer; }
  .sc.has-panel .sc-panel { position: fixed; z-index: 65; top: 0; right: 0; bottom: 0; width: min(380px, 92vw); border-radius: 20px 0 0 20px; }
}
@media (max-width: 700px) {
  .sc { height: calc(100dvh - var(--sc-top, 200px) - 10px); }
  .sc-messages__inner, .sc-composer { padding-left: 10px; padding-right: 10px; }
  .sc-msg__col { max-width: 86%; }
  .sc-select { display: none; }
}
__CC_EOF__
echo "wrote apps/web/src/components/Hub/spaceChat.css"
mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/hubWide.css <<'__CC_EOF__'
/* Community across the whole width  (Community)
 *
 * The rail of places and spaces on the left, the open space filling the rest
 * — no fixed 1180 px column with empty margins. Long reading (threads, forms,
 * about) keeps a comfortable line length inside it.
 */

.app .app__content:has(.hb) { max-width: none; padding: 20px 28px 24px; }

.hb {
  max-width: none;
  grid-template-columns: 264px minmax(0, 1fr);
  gap: 28px;
}
@media (min-width: 1600px) { .hb { grid-template-columns: 288px minmax(0, 1fr); gap: 36px; } }
@media (max-width: 900px) {
  .app .app__content:has(.hb) { padding: 14px 14px 20px; }
  .hb { grid-template-columns: minmax(0, 1fr); gap: 14px; }
}

.hb-rail { top: 20px; max-height: calc(100dvh - 110px); overflow-y: auto; padding-right: 4px; }
.hb-rail__spaces a, .hb-rail__places a { border-radius: 12px; }

/* The space: header and tabs across the width. */
.hb-space { min-width: 0; }
.hb-space__head { gap: 18px; }
.hb-tabs { overflow-x: auto; scrollbar-width: none; }
.hb-tabs::-webkit-scrollbar { display: none; }

/* Reading-heavy views keep a calm measure. */
.hb-thread, .hb-about, .hb-form { max-width: 880px; }
.hb-list { max-width: 1100px; }
__CC_EOF__
echo "wrote apps/web/src/components/Hub/hubWide.css"

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
# Stylesheets: balanced, complete, and as many rules as expected.
cat > .chat-community-css.mjs <<'__CSS_EOF__'
import { readFileSync } from 'node:fs';
const expected = { 'messenger.css': 190, 'spaceChat.css': 85, 'hubWide.css': 10 };
let ok = true;
for (const file of process.argv.slice(2)) {
  const text = readFileSync(file, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
  const open = (text.match(/{/g) ?? []).length;
  const close = (text.match(/}/g) ?? []).length;
  const name = file.split('/').pop();
  const min = expected[name] ?? 1;
  if (open !== close || open < min) {
    console.error(`${file}: ${open} opening and ${close} closing braces (need at least ${min}).`);
    ok = false;
  } else console.log(`ok  ${file} (${open} blocks)`);
}
process.exit(ok ? 0 : 1);
__CSS_EOF__
node .chat-community-css.mjs apps/web/src/components/Messenger/messenger.css apps/web/src/components/Hub/spaceChat.css apps/web/src/components/Hub/hubWide.css || restore_and_exit "A stylesheet is incomplete."
rm -f .chat-community-css.mjs
FAILED=0
for f in "${TOUCHED[@]}"; do
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
  esac
done
[ "$FAILED" -eq 0 ] || restore_and_exit "A file did not pass its check (see above)."

echo "--- rule tests (node --test)"
CHECKS=$(find server/test apps/web/src -name '*.check.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
if node --test $CHECKS > .chat-community-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .chat-community-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .chat-community-test.log
else
  cat .chat-community-test.log
  rm -f .chat-community-test.log
  restore_and_exit "The rule tests failed (see above)."
fi

echo "--- database (migration 033)"
if SERVICE_ROLE=api npm run db:migrate >/tmp/chat-community-migrate.log 2>&1; then
  echo "ok  migration 033 applied"
else
  tail -5 /tmp/chat-community-migrate.log
  echo
  echo "The files are installed, but the database did not answer, so 033 is not applied yet."
  echo "Once your services run (./dev-up.sh), apply it with:  SERVICE_ROLE=api npm run db:migrate"
  exit 1
fi

echo
echo "Done. Nothing was started; the API and Vite reload on their own."
echo "Reload the browser with Ctrl+Shift+R, then open Messages and a space in Community."