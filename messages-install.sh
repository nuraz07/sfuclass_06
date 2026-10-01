#!/usr/bin/env bash
# messages-install.sh — the Messages page.
#
#   - "General" (the everyone-chat) is no longer listed here; it stays where
#     it belongs, in the chat inside rooms
#   - only real conversations: chats someone wrote in, and the one you have
#     open — chats opened by accident and never used do not clutter the list
#   - "New message": find a person in your organisation and start a chat
#   - the back button and the ⋯ menu are larger and always visible: the page
#     fits the window and the conversation scrolls inside it
#
# The chat inside rooms and lessons is unchanged (ChatRooms keeps its old
# behaviour there; the new options are off by default).
# Run from the project folder:  bash messages-install.sh
# Writes 2 files, patches 1 more, backup in .messages-backup/<timestamp>/.
# Undo:                         bash messages-install.sh --restore
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  apps/web/src/pages/MessagesPage.jsx
  apps/web/src/components/Chat/messages.css
  apps/web/src/components/Chat/ChatRooms.jsx
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .messages-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  echo "Restored from $FIRST."
  exit 0
fi

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need apps/web/src/components/Chat/ChatRooms.jsx "export default function ChatRooms" "the chat components"
need apps/web/src/components/Chat/chatRooms.css ".rooms-head" "the chat styles"
need apps/web/src/pages/MessagesPage.jsx "useConversations" "the Messages page"
need packages/core-client/src/index.ts "profileApi" "Settings Phase A (person search)"
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what the Messages update expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".messages-backup/$(date +%Y%m%d-%H%M%S)-$$"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/MessagesPage.jsx <<'__MSG_EOF__'
import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createChatApi, createProfileApi, useConversations, useCore } from '@classroom/core-client';
import ChatRooms from '../components/Chat/ChatRooms.jsx';
import '../components/Chat/chatRooms.css';
import '../components/Chat/messages.css';

/**
 * Messages  (F6 · Design)
 *
 * Your conversations with people — only the ones that are really yours: chats
 * someone wrote in, and the one you have open. A chat that was opened by
 * accident and never used does not clutter the list. "New message" finds a
 * person in your organisation (people who blocked you, or whom you blocked,
 * never appear) and opens the chat with them; whether you may write to them
 * follows their privacy settings, as everywhere.
 *
 * The everyone-chat ("General") is not here: it belongs to live rooms, where
 * it is shown during the session.
 *
 * The page has a fixed height and the conversation scrolls inside it, so the
 * back button and the ⋯ menu stay in view however long a chat gets.
 */

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
  const [composing, setComposing] = useState(false);

  const api = useMemo(() => createChatApi(http), [http]);
  const self = useMemo(
    () => ({
      userId: session?.userId ?? '',
      displayName: session?.displayName ?? 'You',
      avatarUrl: session?.avatarUrl ?? null,
    }),
    [session],
  );

  const rooms = useConversations({
    api,
    socket: chatSocket ?? undefined,
    selfUserId: self.userId,
    enabled: Boolean(self.userId),
  });

  const [view, setView] = useState(conversationId ? { type: 'conversation', id: conversationId } : { type: 'list' });

  useEffect(() => {
    setView(conversationId ? { type: 'conversation', id: conversationId } : { type: 'list' });
  }, [conversationId]);

  const onViewChange = (next) => {
    // The everyone-chat lives in rooms, not here.
    if (next.type === 'lobby') return;
    setView(next);
    if (next.type === 'conversation') navigate(`/messages/${next.id}`);
    else if (conversationId) navigate('/messages');
  };

  const openWith = async (person) => {
    const conversation = await api.openDirect(person.userId);
    await rooms.refresh?.();
    setComposing(false);
    onViewChange({ type: 'conversation', id: conversation.conversationId });
  };

  // Unread from your conversations only — not from the everyone-chat.
  const unread = rooms.conversations.reduce((sum, item) => sum + (item.unreadCount || 0), 0);
  const inChat = view.type === 'conversation';

  return (
    <section className={`page messages-page${inChat ? ' is-chat' : ''}`}>
      <header className="messages-page__head">
        <h1>
          Messages {unread > 0 ? <span className="rooms-badge">{unread}</span> : null}
        </h1>
        {!inChat ? (
          <button type="button" className="btn btn--primary" onClick={() => setComposing((value) => !value)} aria-expanded={composing}>
            New message
          </button>
        ) : null}
      </header>
      {composing && !inChat ? <NewMessage onOpen={openWith} onClose={() => setComposing(false)} /> : null}
      <div className="messages-page__panel">
        <ChatRooms rooms={rooms} view={view} onViewChange={onViewChange} api={api} socket={chatSocket} self={self} showLobby={false} hideEmpty />
      </div>
    </section>
  );
}
__MSG_EOF__
echo "wrote apps/web/src/pages/MessagesPage.jsx"

