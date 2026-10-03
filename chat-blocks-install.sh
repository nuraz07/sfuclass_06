#!/usr/bin/env bash
# chat-blocks-install.sh — step 1: the chat's building blocks, in Messages.
#
#   reactions   emoji on any message: quick six or the full picker; counts,
#               who reacted, live for everyone
#   files       📎, drag-and-drop or paste: pictures, videos, documents, through
#               the normal upload checks; pictures open large
#   voice       record with 🎤, send or cancel; play with a progress bar
#   shared      the details panel shows Media · Files · Voice of the chat
#
# The building blocks live in components/ChatKit/ so the community chat
# (step 2) uses exactly the same code. The lesson chat is not changed.
#
# Run from the project folder:   bash chat-blocks-install.sh
# Needs messages-install.sh to have run first. Writes 17 files, patches 8,
# backs everything up in .chat-blocks-backup/<time>/, checks every file, runs
# the rule tests and applies migration 032 if the database is reachable.
# No container is started, stopped or pulled.
# Undo: bash chat-blocks-install.sh --restore   (the two new tables stay; unused)
set -euo pipefail

if [ ! -f apps/web/src/components/Messenger/MessengerThread.jsx ] || [ ! -f server/src/files/FileService.js ]; then
  echo "Run this from the project folder, after messages-install.sh (and the Materials uploads)." >&2
  exit 1
fi
command -v node >/dev/null || { echo "node is required." >&2; exit 1; }
if ls server/src/db/migrations/032_*.sql 2>/dev/null | grep -qv 032_chat_reactions_files.sql; then
  echo "Another migration 032 exists: $(ls server/src/db/migrations/032_*.sql | tr '\n' ' '). Nothing was changed." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/032_chat_reactions_files.sql
  server/src/messaging/chatExtrasRules.js
  server/src/messaging/ChatExtras.js
  server/test/messaging/chatExtrasRules.check.mjs
  apps/web/src/components/ChatKit/chatKitModel.js
  apps/web/src/components/ChatKit/Reactions.jsx
  apps/web/src/components/ChatKit/MessageFiles.jsx
  apps/web/src/components/ChatKit/Composer.jsx
  apps/web/src/components/ChatKit/chatkit.css
  apps/web/src/components/ChatKit/__checks__/chatKitModel.check.mjs
  apps/web/src/components/Messenger/SharedMedia.jsx
  apps/web/src/components/Messenger/MessengerThread.jsx
  apps/web/src/components/Messenger/MessengerList.jsx
  apps/web/src/components/Messenger/ContactPanel.jsx
  apps/web/src/components/Messenger/messengerModel.js
  apps/web/src/components/Messenger/messenger.css
  apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs
  server/src/messaging/DirectMessageService.js
  server/src/messaging/chatGateway.js
  server/src/routes/messaging.routes.js
  server/src/files/FileService.js
  server/src/files/fileRules.js
  packages/contracts/src/zod/chat.schema.ts
  packages/core-client/src/api/chatApi.ts
  packages/core-client/src/state/useChat.ts
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .chat-blocks-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/032_chat_reactions_files.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  rmdir apps/web/src/components/ChatKit/__checks__ apps/web/src/components/ChatKit 2>/dev/null || true
  echo "Restored from $FIRST. Migration 032 stays, because the database may already have it."
  exit 0
fi

BACKUP=".chat-blocks-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

restore_and_exit() {
  for f in "${TOUCHED[@]}"; do
    if [ -f "$BACKUP/$f" ]; then cp "$BACKUP/$f" "$f"; elif [ -f "$f" ]; then rm "$f"; fi
  done
  rm -f .chat-blocks-patch.mjs
  echo "$1 Every file was put back as it was." >&2
  exit 1
}

echo "--- patching existing files"
cat > .chat-blocks-patch.mjs <<'__CHAT_EOF__'
// Patches existing files for chat reactions, attachments and voice messages.
// Every anchor is checked in every file before anything is written; a second
// run changes nothing.
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'server/src/messaging/DirectMessageService.js',
    marker: 'ChatExtras.js',
    edits: [
      {
        name: 'send: files and voice',
        find: "export const send = async ({ target, authorId, tenantId, body, attachmentIds = [], replyToId = null, clientMessageId }) => {\n",
        replace: "export const send = async ({ target, authorId, tenantId, body, attachmentIds = [], fileIds = [], voice = null, replyToId = null, clientMessageId }) => {\n",
      },
      {
        name: 'send: a file alone is a message',
        find: '  if (!text && attachmentIds.length === 0) {\n',
        replace: '  if (!text && attachmentIds.length === 0 && fileIds.length === 0) {\n',
      },
      {
        name: 'send: check the files before writing',
        find: '  const row = await Message.insert({\n',
        replace:
          '  // Messages (032): files from the upload pipeline, checked before anything is written.\n' +
          "  const Extras = await import('./ChatExtras.js');\n" +
          '  const checkedFiles = await Extras.checkFiles({ authorId, tenantId, fileIds, voice });\n' +
          '\n' +
          '  const row = await Message.insert({\n',
      },
      {
        name: 'send: attach and show files',
        find:
          '  const attachments = await Attachment.listForMessage(row.message_id);\n' +
          '  const message = Message.toMessage(row, { attachments, viewerId: authorId });\n',
        replace:
          '  await Extras.attachFiles({ messageId: row.message_id, checked: checkedFiles });\n' +
          '\n' +
          '  const attachments = await Attachment.listForMessage(row.message_id);\n' +
          '  const [message] = await Extras.applyExtras([Message.toMessage(row, { attachments, viewerId: authorId })], authorId);\n',
      },
      {
        name: 'edit: keep files and reactions',
        find: '  const message = Message.toMessage(updated, { attachments, viewerId: userId });\n',
        replace:
          "  const { applyExtras } = await import('./ChatExtras.js');\n" +
          '  const [message] = await applyExtras([Message.toMessage(updated, { attachments, viewerId: userId })], userId);\n',
      },
      {
        name: 'history: files and reactions for the page',
        find: '  return { items, nextCursor: page.nextCursor, hasMore: page.hasMore };\n',
        replace:
          "  const { applyExtras } = await import('./ChatExtras.js');\n" +
          '  return { items: await applyExtras(items, viewerId), nextCursor: page.nextCursor, hasMore: page.hasMore };\n',
      },
      {
        name: 'react (used by the socket handler)',
        find: 'export default { send, edit, remove, history, authoriseRead };',
        replace:
          '/** Reactions live in ChatExtras; the socket handler looks for them here. */\n' +
          "export const react = async (input) => (await import('./ChatExtras.js')).react(input);\n" +
          '\n' +
          'export default { send, edit, remove, history, authoriseRead, react };',
      },
    ],
  },
  {
    file: 'server/src/messaging/chatGateway.js',
    marker: 'names }) =>',
    edits: [
      {
        name: 'reaction broadcast carries the names',
        find:
          'export const broadcastReaction = ({ target, messageId, emoji, userId, action, count }) =>\n' +
          '  emit(target, SERVER.reactionChanged, { target, messageId, emoji, userId, action, count });\n',
        replace:
          'export const broadcastReaction = ({ target, messageId, emoji, userId, action, count, names }) =>\n' +
          '  emit(target, SERVER.reactionChanged, { target, messageId, emoji, userId, action, count, names: names ?? [] });\n',
      },
      {
        name: 'socket send: files and voice',
        find: '        attachmentIds: payload.attachmentIds,\n',
        replace: '        attachmentIds: payload.attachmentIds,\n        fileIds: payload.fileIds ?? [],\n        voice: payload.voice ?? null,\n',
      },
    ],
  },
  {
    file: 'server/src/routes/messaging.routes.js',
    marker: '/reactions',
    edits: [
      {
        name: 'send body: fileIds, voice',
        find:
          "  '/conversations/:id/messages',\n" +
          "  rateLimit({ key: 'chat:send', points: env.CHAT_RATE_PER_MIN, durationSec: 60, by: ['user'] }),\n" +
          '  validate({\n' +
          '    params: idParam,\n' +
          '    body: z.object({\n' +
          '      body: z.string().max(env.CHAT_MAX_MESSAGE_LEN),\n' +
          '      attachmentIds: z.array(z.string().uuid()).max(10).default([]),\n',
        replace:
          "  '/conversations/:id/messages',\n" +
          "  rateLimit({ key: 'chat:send', points: env.CHAT_RATE_PER_MIN, durationSec: 60, by: ['user'] }),\n" +
          '  validate({\n' +
          '    params: idParam,\n' +
          '    body: z.object({\n' +
          '      body: z.string().max(env.CHAT_MAX_MESSAGE_LEN),\n' +
          '      attachmentIds: z.array(z.string().uuid()).max(10).default([]),\n' +
          '      fileIds: z.array(z.string().uuid()).max(10).default([]),\n' +
          '      voice: z.object({ durationMs: z.number().int().min(0).max(900_000) }).nullish(),\n',
      },
      {
        name: 'send: a file alone is a message',
        find:
          "      if (!req.body.body.trim() && req.body.attachmentIds.length === 0) {\n" +
          "        throw badRequest('A message needs text or an attachment');\n" +
          '      }\n' +
          '\n' +
          '      const message = await DirectMessageService.send({\n' +
          "        target: { kind: 'conversation', conversationId: req.params.id },\n",
        replace:
          "      if (!req.body.body.trim() && req.body.attachmentIds.length === 0 && req.body.fileIds.length === 0) {\n" +
          "        throw badRequest('A message needs text or an attachment');\n" +
          '      }\n' +
          '\n' +
          '      const message = await DirectMessageService.send({\n' +
          "        target: { kind: 'conversation', conversationId: req.params.id },\n" +
          '        fileIds: req.body.fileIds,\n' +
          '        voice: req.body.voice ?? null,\n',
      },
      {
        name: 'reactions and the media of a conversation',
        find: "router.delete(\n  '/messages/:id',\n",
        replace:
          '/** Messages: add or remove one emoji on a message. */\n' +
          'router.post(\n' +
          "  '/messages/:id/reactions',\n" +
          "  rateLimit({ key: 'chat:react', points: 120, durationSec: 60, by: ['user'] }),\n" +
          "  validate({ params: idParam, body: z.object({ emoji: z.string().min(1).max(16), action: z.enum(['add', 'remove']).default('add') }) }),\n" +
          '  route(mapped(async (req) => ChatExtras.react({ messageId: req.params.id, userId: req.user.id, emoji: req.body.emoji, action: req.body.action }))),\n' +
          ');\n' +
          '\n' +
          '/** Messages: what was shared in a conversation — media · files · voice. */\n' +
          'router.get(\n' +
          "  '/conversations/:id/media',\n" +
          "  validate({ params: idParam, query: z.object({ kind: z.enum(['media', 'files', 'voice']).default('media'), before: isoDateTime.optional(), limit: z.coerce.number().int().min(1).max(200).optional() }).passthrough() }),\n" +
          '  route(\n' +
          '    mapped(async (req) => {\n' +
          '      const query = q(req);\n' +
          "      return ChatExtras.media({ conversationId: req.params.id, viewerId: req.user.id, kind: query.kind ?? 'media', before: query.before ?? null, limit: query.limit ?? 60 });\n" +
          '    }),\n' +
          '  ),\n' +
          ');\n' +
          '\n' +
          "router.delete(\n  '/messages/:id',\n",
      },
      {
        name: 'import',
        find: "import * as DirectMessageService from '../messaging/DirectMessageService.js';\n",
        replace: "import * as DirectMessageService from '../messaging/DirectMessageService.js';\nimport * as ChatExtras from '../messaging/ChatExtras.js';\n",
      },
    ],
  },
  {
    file: 'server/src/files/FileService.js',
    marker: 'message_files',
    edits: [
      {
        name: 'participants of a chat may open its files',
        find:
          "               WHERE m.file_id = f.id AND m.deleted_at IS NULL AND (sm.user_id IS NOT NULL OR s.access = 'open')))`,\n",
        replace:
          "               WHERE m.file_id = f.id AND m.deleted_at IS NULL AND (sm.user_id IS NOT NULL OR s.access = 'open'))\n" +
          '            OR EXISTS (\n' +
          '              -- Messages (032): a file sent in a chat, for everyone still in that chat.\n' +
          '              SELECT 1 FROM message_files mf\n' +
          '                JOIN messages msg ON msg.message_id = mf.message_id AND msg.deleted_at IS NULL\n' +
          '                JOIN conversation_participants cp ON cp.conversation_id = msg.conversation_id AND cp.user_id = $2 AND cp.left_at IS NULL\n' +
          '               WHERE mf.file_id = f.id))`,\n',
      },
    ],
  },
  {
    file: 'server/src/files/fileRules.js',
    marker: "case 'webm'",
    edits: [
      {
        name: 'voice recordings: WebM (Chrome, Edge), Ogg (Firefox)',
        find: "  wav: { type: 'audio/wav', kind: 'audio', inline: true, magic: 'wav' },\n",
        replace:
          "  wav: { type: 'audio/wav', kind: 'audio', inline: true, magic: 'wav' },\n" +
          "  webm: { type: 'video/webm', kind: 'video', inline: true, magic: 'webm' },\n" +
          "  ogg: { type: 'audio/ogg', kind: 'audio', inline: true, magic: 'ogg' },\n",
      },
      {
        name: 'content check for WebM and Ogg',
        find: "    case 'mp3':\n",
        replace:
          "    case 'webm':\n" +
          '      return startsWith(b, [0x1a, 0x45, 0xdf, 0xa3]);\n' +
          "    case 'ogg':\n" +
          "      return startsWith(b, ascii('OggS'));\n" +
          "    case 'mp3':\n",
      },
    ],
  },
  {
    file: 'packages/contracts/src/zod/chat.schema.ts',
    marker: 'MessageFileSchema',
    edits: [
      {
        name: 'reactions: who',
        find: '  reacted: z.boolean().default(false),\n});\n',
        replace:
          '  reacted: z.boolean().default(false),\n' +
          '  /** Up to ten display names, for "who reacted" (Messages). */\n' +
          '  names: z.array(z.string()).max(10).default([]),\n' +
          '});\n' +
          '\n' +
          '/** A file from the upload pipeline (files) on a message; `voice` marks a voice message. */\n' +
          'export const MessageFileSchema = z\n' +
          '  .object({\n' +
          '    fileId: z.string(),\n' +
          '    name: z.string(),\n' +
          '    ext: z.string(),\n' +
          '    kind: z.string(),\n' +
          '    sizeBytes: z.number().nonnegative(),\n' +
          '    inline: z.boolean().default(false),\n' +
          '    openUrl: z.string().nullable().default(null),\n' +
          '    voice: z.boolean().default(false),\n' +
          '    durationMs: z.number().nullable().default(null),\n' +
          '  })\n' +
          '  .passthrough();\n' +
          'export type MessageFile = z.infer<typeof MessageFileSchema>;\n',
      },
      {
        name: 'message: files',
        find: '    reactions: z.array(ReactionSummarySchema).max(20).default([]),\n',
        replace:
          '    reactions: z.array(ReactionSummarySchema).max(20).default([]),\n' +
          '    files: z.array(MessageFileSchema).max(10).default([]),\n',
      },
      {
        name: 'send: fileIds and voice',
        find:
          '    attachmentIds: z.array(AssetIdSchema).max(CHAT_ATTACHMENTS_PER_MESSAGE).default([]),\n' +
          '    replyToId: MessageIdSchema.optional(),\n',
        replace:
          '    attachmentIds: z.array(AssetIdSchema).max(CHAT_ATTACHMENTS_PER_MESSAGE).default([]),\n' +
          '    /** Files from the upload pipeline (Messages). */\n' +
          '    fileIds: z.array(z.string().uuid()).max(10).default([]),\n' +
          '    voice: z.strictObject({ durationMs: z.number().int().min(0).max(900_000) }).optional(),\n' +
          '    replyToId: MessageIdSchema.optional(),\n',
      },
      {
        name: 'send: a file alone is a message',
        find: '  .refine((v) => v.body.trim().length > 0 || v.attachmentIds.length > 0, {\n',
        replace: '  .refine((v) => v.body.trim().length > 0 || v.attachmentIds.length > 0 || v.fileIds.length > 0, {\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/api/chatApi.ts',
    marker: 'ConversationMediaSchema',
    edits: [
      {
        name: 'media schema',
        find: 'const ConversationPageSchema = z.object({\n',
        replace:
          'export const ConversationMediaSchema = z\n' +
          '  .object({\n' +
          '    items: z.array(\n' +
          '      Chat.MessageFileSchema.extend({\n' +
          '        messageId: z.string(),\n' +
          '        sentAt: z.string(),\n' +
          '        authorId: z.string().nullable().default(null),\n' +
          "        authorName: z.string().default('Someone'),\n" +
          '      }).passthrough(),\n' +
          '    ),\n' +
          '    nextBefore: z.string().nullable().default(null),\n' +
          '  })\n' +
          '  .passthrough();\n' +
          'export type ConversationMedia = z.infer<typeof ConversationMediaSchema>;\n' +
          '\n' +
          'export const ReactionResultSchema = z\n' +
          '  .object({ messageId: z.string(), emoji: z.string(), count: z.number(), reacted: z.boolean(), names: z.array(z.string()).default([]) })\n' +
          '  .passthrough();\n' +
          '\n' +
          'const ConversationPageSchema = z.object({\n',
      },
      {
        name: 'interface: react result, media',
        find: '  react(messageId: string, input: z.infer<typeof Chat.ReactToMessageSchema>): Promise<void>;\n',
        replace:
          '  react(messageId: string, input: z.infer<typeof Chat.ReactToMessageSchema>): Promise<z.infer<typeof ReactionResultSchema> | undefined>;\n' +
          '  /** Messages: what was shared in a conversation. */\n' +
          "  media(conversationId: string, query?: { kind?: 'media' | 'files' | 'voice'; before?: string | null }, signal?: AbortSignal): Promise<ConversationMedia>;\n",
      },
      {
        name: 'send: fileIds, voice',
        find: '        attachmentIds: input.attachmentIds,\n        replyToId: input.replyToId,\n',
        replace: '        attachmentIds: input.attachmentIds,\n        fileIds: input.fileIds ?? [],\n        voice: input.voice,\n        replyToId: input.replyToId,\n',
      },
      {
        name: 'react returns the new count; media',
        find:
          '  react: async (messageId, input) => {\n' +
          '    await http.post(`/messaging/messages/${encodeURIComponent(messageId)}/reactions`, input, {\n' +
          '      retry: { attempts: 1 },\n' +
          '    });\n' +
          '  },\n',
        replace:
          '  react: async (messageId, input) =>\n' +
          '    http.post(`/messaging/messages/${encodeURIComponent(messageId)}/reactions`, input, {\n' +
          '      schema: ReactionResultSchema,\n' +
          '      retry: { attempts: 1 },\n' +
          '    }),\n' +
          '\n' +
          '  media: (conversationId, query = {}, signal) =>\n' +
          '    http.get(`/messaging/conversations/${encodeURIComponent(conversationId)}/media`, {\n' +
          "      query: { kind: query.kind ?? 'media', ...(query.before ? { before: query.before } : {}) },\n" +
          '      schema: ConversationMediaSchema,\n' +
          '      signal,\n' +
          '    }),\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/state/useChat.ts',
    marker: 'previewFiles',
    edits: [
      {
        name: 'send signature',
        find: '  send(input: { body: string; attachmentIds?: string[]; replyToId?: string }): Promise<void>;\n',
        replace:
          '  send(input: {\n' +
          '    body: string;\n' +
          '    attachmentIds?: string[];\n' +
          '    replyToId?: string;\n' +
          '    /** Messages: files from the upload pipeline, and whether the one file is a voice message. */\n' +
          '    fileIds?: string[];\n' +
          '    voice?: { durationMs: number };\n' +
          '    /** Shown in the bubble while it is sending. */\n' +
          '    previewFiles?: Chat.MessageFile[];\n' +
          '  }): Promise<void>;\n',
      },
      {
        name: 'send payload',
        find: "        ...(input.replyToId ? { replyToId: input.replyToId as Chat.MessageId } : {}),\n        clientMessageId,\n      };\n",
        replace:
          "        ...(input.replyToId ? { replyToId: input.replyToId as Chat.MessageId } : {}),\n" +
          '        fileIds: input.fileIds ?? [],\n' +
          '        ...(input.voice ? { voice: input.voice } : {}),\n' +
          '        clientMessageId,\n' +
          '      };\n',
      },
      {
        name: 'optimistic bubble shows the files',
        find: "        reactions: [],\n        clientMessageId,\n        editedAt: null,\n",
        replace: "        reactions: [],\n        files: input.previewFiles ?? [],\n        clientMessageId,\n        editedAt: null,\n",
      },
      {
        name: 'retry keeps the files',
        find: '        attachmentIds: message.attachments.map((a) => a.assetId),\n        mentions: [],\n        clientMessageId,\n',
        replace:
          '        attachmentIds: message.attachments.map((a) => a.assetId),\n' +
          '        fileIds: (message.files ?? []).map((f) => f.fileId),\n' +
          '        ...(message.files?.[0]?.voice ? { voice: { durationMs: message.files[0].durationMs ?? 0 } } : {}),\n' +
          '        ...(message.replyToId ? { replyToId: message.replyToId } : {}),\n' +
          '        mentions: [],\n' +
          '        clientMessageId,\n',
      },
      {
        name: 'an edit keeps my reactions as I see them',
        find: '            ? { ...payload.message, delivery: \'sent\' as const }\n            : m,\n        ),\n      );\n    };\n\n    const onDeleted',
        replace:
          "            ? { ...payload.message, reactions: m.reactions, files: payload.message.files ?? m.files, delivery: 'sent' as const }\n" +
          '            : m,\n        ),\n      );\n    };\n\n    const onDeleted',
      },
      {
        name: 'live reactions carry the names',
        find:
          '              {\n                emoji: payload.emoji,\n                count: payload.count,\n                reacted: mine ? payload.action === \'add\' : (existing?.reacted ?? false),\n              },\n',
        replace:
          '              {\n                emoji: payload.emoji,\n                count: payload.count,\n                reacted: mine ? payload.action === \'add\' : (existing?.reacted ?? false),\n' +
          '                names: ((payload as { names?: string[] }).names ?? existing?.names ?? []).slice(0, 10),\n' +
          '              },\n',
      },
      {
        name: 'react shows the result at once',
        find:
          "    react: async (messageId, emoji, action = 'add') => {\n" +
          '      await api.react(messageId, { emoji, action });\n' +
          '    },\n',
        replace:
          "    react: async (messageId, emoji, action = 'add') => {\n" +
          '      const result = await api.react(messageId, { emoji, action });\n' +
          '      if (!result) return;\n' +
          '      // Applied here as well as by the socket event, so it also works without one.\n' +
          '      setMessages((current) =>\n' +
          '        current.map((m) => {\n' +
          '          if (m.messageId !== messageId) return m;\n' +
          '          const others = m.reactions.filter((r) => r.emoji !== emoji);\n' +
          '          if (result.count === 0) return { ...m, reactions: others };\n' +
          '          const position = m.reactions.findIndex((r) => r.emoji === emoji);\n' +
          '          const next = { emoji, count: result.count, reacted: result.reacted, names: result.names };\n' +
          '          const reactions = [...others];\n' +
          '          reactions.splice(position === -1 ? reactions.length : position, 0, next);\n' +
          '          return { ...m, reactions };\n' +
          '        }),\n' +
          '      );\n' +
          '    },\n',
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
__CHAT_EOF__
node .chat-blocks-patch.mjs || { rm -f .chat-blocks-patch.mjs; exit 1; }
rm -f .chat-blocks-patch.mjs

echo "--- writing files"
mkdir -p server/src/db/migrations
cat > server/src/db/migrations/032_chat_reactions_files.sql <<'__CHAT_EOF__'
-- 032_chat_reactions_files.sql  (Messages: reactions, attachments, voice)
--
--   message_reactions   one row per person and emoji on a message
--   message_files       files from the upload pipeline (files, 029) attached
--                       to a message; voice_duration_ms marks a voice message
--
-- The older message_attachments table (008) points at the legacy assets table
-- and stays as it is. Additive only.

create table if not exists message_reactions (
  message_id uuid        not null references messages (message_id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  emoji      text        not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);
create index if not exists message_reactions_message_idx on message_reactions (message_id);

create table if not exists message_files (
  message_id        uuid     not null references messages (message_id) on delete cascade,
  file_id           uuid     not null references files (id) on delete cascade,
  position          smallint not null default 0,
  voice_duration_ms integer  check (voice_duration_ms is null or voice_duration_ms between 0 and 900000),
  primary key (message_id, file_id)
);
create index if not exists message_files_file_idx on message_files (file_id);
__CHAT_EOF__
echo "wrote server/src/db/migrations/032_chat_reactions_files.sql"
mkdir -p server/src/messaging
cat > server/src/messaging/chatExtrasRules.js <<'__CHAT_EOF__'
// classroom-app/server/src/messaging/chatExtrasRules.js
/**
 * Rules for reactions, attachments and voice messages  (Messages)
 *
 * Pure, tested in server/test/messaging/chatExtrasRules.check.mjs, and shared
 * with the community chat (step 2), so both chats follow the same rules.
 */

export const MAX_FILES_PER_MESSAGE = 10;
export const MAX_VOICE_MS = 15 * 60 * 1000;
export const MAX_REACTIONS_PER_PERSON = 12;
export const MEDIA_KINDS = ['media', 'files', 'voice'];

/**
 * One emoji (with its skin tone, flags and ZWJ sequences), nothing else:
 * no text, no markup. At most 16 code units, like the column.
 */
export const isEmoji = (value) => {
  const text = String(value ?? '');
  if (!text || text.length > 16 || /\s/.test(text)) return false;
  if (/^[0-9#*]\ufe0f?\u20e3$/u.test(text)) return true; // keycaps: 1️⃣ #️⃣
  if (!/\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(text)) return false;
  // Every code point has to belong to an emoji sequence.
  return /^(?:\p{Extended_Pictographic}|\p{Emoji_Modifier}|\p{Emoji_Component}|\p{Regional_Indicator}|\u200d|\ufe0f|\u20e3)+$/u.test(text);
};

/** Rows of (emoji, user_id, display_name) → the per-message summary the client shows. */
export const summariseReactions = (rows = [], viewerId = null) => {
  const byEmoji = new Map();
  for (const row of rows) {
    const entry = byEmoji.get(row.emoji) ?? { emoji: row.emoji, count: 0, reacted: false, names: [], first: row.created_at };
    entry.count += 1;
    if (row.user_id === viewerId) entry.reacted = true;
    if (entry.names.length < 10) entry.names.push(row.user_id === viewerId ? 'You' : row.display_name ?? 'Someone');
    if (row.created_at && (!entry.first || new Date(row.created_at) < new Date(entry.first))) entry.first = row.created_at;
    byEmoji.set(row.emoji, entry);
  }
  return [...byEmoji.values()]
    .sort((a, b) => b.count - a.count || new Date(a.first ?? 0) - new Date(b.first ?? 0))
    .slice(0, 20)
    .map(({ first, ...rest }) => rest);
};

/** Which gallery tab a file belongs to. */
export const galleryKindOf = (file) => {
  if (file.voice_duration_ms !== null && file.voice_duration_ms !== undefined) return 'voice';
  if (file.kind === 'image' || file.kind === 'video') return 'media';
  return 'files';
};

/** The duration the client claims, kept within bounds. */
export const voiceDuration = (value) => {
  const ms = Math.round(Number(value));
  if (!Number.isFinite(ms) || ms < 0) return 0;
  return Math.min(ms, MAX_VOICE_MS);
};

export default { MAX_FILES_PER_MESSAGE, MAX_VOICE_MS, MAX_REACTIONS_PER_PERSON, MEDIA_KINDS, isEmoji, summariseReactions, galleryKindOf, voiceDuration };
__CHAT_EOF__
echo "wrote server/src/messaging/chatExtrasRules.js"
mkdir -p server/src/messaging
cat > server/src/messaging/ChatExtras.js <<'__CHAT_EOF__'
// classroom-app/server/src/messaging/ChatExtras.js
/**
 * Reactions, attachments and voice messages  (Messages)
 *
 *   checkFiles / attachFiles   files from the upload pipeline (files, 029) on a
 *                              message: only your own, ready files; checked
 *                              before the message is written, attached after
 *   applyExtras                adds files and reactions to message views, for a
 *                              whole page in two queries
 *   react                      add or remove one emoji; everyone in the chat
 *                              sees it live (chat:message.reaction)
 *   media                      the files of a conversation for the details
 *                              panel: media · files · voice
 *
 * Who may open an attached file: the participants of its conversation
 * (FileService.canView). A deleted message shows none of its files.
 */

import { ApiError } from '@classroom/contracts';
import { pool } from '../db/pool.js';
import * as Message from './models/Message.js';
import * as Files from '../files/FileService.js';
import * as Rules from './chatExtrasRules.js';

const fail = (code, detail) => {
  throw new ApiError(code, { detail });
};

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

/** Before the message is written: the files exist, are ready and are the author's. */
export const checkFiles = async ({ authorId, tenantId, fileIds = [], voice = null }) => {
  const ids = [...new Set(fileIds)];
  if (ids.length === 0) return { ids, durationMs: null };
  if (ids.length > Rules.MAX_FILES_PER_MESSAGE) fail('validation_failed', `Up to ${Rules.MAX_FILES_PER_MESSAGE} files per message.`);

  const { rows } = await pool.query(
    `SELECT id, kind FROM files
      WHERE id = ANY($1::uuid[]) AND owner_id = $2 AND ($3::uuid IS NULL OR tenant_id = $3)
        AND status = 'ready' AND deleted_at IS NULL`,
    [ids, authorId, tenantId ?? null],
  );
  if (rows.length !== ids.length) fail('validation_failed', 'One of the files is not ready yet or is no longer available. Upload it again.');

  let durationMs = null;
  if (voice) {
    if (ids.length !== 1 || !['audio', 'video'].includes(rows[0].kind)) fail('validation_failed', 'A voice message is one recording.');
    durationMs = Rules.voiceDuration(voice.durationMs);
  }
  return { ids, durationMs };
};

/** After the message is written. Idempotent, like the send it belongs to. */
export const attachFiles = async ({ messageId, checked }) => {
  if (!checked?.ids?.length) return;
  await pool.query(
    `INSERT INTO message_files (message_id, file_id, position, voice_duration_ms)
     SELECT $1, f.id, f.position - 1, $3
       FROM unnest($2::uuid[]) WITH ORDINALITY AS f(id, position)
     ON CONFLICT (message_id, file_id) DO NOTHING`,
    [messageId, checked.ids, checked.durationMs],
  );
};

const toFile = (row) => ({
  ...Files.toView(row),
  voice: row.voice_duration_ms !== null && row.voice_duration_ms !== undefined,
  durationMs: row.voice_duration_ms ?? null,
});

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

const extrasFor = async ({ messageIds, viewerId }) => {
  const result = new Map(messageIds.map((id) => [id, { files: [], reactionRows: [] }]));
  if (messageIds.length === 0) return result;

  const [{ rows: files }, { rows: reactions }] = await Promise.all([
    pool.query(
      `SELECT mf.message_id, mf.position, mf.voice_duration_ms, f.*
         FROM message_files mf JOIN files f ON f.id = mf.file_id
        WHERE mf.message_id = ANY($1::uuid[]) AND f.deleted_at IS NULL AND f.status = 'ready'
        ORDER BY mf.message_id, mf.position`,
      [messageIds],
    ),
    pool.query(
      `SELECT r.message_id, r.emoji, r.user_id, r.created_at, u.display_name
         FROM message_reactions r JOIN users u ON u.id = r.user_id
        WHERE r.message_id = ANY($1::uuid[])
        ORDER BY r.created_at`,
      [messageIds],
    ),
  ]);
  for (const row of files) result.get(row.message_id)?.files.push(toFile(row));
  for (const row of reactions) result.get(row.message_id)?.reactionRows.push(row);
  for (const [, entry] of result) entry.reactions = Rules.summariseReactions(entry.reactionRows, viewerId);
  return result;
};

/** Message views with their files and reactions, as `viewerId` sees them. */
export const applyExtras = async (messages, viewerId) => {
  const ids = messages.filter((m) => !m.deletedAt).map((m) => m.messageId);
  const extras = await extrasFor({ messageIds: ids, viewerId });
  return messages.map((message) => {
    const entry = extras.get(message.messageId);
    return { ...message, files: entry?.files ?? [], reactions: entry?.reactions ?? [] };
  });
};

// ---------------------------------------------------------------------------
// Reactions
// ---------------------------------------------------------------------------

export const react = async ({ messageId, userId, emoji, action = 'add' }) => {
  if (!Rules.isEmoji(emoji)) fail('validation_failed', 'A reaction is one emoji.');
  const row = await Message.findById(messageId);
  if (!row) fail('not_found', 'Message not found.');
  if (row.deleted_at) fail('gone', 'This message was deleted.');

  const target = Message.toMessage(row, {}).target;
  const { authoriseRead } = await import('./DirectMessageService.js');
  await authoriseRead({ target, userId });

  if (action === 'remove') {
    await pool.query(`DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3`, [messageId, userId, emoji]);
  } else {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n FROM message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji <> $3`,
      [messageId, userId, emoji],
    );
    if ((rows[0]?.n ?? 0) >= Rules.MAX_REACTIONS_PER_PERSON) fail('conflict', 'That is enough reactions on one message.');
    await pool.query(
      `INSERT INTO message_reactions (message_id, user_id, emoji) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
      [messageId, userId, emoji],
    );
  }

  const { rows: current } = await pool.query(
    `SELECT r.emoji, r.user_id, r.created_at, u.display_name
       FROM message_reactions r JOIN users u ON u.id = r.user_id
      WHERE r.message_id = $1 AND r.emoji = $2 ORDER BY r.created_at`,
    [messageId, emoji],
  );
  const summary = Rules.summariseReactions(current, userId)[0] ?? { emoji, count: 0, reacted: false, names: [] };
  // Names as everyone else sees them: "You" is only true for the reactor.
  const namesForOthers = current.slice(0, 10).map((r) => r.display_name ?? 'Someone');

  const { broadcastReaction } = await import('./chatGateway.js');
  broadcastReaction({ target, messageId, emoji, userId, action: action === 'remove' ? 'remove' : 'add', count: summary.count, names: namesForOthers });

  return { messageId, ...summary };
};

// ---------------------------------------------------------------------------
// The details panel: everything that was shared in a conversation
// ---------------------------------------------------------------------------

const GALLERY_WHERE = {
  voice: 'mf.voice_duration_ms IS NOT NULL',
  media: "mf.voice_duration_ms IS NULL AND f.kind IN ('image', 'video')",
  files: "mf.voice_duration_ms IS NULL AND f.kind NOT IN ('image', 'video')",
};

export const media = async ({ conversationId, viewerId, kind = 'media', before = null, limit = 60 }) => {
  const size = Math.min(Math.max(Number(limit) || 60, 1), 200);
  if (!Rules.MEDIA_KINDS.includes(kind)) fail('validation_failed', 'Unknown kind.');
  const { assertParticipant } = await import('./ConversationService.js');
  await assertParticipant({ conversationId, userId: viewerId });

  const { rows } = await pool.query(
    `SELECT mf.voice_duration_ms, f.*, m.message_id, m.created_at AS sent_at, m.author_id, u.display_name AS author_name
       FROM message_files mf
       JOIN messages m ON m.message_id = mf.message_id
       JOIN files f ON f.id = mf.file_id
       LEFT JOIN users u ON u.id = m.author_id
       JOIN conversation_participants p ON p.conversation_id = m.conversation_id AND p.user_id = $2
      WHERE m.conversation_id = $1 AND m.deleted_at IS NULL
        AND f.deleted_at IS NULL AND f.status = 'ready'
        AND m.created_at > coalesce(p.cleared_at, '-infinity'::timestamptz)
        AND ($3::timestamptz IS NULL OR m.created_at < $3)
        AND ${GALLERY_WHERE[kind]}
      ORDER BY m.created_at DESC, mf.position
      LIMIT $4`,
    [conversationId, viewerId, before, size + 1],
  );
  const page = rows.slice(0, size);
  return {
    items: page.map((row) => ({
      ...toFile(row),
      messageId: row.message_id,
      sentAt: new Date(row.sent_at).toISOString(),
      authorId: row.author_id,
      authorName: row.author_name ?? 'Someone',
    })),
    nextBefore: rows.length > size ? new Date(page.at(-1).sent_at).toISOString() : null,
  };
};

export default { checkFiles, attachFiles, applyExtras, react, media };
__CHAT_EOF__
echo "wrote server/src/messaging/ChatExtras.js"
mkdir -p server/test/messaging
cat > server/test/messaging/chatExtrasRules.check.mjs <<'__CHAT_EOF__'
// node --test server/test/messaging/chatExtrasRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isEmoji, summariseReactions, galleryKindOf, voiceDuration, MAX_VOICE_MS } from '../../src/messaging/chatExtrasRules.js';

test('one emoji, nothing else', () => {
  for (const ok of ['👍', '❤️', '😂', '👍🏽', '🇩🇪', '👩‍💻', '👨‍👩‍👧', '🙏', '🔥', '1️⃣']) assert.equal(isEmoji(ok), true, ok);
  for (const bad of ['', 'a', 'ok', '👍 ', '<b>', '👍a', 'x'.repeat(20), null, '123', '#']) assert.equal(isEmoji(bad), false, String(bad));
});

test('reaction summary: counts, mine, names, most used first', () => {
  const rows = [
    { emoji: '👍', user_id: 'u1', display_name: 'Ann', created_at: '2026-10-01T10:00:00Z' },
    { emoji: '❤️', user_id: 'u2', display_name: 'Ben', created_at: '2026-10-01T09:00:00Z' },
    { emoji: '👍', user_id: 'me', display_name: 'Me', created_at: '2026-10-01T11:00:00Z' },
  ];
  assert.deepEqual(summariseReactions(rows, 'me'), [
    { emoji: '👍', count: 2, reacted: true, names: ['Ann', 'You'] },
    { emoji: '❤️', count: 1, reacted: false, names: ['Ben'] },
  ]);
  assert.deepEqual(summariseReactions([], 'me'), []);
});

test('gallery tabs and voice length', () => {
  assert.equal(galleryKindOf({ kind: 'image', voice_duration_ms: null }), 'media');
  assert.equal(galleryKindOf({ kind: 'video' }), 'media');
  assert.equal(galleryKindOf({ kind: 'document' }), 'files');
  assert.equal(galleryKindOf({ kind: 'audio', voice_duration_ms: null }), 'files');
  assert.equal(galleryKindOf({ kind: 'video', voice_duration_ms: 4200 }), 'voice');
  assert.equal(voiceDuration('4200.4'), 4200);
  assert.equal(voiceDuration(-5), 0);
  assert.equal(voiceDuration('x'), 0);
  assert.equal(voiceDuration(10 ** 9), MAX_VOICE_MS);
});
__CHAT_EOF__
echo "wrote server/test/messaging/chatExtrasRules.check.mjs"
mkdir -p apps/web/src/components/ChatKit
cat > apps/web/src/components/ChatKit/chatKitModel.js <<'__CHAT_EOF__'
/**
 * The chat kit's pure helpers  (Messages · Community)
 *
 * Shared by every chat in the app; tested in __checks__/chatKitModel.check.mjs.
 */

import { DEFAULT_ACCEPT, extensionOf } from '../Files/filesModel.js';

export const QUICK_REACTIONS = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/** The full picker, grouped like on a phone. */
export const EMOJI_GROUPS = [
  { label: 'Smileys', emoji: ['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😋', '😛', '🤔', '🤨', '😐', '🙄', '😏', '😬', '😌', '😴', '🤯', '🥳', '😎', '🤓', '😕', '😟', '😮', '😲', '😳', '🥺', '😢', '😭', '😤', '😡'] },
  { label: 'Gestures', emoji: ['👍', '👎', '👏', '🙌', '👐', '🤝', '🙏', '✌️', '🤞', '🤟', '👌', '🤌', '👋', '💪', '✍️', '👀'] },
  { label: 'Hearts and symbols', emoji: ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '💔', '❣️', '💯', '✅', '❌', '❓', '❗', '⭐', '🔥', '✨', '🎉', '🎊', '💡'] },
  { label: 'Learning', emoji: ['📚', '📖', '📝', '✏️', '📐', '🧮', '🔬', '🧪', '🌍', '💻', '🎓', '🏆', '⏰', '📅', '☕', '🍕'] },
];

/** Files a chat accepts: everything uploads take, plus voice recordings. */
export const CHAT_ACCEPT = [...new Set([...DEFAULT_ACCEPT, 'webm', 'ogg'])];
export const MAX_FILES = 10;
export const MAX_FILE_BYTES = 50 * 1024 * 1024;

/** Why a file cannot be attached, or null. */
export const attachProblem = (file, { staged = 0, accept = CHAT_ACCEPT, maxBytes = MAX_FILE_BYTES } = {}) => {
  if (staged >= MAX_FILES) return `Up to ${MAX_FILES} files per message.`;
  const ext = extensionOf(file?.name);
  if (!ext || !accept.includes(ext)) return `${file?.name ?? 'This file'}: this type of file cannot be sent.`;
  if (!file.size) return `${file.name} is empty.`;
  if (file.size > maxBytes) return `${file.name} is larger than ${Math.round(maxBytes / 1024 / 1024)} MB.`;
  return null;
};

/** 0:07 · 1:05 · 12:00 */
export const formatDuration = (ms) => {
  const total = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
};

/**
 * The recording format this browser can make, and the file extension the
 * upload checks know for it. Chrome/Edge: WebM · Firefox: Ogg · Safari: MP4.
 */
export const recorderFormat = (isTypeSupported) => {
  const supported = (type) => {
    try {
      return Boolean(isTypeSupported?.(type));
    } catch {
      return false;
    }
  };
  if (supported('audio/webm;codecs=opus')) return { mimeType: 'audio/webm;codecs=opus', ext: 'webm' };
  if (supported('audio/webm')) return { mimeType: 'audio/webm', ext: 'webm' };
  if (supported('audio/ogg;codecs=opus')) return { mimeType: 'audio/ogg;codecs=opus', ext: 'ogg' };
  if (supported('audio/mp4')) return { mimeType: 'audio/mp4', ext: 'm4a' };
  return null;
};

/** "Ann and You" · "Ann, Ben and 3 others" — the tooltip of a reaction. */
export const reactionTitle = ({ emoji, count = 0, names = [] }) => {
  if (!names.length) return `${count} reacted with ${emoji}`;
  const rest = count - names.length;
  const shown = rest > 0 ? [...names, `${rest} ${rest === 1 ? 'other' : 'others'}`] : names;
  const list = shown.length === 1 ? shown[0] : `${shown.slice(0, -1).join(', ')} and ${shown.at(-1)}`;
  return `${list} reacted with ${emoji}`;
};

/** Add if I have not reacted with it, remove if I have. */
export const toggleAction = (reactions = [], emoji) => (reactions.some((r) => r.emoji === emoji && r.reacted) ? 'remove' : 'add');

/** Pictures and videos as a grid, everything else as a list below it. */
export const splitFiles = (files = []) => ({
  visual: files.filter((f) => !f.voice && (f.kind === 'image' || f.kind === 'video')),
  voice: files.filter((f) => f.voice),
  other: files.filter((f) => !f.voice && f.kind !== 'image' && f.kind !== 'video'),
});

/** What a message with only files says in a preview or a reply chip. */
export const filesLabel = (files = []) => {
  if (!files.length) return '';
  if (files[0].voice) return `🎤 Voice message (${formatDuration(files[0].durationMs)})`;
  if (files.length > 1) return `📎 ${files.length} files`;
  const icon = { image: '🖼', video: '🎬', audio: '🎵' }[files[0].kind] ?? '📄';
  return `${icon} ${files[0].name}`;
};
__CHAT_EOF__
echo "wrote apps/web/src/components/ChatKit/chatKitModel.js"
mkdir -p apps/web/src/components/ChatKit
cat > apps/web/src/components/ChatKit/Reactions.jsx <<'__CHAT_EOF__'
import { useEffect, useRef, useState } from 'react';
import { EMOJI_GROUPS, QUICK_REACTIONS, reactionTitle } from './chatKitModel.js';

/**
 * Reactions  (chat kit)
 *
 *   ReactionChips    under a message: one chip per emoji with its count; yours
 *                    are highlighted; click to add or take back; hover says who
 *   ReactionPicker   six quick ones and "+" for the full set, like a phone
 */

export function ReactionChips({ reactions = [], onToggle, mine = false }) {
  if (!reactions.length) return null;
  return (
    <div className={`ck-chips${mine ? ' is-mine' : ''}`}>
      {reactions.map((reaction) => (
        <button
          key={reaction.emoji}
          type="button"
          className={`ck-chip${reaction.reacted ? ' is-on' : ''}`}
          title={reactionTitle(reaction)}
          aria-pressed={reaction.reacted}
          aria-label={`${reactionTitle(reaction)}. ${reaction.reacted ? 'Take back' : 'React too'}`}
          onClick={() => onToggle(reaction.emoji)}
        >
          <span aria-hidden="true">{reaction.emoji}</span>
          {reaction.count > 1 ? <span className="ck-chip__count">{reaction.count}</span> : null}
        </button>
      ))}
    </div>
  );
}

export function ReactionPicker({ onPick, onClose, align = 'start' }) {
  const [all, setAll] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    const onDown = (event) => !ref.current?.contains(event.target) && onClose();
    const onKey = (event) => event.key === 'Escape' && (event.stopPropagation(), onClose());
    document.addEventListener('pointerdown', onDown);
    document.addEventListener('keydown', onKey, true);
    ref.current?.querySelector('button')?.focus();
    return () => {
      document.removeEventListener('pointerdown', onDown);
      document.removeEventListener('keydown', onKey, true);
    };
  }, [onClose]);

  const pick = (emoji) => {
    onPick(emoji);
    onClose();
  };

  return (
    <div ref={ref} className={`ck-picker ck-picker--${align}${all ? ' is-all' : ''}`} role="dialog" aria-label="React with an emoji">
      <div className="ck-picker__quick">
        {QUICK_REACTIONS.map((emoji) => (
          <button key={emoji} type="button" onClick={() => pick(emoji)} aria-label={`React with ${emoji}`}>
            {emoji}
          </button>
        ))}
        <button type="button" className="ck-picker__more" onClick={() => setAll((value) => !value)} aria-expanded={all} aria-label="More emoji">
          {all ? '−' : '+'}
        </button>
      </div>
      {all ? (
        <div className="ck-picker__all">
          {EMOJI_GROUPS.map((group) => (
            <div key={group.label}>
              <p>{group.label}</p>
              <div className="ck-picker__grid">
                {group.emoji.map((emoji) => (
                  <button key={emoji} type="button" onClick={() => pick(emoji)} aria-label={`React with ${emoji}`}>
                    {emoji}
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
}
__CHAT_EOF__
echo "wrote apps/web/src/components/ChatKit/Reactions.jsx"
mkdir -p apps/web/src/components/ChatKit
cat > apps/web/src/components/ChatKit/MessageFiles.jsx <<'__CHAT_EOF__'
import { useEffect, useRef, useState } from 'react';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDuration, splitFiles } from './chatKitModel.js';

/**
 * Files in a message  (chat kit)
 *
 * Pictures and videos as a grid (a picture opens large on click), voice
 * messages as a player, everything else as a card with Open or Download.
 * Links are signed for two hours; a page left open longer reloads them.
 */

export function VoicePlayer({ src, durationMs = 0, mine = false }) {
  const audio = useRef(null);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [length, setLength] = useState(durationMs / 1000);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const el = audio.current;
    if (!el) return undefined;
    const onTime = () => setPosition(el.currentTime);
    const onMeta = () => Number.isFinite(el.duration) && el.duration > 0 && setLength(el.duration);
    const onEnd = () => {
      setPlaying(false);
      setPosition(0);
    };
    const onPause = () => setPlaying(false);
    const onPlay = () => setPlaying(true);
    el.addEventListener('timeupdate', onTime);
    el.addEventListener('loadedmetadata', onMeta);
    el.addEventListener('ended', onEnd);
    el.addEventListener('pause', onPause);
    el.addEventListener('play', onPlay);
    return () => {
      el.removeEventListener('timeupdate', onTime);
      el.removeEventListener('loadedmetadata', onMeta);
      el.removeEventListener('ended', onEnd);
      el.removeEventListener('pause', onPause);
      el.removeEventListener('play', onPlay);
    };
  }, []);

  const toggle = async () => {
    const el = audio.current;
    if (!el) return;
    if (playing) return el.pause();
    // One voice message at a time, like any messenger.
    document.querySelectorAll('audio[data-ck-voice]').forEach((other) => other !== el && other.pause());
    try {
      await el.play();
    } catch {
      setFailed(true);
    }
    return undefined;
  };

  const seek = (event) => {
    const el = audio.current;
    if (!el || !length) return;
    const box = event.currentTarget.getBoundingClientRect();
    el.currentTime = Math.min(length, Math.max(0, ((event.clientX - box.left) / box.width) * length));
  };

  const share = length ? Math.min(1, position / length) : 0;
  return (
    <div className={`ck-voice${mine ? ' is-mine' : ''}`}>
      <audio ref={audio} src={src} preload="metadata" data-ck-voice onError={() => setFailed(true)} />
      <button type="button" className="ck-voice__play" onClick={toggle} aria-label={playing ? 'Pause voice message' : 'Play voice message'} disabled={failed}>
        {playing ? '❚❚' : '▶'}
      </button>
      <div className="ck-voice__track" onClick={seek} role="slider" tabIndex={0} aria-label="Position" aria-valuemin={0} aria-valuemax={Math.round(length)} aria-valuenow={Math.round(position)}
        onKeyDown={(event) => {
          const el = audio.current;
          if (!el) return;
          if (event.key === 'ArrowRight') el.currentTime = Math.min(length, el.currentTime + 5);
          if (event.key === 'ArrowLeft') el.currentTime = Math.max(0, el.currentTime - 5);
        }}
      >
        <i style={{ transform: `scaleX(${share})` }} />
      </div>
      <span className="ck-voice__time">{failed ? 'Unavailable' : formatDuration((playing || position ? position : length) * 1000)}</span>
    </div>
  );
}

function Lightbox({ file, onClose }) {
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
  const href = fileHref(file.openUrl);
  return (
    <dialog ref={ref} className="ck-lightbox" aria-label={file.name} onClick={(event) => event.target === ref.current && onClose()}>
      <div className="ck-lightbox__bar">
        <span>{file.name}</span>
        <span>
          <a href={href} target="_blank" rel="noopener noreferrer">Open</a>
          <button type="button" onClick={onClose} aria-label="Close">×</button>
        </span>
      </div>
      <img src={href} alt={file.name} />
    </dialog>
  );
}

export default function MessageFiles({ files = [], mine = false }) {
  const [large, setLarge] = useState(null);
  if (!files.length) return null;
  const { visual, voice, other } = splitFiles(files);
  return (
    <div className="ck-files">
      {visual.length ? (
        <div className={`ck-grid ck-grid--${Math.min(visual.length, 4)}`}>
          {visual.slice(0, 4).map((file, index) => {
            const href = file.openUrl ? fileHref(file.openUrl) : null;
            const more = index === 3 && visual.length > 4 ? visual.length - 4 : 0;
            if (!href) return <span key={file.fileId} className="ck-grid__gone">No longer available</span>;
            return file.kind === 'image' ? (
              <button key={file.fileId} type="button" className="ck-grid__item" onClick={() => setLarge(file)} aria-label={`Open ${file.name}`}>
                <img src={href} alt={file.name} loading="lazy" decoding="async" />
                {more ? <span className="ck-grid__more">+{more}</span> : null}
              </button>
            ) : (
              <span key={file.fileId} className="ck-grid__item">
                <video src={href} controls preload="metadata" playsInline />
              </span>
            );
          })}
        </div>
      ) : null}
      {voice.map((file) => (file.openUrl ? <VoicePlayer key={file.fileId} src={fileHref(file.openUrl)} durationMs={file.durationMs ?? 0} mine={mine} /> : null))}
      {other.map((file) => {
        const href = file.openUrl ? fileHref(file.openUrl) : null;
        return (
          <div key={file.fileId} className="ck-doc">
            <span className="ck-doc__icon" aria-hidden="true">{iconFor(file.kind)}</span>
            <span className="ck-doc__text">
              <span className="ck-doc__name" title={file.name}>{file.name}</span>
              <span className="ck-doc__meta">{fileMeta(file)}</span>
            </span>
            {file.kind === 'audio' && href ? <audio src={href} controls preload="none" className="ck-doc__audio" /> : null}
            {href ? (
              <a className="ck-doc__open" href={href} target="_blank" rel="noopener noreferrer">
                {file.inline ? 'Open' : 'Download'}
              </a>
            ) : (
              <span className="ck-doc__meta">Unavailable</span>
            )}
          </div>
        );
      })}
      {large ? <Lightbox file={large} onClose={() => setLarge(null)} /> : null}
    </div>
  );
}
__CHAT_EOF__
echo "wrote apps/web/src/components/ChatKit/MessageFiles.jsx"
mkdir -p apps/web/src/components/ChatKit
cat > apps/web/src/components/ChatKit/Composer.jsx <<'__CHAT_EOF__'
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
 * same composer serves Messages and the community chat.
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

export default function Composer({ files, placeholder, disabled = false, disabledReason = '', onSend, onTyping, onArrowUp, onEscape, top = null, inputRef: externalRef = null, hint = true }) {
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
      {hint ? <p className="ck-composer__hint">Enter to send · Shift+Enter for a new line · drop files to attach</p> : null}
    </div>
  );
}
__CHAT_EOF__
echo "wrote apps/web/src/components/ChatKit/Composer.jsx"
mkdir -p apps/web/src/components/ChatKit
cat > apps/web/src/components/ChatKit/chatkit.css <<'__CHAT_EOF__'
/* Chat kit — reactions, files, voice, composer. Shared by Messages and the
   community chat; colours from the app's variables (styles/theme.css). */

/* ---------------------------------------------------------------- reactions */
.ck-chips { display: flex; flex-wrap: wrap; gap: 4px; margin-top: -6px; padding: 0 6px; position: relative; z-index: 1; }
.ck-chips.is-mine { justify-content: flex-end; }
.ck-chip {
  display: inline-flex; align-items: center; gap: 3px; height: 26px; padding: 0 8px; border-radius: 999px;
  border: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface, #fff); color: var(--color-text, #15272c);
  font: inherit; font-size: 14px; line-height: 1; cursor: pointer; box-shadow: 0 1px 3px rgba(20, 38, 43, 0.12);
  transition: transform 0.15s ease, background-color 0.15s ease;
}
.ck-chip:hover { transform: translateY(-1px); }
.ck-chip.is-on { background: rgba(47, 99, 214, 0.12); border-color: rgba(47, 99, 214, 0.5); }
.ck-chip__count { font-size: 12.5px; font-weight: 700; }

.ck-picker {
  position: absolute; bottom: calc(100% + 6px); z-index: 20; display: grid; gap: 6px; padding: 6px; border-radius: 999px;
  background: var(--color-surface, #fff); border: 1px solid var(--color-border, #dbe4e1); box-shadow: 0 12px 32px -12px rgba(20, 38, 43, 0.45);
  animation: ck-pop 0.18s cubic-bezier(0.16, 1, 0.3, 1) both;
}
.ck-picker--start { left: 0; }
.ck-picker--end { right: 0; }
.ck-picker.is-all { border-radius: 16px; width: min(340px, 86vw); }
@keyframes ck-pop { from { opacity: 0; transform: translateY(4px) scale(0.96); } to { opacity: 1; transform: none; } }
.ck-picker__quick { display: flex; gap: 2px; }
.ck-picker button { width: 38px; height: 38px; border: 0; border-radius: 50%; background: none; font-size: 22px; line-height: 1; cursor: pointer; transition: transform 0.12s ease, background-color 0.12s ease; }
.ck-picker button:hover, .ck-picker button:focus-visible { transform: scale(1.18); background: var(--color-surface-2, #f1f5f4); }
.ck-picker__more { font-size: 20px !important; color: var(--color-muted, #5d6f73); }
.ck-picker__all { max-height: 260px; overflow-y: auto; padding: 0 2px; }
.ck-picker__all p { margin: 6px 4px 2px; font-size: 11.5px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; color: var(--color-muted, #5d6f73); }
.ck-picker__grid { display: grid; grid-template-columns: repeat(8, 1fr); }
.ck-picker__grid button { width: 36px; height: 36px; font-size: 20px; }

/* ---------------------------------------------------------------- files in a message */
.ck-files { display: grid; gap: 6px; min-width: 0; }
.ck-grid { display: grid; gap: 3px; border-radius: 12px; overflow: hidden; max-width: 360px; }
.ck-grid--2, .ck-grid--3, .ck-grid--4 { grid-template-columns: 1fr 1fr; }
.ck-grid--3 .ck-grid__item:first-child { grid-column: span 2; }
.ck-grid__item { position: relative; display: block; padding: 0; border: 0; background: #0d1a1e; cursor: zoom-in; min-height: 80px; }
.ck-grid__item img { display: block; width: 100%; height: 100%; max-height: 320px; object-fit: cover; }
.ck-grid--1 .ck-grid__item img { object-fit: contain; max-height: 360px; background: rgba(0, 0, 0, 0.04); }
.ck-grid__item video { display: block; width: 100%; max-height: 320px; background: #000; }
.ck-grid__more { position: absolute; inset: 0; display: grid; place-items: center; background: rgba(13, 26, 30, 0.55); color: #fff; font-size: 24px; font-weight: 700; }
.ck-grid__gone { display: grid; place-items: center; padding: 18px; font-size: 13px; background: rgba(20, 38, 43, 0.06); }

.ck-doc { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 8px 10px; border-radius: 12px; background: rgba(20, 38, 43, 0.06); min-width: min(260px, 60vw); }
.is-mine .ck-doc, .ck-files .ck-doc:is(.is-mine *) { background: rgba(255, 255, 255, 0.16); }
.ck-doc__icon { font-size: 24px; }
.ck-doc__text { display: grid; flex: 1; min-width: 0; }
.ck-doc__name { font-weight: 700; font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ck-doc__meta { font-size: 12px; opacity: 0.75; }
.ck-doc__open { font-size: 13px; font-weight: 700; color: inherit; text-decoration: underline; }
.ck-doc__audio { width: 100%; height: 36px; }

.ck-voice { display: flex; align-items: center; gap: 10px; min-width: min(260px, 62vw); padding: 2px 0; }
.ck-voice__play { flex: 0 0 auto; width: 36px; height: 36px; border: 0; border-radius: 50%; background: var(--color-accent, #2f63d6); color: #fff; font-size: 13px; cursor: pointer; }
.ck-voice.is-mine .ck-voice__play { background: #fff; color: var(--color-accent, #2f63d6); }
.ck-voice__play:disabled { opacity: 0.4; cursor: default; }
.ck-voice__track { position: relative; flex: 1; height: 6px; border-radius: 3px; background: rgba(20, 38, 43, 0.15); cursor: pointer; overflow: hidden; }
.ck-voice.is-mine .ck-voice__track { background: rgba(255, 255, 255, 0.35); }
.ck-voice__track i { position: absolute; inset: 0; background: currentColor; transform-origin: left; opacity: 0.8; }
.ck-voice__time { flex: 0 0 auto; font-size: 12.5px; font-variant-numeric: tabular-nums; opacity: 0.85; min-width: 34px; text-align: right; }

.ck-lightbox { width: min(1100px, 96vw); max-height: 94vh; padding: 0; border: 0; border-radius: 14px; background: #0d1a1e; color: #fff; }
.ck-lightbox::backdrop { background: rgba(5, 12, 14, 0.8); }
.ck-lightbox__bar { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 10px 14px; font-size: 14px; }
.ck-lightbox__bar span { display: inline-flex; gap: 12px; align-items: center; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ck-lightbox__bar a { color: #fff; font-weight: 700; }
.ck-lightbox__bar button { border: 0; background: none; color: #fff; font-size: 26px; cursor: pointer; }
.ck-lightbox img { display: block; max-width: 100%; max-height: calc(94vh - 48px); margin: 0 auto; object-fit: contain; }

/* ---------------------------------------------------------------- composer */
.ck-composer { position: relative; display: grid; gap: 8px; }
.ck-dropveil { position: fixed; inset: 0; z-index: 30; display: grid; place-items: center; pointer-events: none; background: rgba(47, 99, 214, 0.1); border: 3px dashed var(--color-accent, #2f63d6); color: var(--color-accent, #2f63d6); font-size: 20px; font-weight: 700; }
[data-ck-dropzone] { position: relative; }
.ck-composer__row { display: flex; align-items: flex-end; gap: 8px; }
.ck-composer textarea {
  flex: 1; min-width: 0; box-sizing: border-box; resize: none; max-height: 180px; padding: 11px 16px; border-radius: 22px;
  border: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface-2, #f1f5f4); font: inherit; font-size: 15px; line-height: 1.4; color: inherit;
}
.ck-composer textarea:focus { background: var(--color-surface, #fff); }
.ck-round { display: grid; place-items: center; flex: 0 0 auto; width: 44px; height: 44px; border: 0; border-radius: 50%; cursor: pointer; transition: transform 0.15s ease, opacity 0.2s ease, background-color 0.15s ease; font-size: 18px; }
.ck-round svg { width: 21px; height: 21px; fill: currentColor; }
.ck-round--ghost { background: transparent; color: var(--color-muted, #5d6f73); }
.ck-round--ghost svg { fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.ck-round--ghost:hover:not(:disabled) { background: var(--color-surface-2, #f1f5f4); color: var(--color-text, #15272c); }
.ck-round--accent { background: var(--color-accent, #2f63d6); color: #fff; }
.ck-round--accent:hover:not(:disabled) { transform: scale(1.05); }
.ck-round:disabled { opacity: 0.35; cursor: default; }
.ck-composer__hint { margin: 0; font-size: 12px; color: var(--color-muted, #5d6f73); }
.ck-composer__notice { margin: 0; padding: 8px 12px; border-radius: 10px; background: #fff3c4; color: #6b4c00; font-size: 14px; }
.ck-composer__error { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin: 0; padding: 6px 6px 6px 12px; border-radius: 10px; background: #fdecec; color: var(--color-danger, #c93636); font-size: 13.5px; }
.ck-composer__error button { border: 0; background: none; color: inherit; font-size: 18px; cursor: pointer; }

.ck-tray { list-style: none; margin: 0; padding: 0; display: flex; gap: 8px; overflow-x: auto; }
.ck-tray__item { position: relative; display: flex; align-items: center; gap: 8px; flex: 0 0 auto; width: 220px; padding: 8px 6px 8px 10px; border-radius: 12px; border: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface, #fff); overflow: hidden; }
.ck-tray__item.is-failed { border-color: #f3c2c2; background: #fdf4f4; }
.ck-tray__icon { font-size: 20px; }
.ck-tray__text { display: grid; flex: 1; min-width: 0; }
.ck-tray__name { font-size: 13.5px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ck-tray__meta { font-size: 12px; color: var(--color-muted, #5d6f73); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ck-tray__item.is-failed .ck-tray__meta { color: var(--color-danger, #c93636); }
.ck-tray__bar { position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: var(--color-accent, #2f63d6); transform-origin: left; transition: transform 0.2s linear; }
.ck-tray__item button { border: 0; background: none; color: var(--color-muted, #5d6f73); font-size: 18px; cursor: pointer; }

.ck-recording { display: flex; align-items: center; gap: 10px; padding: 2px 0; }
.ck-recording__dot { width: 12px; height: 12px; border-radius: 50%; background: #e0393e; animation: ck-blink 1.2s ease-in-out infinite; }
@keyframes ck-blink { 50% { opacity: 0.25; } }
.ck-recording__time { font-size: 17px; font-weight: 700; font-variant-numeric: tabular-nums; }
.ck-recording__label { flex: 1; color: var(--color-muted, #5d6f73); }

@media (prefers-reduced-motion: reduce) {
  .ck-picker, .ck-recording__dot { animation: none; }
  .ck-chip, .ck-round, .ck-picker button { transition: none; }
}
__CHAT_EOF__
echo "wrote apps/web/src/components/ChatKit/chatkit.css"
mkdir -p apps/web/src/components/ChatKit/__checks__
cat > apps/web/src/components/ChatKit/__checks__/chatKitModel.check.mjs <<'__CHAT_EOF__'
// node --test apps/web/src/components/ChatKit/__checks__/chatKitModel.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { attachProblem, formatDuration, recorderFormat, reactionTitle, toggleAction, splitFiles, filesLabel, QUICK_REACTIONS, EMOJI_GROUPS, MAX_FILES } from '../chatKitModel.js';

test('what can be attached', () => {
  assert.equal(attachProblem({ name: 'a.pdf', size: 10 }), null);
  assert.equal(attachProblem({ name: 'voice.webm', size: 10 }), null);
  assert.match(attachProblem({ name: 'x.exe', size: 10 }), /cannot be sent/);
  assert.match(attachProblem({ name: 'a.pdf', size: 0 }), /empty/);
  assert.match(attachProblem({ name: 'a.pdf', size: 60 * 1024 * 1024 }), /larger than 50 MB/);
  assert.match(attachProblem({ name: 'a.pdf', size: 1 }, { staged: MAX_FILES }), /Up to 10/);
});

test('durations', () => {
  assert.equal(formatDuration(0), '0:00');
  assert.equal(formatDuration(7400), '0:07');
  assert.equal(formatDuration(65_000), '1:05');
  assert.equal(formatDuration(-3), '0:00');
});

test('recording formats per browser', () => {
  assert.deepEqual(recorderFormat((t) => t === 'audio/webm;codecs=opus'), { mimeType: 'audio/webm;codecs=opus', ext: 'webm' });
  assert.deepEqual(recorderFormat((t) => t === 'audio/ogg;codecs=opus'), { mimeType: 'audio/ogg;codecs=opus', ext: 'ogg' });
  assert.deepEqual(recorderFormat((t) => t === 'audio/mp4'), { mimeType: 'audio/mp4', ext: 'm4a' });
  assert.equal(recorderFormat(() => false), null);
  assert.equal(recorderFormat(() => { throw new Error('x'); }), null);
  assert.equal(recorderFormat(undefined), null);
});

test('reactions: tooltip and toggle', () => {
  assert.equal(reactionTitle({ emoji: '👍', count: 2, names: ['Ann', 'You'] }), 'Ann and You reacted with 👍');
  assert.equal(reactionTitle({ emoji: '👍', count: 5, names: ['Ann', 'Ben'] }), 'Ann, Ben and 3 others reacted with 👍');
  assert.equal(reactionTitle({ emoji: '👍', count: 1, names: [] }), '1 reacted with 👍');
  assert.equal(toggleAction([{ emoji: '👍', reacted: true }], '👍'), 'remove');
  assert.equal(toggleAction([{ emoji: '👍', reacted: false }], '👍'), 'add');
  assert.equal(toggleAction([], '❤️'), 'add');
  assert.equal(QUICK_REACTIONS.length, 6);
  assert.ok(EMOJI_GROUPS.every((g) => g.emoji.length >= 10));
});

test('files: grouping and labels', () => {
  const files = [{ kind: 'image', name: 'a.png' }, { kind: 'document', name: 'b.pdf' }, { kind: 'video', name: 'c.mp4' }];
  const parts = splitFiles(files);
  assert.deepEqual([parts.visual.length, parts.other.length, parts.voice.length], [2, 1, 0]);
  assert.equal(filesLabel([{ voice: true, durationMs: 5000 }]), '🎤 Voice message (0:05)');
  assert.equal(filesLabel([{ kind: 'image', name: 'a.png' }]), '🖼 a.png');
  assert.equal(filesLabel(files), '📎 3 files');
  assert.equal(filesLabel([]), '');
});
__CHAT_EOF__
echo "wrote apps/web/src/components/ChatKit/__checks__/chatKitModel.check.mjs"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/SharedMedia.jsx <<'__CHAT_EOF__'
import { useEffect, useState } from 'react';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDate } from '../../lib/preferences.js';
import { VoicePlayer } from '../ChatKit/MessageFiles.jsx';

/**
 * Everything shared in a conversation  (Messages)
 *
 * Three tabs, newest first: Media (pictures and videos as a grid), Files
 * (documents and other files) and Voice (voice messages, playable here).
 * "Show more" loads older ones. Only what you can still see in the chat.
 */

const TABS = [
  { kind: 'media', label: 'Media' },
  { kind: 'files', label: 'Files' },
  { kind: 'voice', label: 'Voice' },
];

export default function SharedMedia({ api, conversationId, refreshKey = 0 }) {
  const [kind, setKind] = useState('media');
  const [state, setState] = useState({ items: null, nextBefore: null, error: null });
  const [more, setMore] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    setState({ items: null, nextBefore: null, error: null });
    api
      .media(conversationId, { kind }, controller.signal)
      .then((page) => setState({ items: page.items, nextBefore: page.nextBefore, error: null }))
      .catch(() => !controller.signal.aborted && setState({ items: [], nextBefore: null, error: 'This could not be loaded.' }));
    return () => controller.abort();
  }, [api, conversationId, kind, refreshKey]);

  const loadMore = async () => {
    setMore(true);
    try {
      const page = await api.media(conversationId, { kind, before: state.nextBefore });
      setState((current) => ({ ...current, items: [...current.items, ...page.items], nextBefore: page.nextBefore }));
    } finally {
      setMore(false);
    }
  };

  const items = state.items ?? [];
  return (
    <div className="mx-shared">
      <div className="mx-tabs" role="tablist" aria-label="Shared in this chat">
        {TABS.map((tab) => (
          <button key={tab.kind} type="button" role="tab" aria-selected={kind === tab.kind} className={kind === tab.kind ? 'is-on' : ''} onClick={() => setKind(tab.kind)}>
            {tab.label}
          </button>
        ))}
      </div>
      {state.items === null ? <p className="mx-muted">Loading…</p> : null}
      {state.error ? <p className="mx-muted">{state.error}</p> : null}
      {state.items && !items.length && !state.error ? (
        <p className="mx-muted">{kind === 'media' ? 'No pictures or videos yet.' : kind === 'files' ? 'No files yet.' : 'No voice messages yet.'}</p>
      ) : null}

      {kind === 'media' && items.length ? (
        <ul className="mx-shared__grid">
          {items.map((item) => (
            <li key={`${item.messageId}-${item.fileId}`}>
              <a href={fileHref(item.openUrl)} target="_blank" rel="noopener noreferrer" title={`${item.name} · ${item.authorName}, ${formatDate(item.sentAt)}`}>
                {item.kind === 'image' ? <img src={fileHref(item.openUrl)} alt={item.name} loading="lazy" decoding="async" /> : <span className="mx-shared__video" aria-hidden="true">▶</span>}
              </a>
            </li>
          ))}
        </ul>
      ) : null}

      {kind === 'files' && items.length ? (
        <ul className="mx-shared__list">
          {items.map((item) => (
            <li key={`${item.messageId}-${item.fileId}`}>
              <span aria-hidden="true">{iconFor(item.kind)}</span>
              <span className="mx-shared__text">
                <a href={fileHref(item.openUrl)} target="_blank" rel="noopener noreferrer">{item.name}</a>
                <span className="mx-muted">{fileMeta(item)} · {item.authorName}, {formatDate(item.sentAt)}</span>
              </span>
            </li>
          ))}
        </ul>
      ) : null}

      {kind === 'voice' && items.length ? (
        <ul className="mx-shared__list">
          {items.map((item) => (
            <li key={`${item.messageId}-${item.fileId}`} className="mx-shared__voice">
              <span className="mx-muted">{item.authorName}, {formatDate(item.sentAt)}</span>
              <VoicePlayer src={fileHref(item.openUrl)} durationMs={item.durationMs ?? 0} />
            </li>
          ))}
        </ul>
      ) : null}

      {state.nextBefore ? (
        <button type="button" className="btn" onClick={loadMore} disabled={more}>
          {more ? 'Loading…' : 'Show more'}
        </button>
      ) : null}
    </div>
  );
}
__CHAT_EOF__
echo "wrote apps/web/src/components/Messenger/SharedMedia.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/MessengerThread.jsx <<'__CHAT_EOF__'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createFilesApi, useChat, useCore } from '@classroom/core-client';
import Composer from '../ChatKit/Composer.jsx';
import MessageFiles from '../ChatKit/MessageFiles.jsx';
import { ReactionChips, ReactionPicker } from '../ChatKit/Reactions.jsx';
import { filesLabel, toggleAction } from '../ChatKit/chatKitModel.js';
import '../ChatKit/chatkit.css';
import { formatDate, formatTime } from '../../lib/preferences.js';
import Avatar from './Avatar.jsx';
import { ConfirmDialog } from './Dialogs.jsx';
import { canDelete, canEdit, dayLabel, highlightParts, lastEditable, searchHits, snippet, threadRows } from './messengerModel.js';

/**
 * One conversation  (Messages)
 *
 *   messages   grouped by day and by person; names and pictures open the
 *              person's profile
 *   actions    on hover (or always on touch screens): React, Reply, Edit (your
 *              own, within the edit window), Copy, Delete (your own, for
 *              everyone). Edits, deletes and reactions reach the other side live.
 *   files      pictures, videos, documents and voice messages in the bubble
 *   composer   the chat kit's: text, files (📎, drop, paste) and voice (🎤);
 *              ↑ in an empty composer edits your last message, Esc cancels a reply
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

function MessageActions({ message, mine, editable, deletable, onReact, onReply, onEdit, onCopy, onDelete }) {
  if (message.deletedAt || message.delivery !== 'sent') return null;
  return (
    <span className={`mx-actions${mine ? ' is-mine' : ''}`} role="toolbar" aria-label="Message actions">
      <button type="button" onClick={onReact} title="React" aria-label="React">☺</button>
      <button type="button" onClick={onReply} title="Reply" aria-label="Reply">↩</button>
      {editable ? <button type="button" onClick={onEdit} title="Edit" aria-label="Edit">✎</button> : null}
      {message.body ? <button type="button" onClick={onCopy} title="Copy text" aria-label="Copy text">⧉</button> : null}
      {deletable ? <button type="button" className="is-danger" onClick={onDelete} title="Delete" aria-label="Delete">🗑</button> : null}
    </span>
  );
}

export default function MessengerThread({ api, socket, self, conversation, title, other, editWindowMin, search, onSearchChange, searchOpen, onCloseSearch, onOpenProfile, disabledReason = '' }) {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const target = useMemo(() => ({ kind: 'conversation', conversationId: conversation.conversationId }), [conversation.conversationId]);
  const { messages, loading, loadingOlder, hasMore, loadOlder, typingUserIds, throttledUntil, send, retry, edit, remove, react, setTyping, error } = useChat({
    api,
    socket: socket ?? undefined,
    target,
    self,
  });

  const [replyTo, setReplyTo] = useState(null);
  const [pickerFor, setPickerFor] = useState(null);
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
    setReplyTo(null);
    setPickerFor(null);
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

  const sendFromComposer = async ({ body, files: ready, voice }) => {
    stickToBottom.current = true;
    const reply = replyTo;
    setReplyTo(null);
    await send({
      body,
      fileIds: ready.map((f) => f.fileId),
      previewFiles: ready.map((f) => ({ ...f, voice: Boolean(voice), durationMs: voice?.durationMs ?? null })),
      ...(voice ? { voice } : {}),
      ...(reply ? { replyToId: reply.messageId } : {}),
    });
  };

  const toggleReaction = async (message, emoji) => {
    try {
      await react(message.messageId, emoji, toggleAction(message.reactions, emoji));
    } catch (cause) {
      say(cause?.detail ?? 'The reaction was not saved.');
    }
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

      <div className="mx-messages" ref={scrollRef} onScroll={onScroll} data-ck-dropzone>
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
                          <span>{reply ? (reply.deletedAt ? 'Message deleted' : snippet(reply.body) || filesLabel(reply.files)) : 'to an earlier message'}</span>
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
                        <>
                          <MessageFiles files={message.files ?? []} mine={mine} />
                          {message.body ? (
                            <span className="mx-bubble__text">
                              <Text body={message.body} query={search} />
                            </span>
                          ) : null}
                        </>
                      )}
                      {!isEditing ? (
                        <span className="mx-bubble__meta">
                          {message.editedAt && !message.deletedAt ? <span>edited · </span> : null}
                          {message.delivery === 'sending' ? 'Sending…' : formatTime(new Date(message.createdAt))}
                        </span>
                      ) : null}
                    </div>
                    {pickerFor === message.messageId ? (
                      <ReactionPicker align={mine ? 'end' : 'start'} onPick={(emoji) => toggleReaction(message, emoji)} onClose={() => setPickerFor(null)} />
                    ) : null}
                    {!isEditing ? (
                      <MessageActions
                        message={message}
                        mine={mine}
                        editable={canEdit(message, rules)}
                        deletable={canDelete(message, rules)}
                        onReact={() => setPickerFor(message.messageId)}
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
                  {!message.deletedAt ? <ReactionChips reactions={message.reactions ?? []} mine={mine} onToggle={(emoji) => toggleReaction(message, emoji)} /> : null}
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
        <Composer
          files={files}
          inputRef={composerRef}
          placeholder={throttled ? 'Slow down a little — you can write again in a moment' : `Message ${title}`}
          disabled={disabled}
          disabledReason={disabledReason}
          onSend={sendFromComposer}
          onTyping={setTyping}
          onArrowUp={() => {
            const last = lastEditable(messages, rules);
            if (last) startEdit(last);
            return Boolean(last);
          }}
          onEscape={() => setReplyTo(null)}
          top={
            replyTo ? (
              <div className="mx-replychip">
                <span>
                  <strong>Replying to {replyTo.author?.userId === self.userId ? 'yourself' : replyTo.author?.displayName}</strong>
                  <span>{snippet(replyTo.body) || filesLabel(replyTo.files)}</span>
                </span>
                <button type="button" className="mx-iconbtn" onClick={() => setReplyTo(null)} aria-label="Cancel reply">×</button>
              </div>
            ) : null
          }
        />
      </div>

      {confirmDelete ? (
        <ConfirmDialog
          title="Delete this message?"
          body={`It is removed for everyone in this chat, with its files, and shows as “This message was deleted”. ${snippet(confirmDelete.body, 60) ? `“${snippet(confirmDelete.body, 60)}”` : filesLabel(confirmDelete.files)}`}
          confirmLabel="Delete for everyone"
          danger
          onConfirm={() => remove(confirmDelete.messageId)}
          onClose={() => setConfirmDelete(null)}
        />
      ) : null}
    </div>
  );
}
__CHAT_EOF__
echo "wrote apps/web/src/components/Messenger/MessengerThread.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/MessengerList.jsx <<'__CHAT_EOF__'
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
                    {preview.body ? <Highlight text={preview.body} query={filter} /> : <span>📎 Attachment</span>}
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
__CHAT_EOF__
echo "wrote apps/web/src/components/Messenger/MessengerList.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/ContactPanel.jsx <<'__CHAT_EOF__'
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { isMutedNow } from '@classroom/core-client';
import { formatDate, formatTime } from '../../lib/preferences.js';
import Avatar from './Avatar.jsx';
import { ProfileSummary, useProfile } from './ProfileCard.jsx';
import { ConfirmDialog, ReportDialog } from './Dialogs.jsx';
import SharedMedia from './SharedMedia.jsx';
import { MUTE_CHOICES, muteState, muteUntil } from './messengerModel.js';

/**
 * Details of a conversation  (Messages)
 *
 * Beside the chat on wide screens, as a sheet on narrow ones:
 *   the person      profile as they allow it to be seen
 *   quick actions   search in the chat, mute, pin
 *   notifications   mute for 1 h / 8 h / 1 day / 1 week / until turned on
 *   shared          media, files and voice messages of this chat
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

        <Section title="Shared in this chat">
          <SharedMedia api={api} conversationId={conversation.conversationId} refreshKey={conversation.lastMessageAt} />
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
__CHAT_EOF__
echo "wrote apps/web/src/components/Messenger/ContactPanel.jsx"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/messengerModel.js <<'__CHAT_EOF__'
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
  // A message that is only files (or a voice message) has no text to edit.
  if (!String(message.body ?? '').trim()) return false;
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
__CHAT_EOF__
echo "wrote apps/web/src/components/Messenger/messengerModel.js"
mkdir -p apps/web/src/components/Messenger
cat > apps/web/src/components/Messenger/messenger.css <<'__CHAT_EOF__'

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
__CHAT_EOF__
echo "wrote apps/web/src/components/Messenger/messenger.css"
mkdir -p apps/web/src/components/Messenger/__checks__
cat > apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs <<'__CHAT_EOF__'
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
  const mine = { author: { userId: 'me' }, body: 'hello', delivery: 'sent', createdAt: '2026-10-02T11:55:00Z' };
  const o = { selfUserId: 'me', windowMin: 15, now };
  assert.equal(canEdit(mine, o), true);
  assert.equal(canEdit({ ...mine, createdAt: '2026-10-02T11:40:00Z' }, o), false);
  assert.equal(canEdit({ ...mine, delivery: 'sending' }, o), false);
  assert.equal(canEdit({ ...mine, deletedAt: 'x' }, o), false);
  assert.equal(canEdit({ ...mine, author: { userId: 'other' } }, o), false);
  assert.equal(canEdit({ ...mine, createdAt: '2020-01-01T00:00:00Z' }, { ...o, windowMin: 0 }), true);
  assert.equal(canEdit({ ...mine, body: '' }, o), false, 'files only: nothing to edit');
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
__CHAT_EOF__
echo "wrote apps/web/src/components/Messenger/__checks__/messengerModel.check.mjs"

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
if node --test $CHECKS > .chat-blocks-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .chat-blocks-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .chat-blocks-test.log
else
  cat .chat-blocks-test.log
  rm -f .chat-blocks-test.log
  restore_and_exit "The rule tests failed (see above)."
fi

echo "--- database (migration 032)"
if SERVICE_ROLE=api npm run db:migrate >/tmp/chat-blocks-migrate.log 2>&1; then
  echo "ok  migration 032 applied"
else
  tail -5 /tmp/chat-blocks-migrate.log
  echo
  echo "The files are installed, but the database did not answer, so 032 is not applied yet."
  echo "Once your services run (./dev-up.sh), apply it with:  SERVICE_ROLE=api npm run db:migrate"
  exit 1
fi

echo
echo "Done. Nothing was started; the API and Vite reload on their own."
echo "Reload the browser with Ctrl+Shift+R and open a chat in Messages."