mkdir -p apps/web/src/components/Chat
cat > apps/web/src/components/Chat/messages.css <<'__MSG_EOF__'
/* Messages page — see pages/MessagesPage.jsx.
 *
 * The page is exactly as tall as the window below the top bar. Inside it the
 * list or the open conversation scrolls on its own, so the conversation's
 * header — back button, name, ⋯ menu — never scrolls out of view.
 * Colours come from the app's variables (styles/theme.css), so this follows
 * the app's look.
 */

.messages-page {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-width: 820px;
  margin: 0 auto;
  height: calc(100dvh - 150px);
  min-height: 420px;
}
.app .app__content:has(.messages-page) { padding-bottom: 20px; }

.messages-page__head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex: 0 0 auto; }
.messages-page__head h1 { margin: 0; display: flex; align-items: center; gap: 10px; }

.messages-page__panel {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  border-radius: 18px;
  border: 1px solid var(--color-border, rgba(127, 140, 140, 0.25));
  background: var(--color-surface, #223a41);
  box-shadow: 0 18px 40px -28px rgba(0, 0, 0, 0.5);
  overflow: hidden;
}
.messages-page .rooms { flex: 1 1 auto; min-height: 0; gap: 0; }
.messages-page .rooms-list { padding: 8px; flex: 1 1 auto; min-height: 0; }
.messages-page .rooms-row { padding: 10px 12px; border-radius: 12px; grid-template-columns: 42px 1fr auto auto; gap: 12px; }
.messages-page .rooms-row:hover, .messages-page .rooms-row:focus-visible { background: rgba(127, 140, 140, 0.14); }
.messages-page .rooms-row__avatar { width: 42px; height: 42px; font-size: 16px; background: rgba(90, 123, 242, 0.22); color: inherit; }
.messages-page .rooms-row__name { font-size: 15.5px; }
.messages-page .rooms-row__preview { font-size: 13.5px; }
.messages-page .rooms-notice { padding: 18px 16px; margin: 0; }

/* The conversation header: always visible, large enough to hit. */
.messages-page .rooms-head {
  position: sticky;
  top: 0;
  z-index: 5;
  flex: 0 0 auto;
  gap: 12px;
  padding: 10px 12px;
  border-bottom: 1px solid var(--color-border, rgba(127, 140, 140, 0.25));
  background: var(--color-surface, #223a41);
}
.messages-page .rooms-head > .btn,
.messages-page .rooms-menu > .btn {
  min-width: 44px;
  min-height: 44px;
  padding: 0 14px;
  border-radius: 12px;
  font-size: 20px;
  line-height: 1;
}
.messages-page .rooms-head__title { font-size: 17px; }
.messages-page .rooms-menu__items { min-width: 260px; border-radius: 14px; border: 1px solid var(--color-border, rgba(127, 140, 140, 0.25)); }
.messages-page .rooms-menu__item { padding: 10px 12px; font-size: 14.5px; }

.messages-page .thread { flex: 1 1 auto; min-height: 0; }
.messages-page .thread__messages { padding: 16px; gap: 8px; }
.messages-page .bubble { max-width: 75%; padding: 9px 13px; font-size: 15px; line-height: 1.45; }
.messages-page .thread__composer { padding: 12px; background: rgba(127, 140, 140, 0.08); }
.messages-page .thread__composer input { padding: 11px 16px; font-size: 15px; }
.messages-page .thread__composer .btn { min-height: 44px; padding: 0 18px; border-radius: 999px; }
.messages-page .rooms-status { padding: 6px 14px; }

/* New message */
.msg-new {
  flex: 0 0 auto; display: grid; gap: 10px; padding: 16px; border-radius: 18px;
  border: 1px solid var(--color-border, rgba(127, 140, 140, 0.25)); background: var(--color-surface, #223a41);
  box-shadow: 0 18px 40px -28px rgba(0, 0, 0, 0.5);
  animation: msg-in 0.35s cubic-bezier(0.16, 1, 0.3, 1) both;
}
@keyframes msg-in { from { opacity: 0; transform: translateY(-6px); } to { opacity: 1; transform: none; } }
.msg-new__head { display: flex; align-items: center; justify-content: space-between; }
.msg-new__title { margin: 0; font-weight: 700; font-size: 16px; }
.msg-iconbtn { width: 40px; height: 40px; border: 0; border-radius: 12px; background: transparent; color: inherit; font-size: 24px; cursor: pointer; }
.msg-iconbtn:hover { background: rgba(127, 140, 140, 0.16); }
.msg-new__search {
  width: 100%; box-sizing: border-box; padding: 12px 14px; border-radius: 12px; font: inherit; font-size: 15px;
  border: 1px solid var(--color-border, rgba(127, 140, 140, 0.3)); background: var(--color-surface-2, rgba(127, 140, 140, 0.1)); color: inherit;
}
.msg-new__hint { margin: 0; font-size: 13.5px; color: var(--color-muted, #a8bcb9); }
.msg-new__error { margin: 0; font-size: 14px; color: #ef6b6f; }
.msg-new__results { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; max-height: 280px; overflow-y: auto; }
.msg-new__results button { width: 100%; display: flex; align-items: center; gap: 12px; padding: 8px 10px; border: 0; border-radius: 12px; background: transparent; color: inherit; font: inherit; font-size: 15px; text-align: left; cursor: pointer; }
.msg-new__results button:hover, .msg-new__results button:focus-visible { background: rgba(127, 140, 140, 0.14); }
.msg-new__avatar { width: 36px; height: 36px; border-radius: 50%; overflow: hidden; display: grid; place-items: center; background: rgba(90, 123, 242, 0.22); font-weight: 700; flex: 0 0 auto; }
.msg-new__avatar img { width: 100%; height: 100%; object-fit: cover; }

@media (max-width: 620px) {
  .messages-page { height: calc(100dvh - 120px); }
  .messages-page .bubble { max-width: 85%; }
}
@media (prefers-reduced-motion: reduce) { .msg-new { animation: none; } }
__MSG_EOF__
echo "wrote apps/web/src/components/Chat/messages.css"

cat > .messages-patch.mjs <<'__MSG_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Messages — edits to ChatRooms.jsx, which the lesson's chat panel shares.
 * Both new options default to today's behaviour, so inside a room nothing
 * changes. Every anchor must be found exactly once; otherwise nothing is
 * written and the installer stops.
 */

const plan = [
  {
    file: 'apps/web/src/components/Chat/ChatRooms.jsx',
    marker: 'showLobby',
    edits: [
      {
        name: 'options: the everyone-chat, and unused chats',
        find: 'export default function ChatRooms({ rooms, view, onViewChange, api, socket, self, roomId = null, sessionBlocks = null }) {\n',
        replace:
          '/**\n' +
          ' * showLobby  the everyone-chat ("General") at the top — inside a room only;\n' +
          ' *            the Messages page turns it off.\n' +
          ' * hideEmpty  leave out chats nobody has written in (except the open one).\n' +
          ' */\n' +
          'export default function ChatRooms({ rooms, view, onViewChange, api, socket, self, roomId = null, sessionBlocks = null, showLobby = true, hideEmpty = false }) {\n',
      },
      {
        name: 'the everyone-chat only where it belongs',
        find: '        {rooms.lobby ? (\n          <button\n',
        replace: '        {rooms.lobby && showLobby ? (\n          <button\n',
      },
      {
        name: 'no "Private chats" heading without the everyone-chat above it',
        find: '        <p className="rooms-list__group">Private chats</p>\n',
        replace: '        {showLobby ? <p className="rooms-list__group">Private chats</p> : null}\n',
      },
      {
        name: 'only chats that are really in use',
        find: '        {rooms.conversations.length === 0 && !rooms.loading ? (\n',
        replace: '        {visibleConversations.length === 0 && !rooms.loading ? (\n',
      },
      {
        name: 'the empty list says how to start',
        find: "              : 'No private chats yet. Open a lesson and click a person to start one.'}\n",
        replace: "              : hideEmpty\n                ? 'No conversations yet. Start one with “New message”.'\n                : 'No private chats yet. Open a lesson and click a person to start one.'}\n",
      },
      {
        name: 'list the visible ones',
        find: '        {rooms.conversations.map((conversation) => {\n',
        replace: '        {visibleConversations.map((conversation) => {\n',
      },
      {
        name: 'which ones are visible',
        find: '  /* ---- the list ---- */\n',
        replace:
          '  /* ---- the list ---- */\n' +
          '\n' +
          '  const visibleConversations = hideEmpty\n' +
          '    ? rooms.conversations.filter((c) => c.lastMessageAt || c.unreadCount > 0 || c.conversationId === openId)\n' +
          '    : rooms.conversations;\n',
      },
    ],
  }
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
__MSG_EOF__
node .messages-patch.mjs
rm -f .messages-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo "A file did not pass its check (see above). Undo with: bash messages-install.sh --restore" >&2
  exit 1
fi
echo
echo "Messages updated. Vite picks it up on its own; reload the page with Ctrl+Shift+R."
echo "No server change and no migration: the API does not need a restart."