import { useCallback, useEffect, useRef, useState } from 'react';
import { isMutedNow, otherParticipant, titleOf, useChat } from '@classroom/core-client';
import './chatRooms.css';

/**
 * "Rooms": the default chatroom and every private chat, one under the other,
 * like a messenger. Used inside a lesson (ClassroomChatPanel) and on the
 * Messages page, so both behave the same.
 *
 *   list        the default chatroom first, then private chats by activity,
 *               each with its unread badge and a muted mark
 *   a chat      opened by clicking its row — and only then; a back arrow
 *               returns to the list. The ⋯ menu mutes (1 hour, 8 hours,
 *               1 day, until turned back on), deletes the chat for you (not the
 *               default chatroom), and inside a lesson blocks the other person
 *               for this lesson.
 *
 * The component is controlled: the caller owns `view` so it can open a chat it
 * just created (after the "Send a private message?" confirmation) and owns
 * the useConversations state so the tab badge can show the total.
 */

const time = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
const day = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' });

const HOUR = 60 * 60 * 1000;
export const MUTE_CHOICES = [
  { id: '1h', label: 'Mute for 1 hour', ms: HOUR },
  { id: '8h', label: 'Mute for 8 hours', ms: 8 * HOUR },
  { id: '1d', label: 'Mute for 1 day', ms: 24 * HOUR },
  { id: 'on', label: 'Mute until I turn it back on', ms: null },
];

const untilFor = (choice) => (choice.ms ? new Date(Date.now() + choice.ms).toISOString() : null);

function shortTime(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  return date.toDateString() === new Date().toDateString() ? time.format(date) : day.format(date);
}

function mutedLabel(item) {
  if (!isMutedNow(item)) return null;
  return item.mutedUntil ? `Muted until ${shortTime(item.mutedUntil)}` : 'Muted';
}

/* ------------------------------------------------------------------ *
 * Lesson blocks
 * ------------------------------------------------------------------ */

/** Whom I have blocked in this lesson. Nothing without a roomId. */
export function useSessionBlocks({ api, roomId }) {
  const [blocked, setBlocked] = useState(() => new Set());

  useEffect(() => {
    if (!roomId) return undefined;
    let cancelled = false;
    api
      .listSessionBlocks(roomId)
      .then((result) => !cancelled && setBlocked(new Set(result.blockedUserIds)))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [api, roomId]);

  const block = useCallback(
    async (userId) => {
      await api.blockInSession(roomId, userId);
      setBlocked((current) => new Set(current).add(userId));
    },
    [api, roomId],
  );

  const unblock = useCallback(
    async (userId) => {
      await api.unblockInSession(roomId, userId);
      setBlocked((current) => {
        const next = new Set(current);
        next.delete(userId);
        return next;
      });
    },
    [api, roomId],
  );

  return { enabled: Boolean(roomId), blocked, block, unblock };
}

/* ------------------------------------------------------------------ *
 * The ⋯ menu
 * ------------------------------------------------------------------ */

function ChatMenu({ items }) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const close = (event) => {
      if (!wrapRef.current?.contains(event.target)) setOpen(false);
    };
    const onKey = (event) => event.key === 'Escape' && setOpen(false);
    document.addEventListener('pointerdown', close);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('pointerdown', close);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  return (
    <span className="rooms-menu" ref={wrapRef}>
      <button
        type="button"
        className="btn btn--tiny"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Chat options"
        onClick={() => setOpen((value) => !value)}
      >
        ⋯
      </button>
      {open ? (
        <div className="rooms-menu__items" role="menu">
          {items.map((item) =>
            item.separator ? (
              <hr key={item.id} className="rooms-menu__sep" />
            ) : (
              <button
                key={item.id}
                type="button"
                role="menuitem"
                className={`rooms-menu__item${item.danger ? ' rooms-menu__item--danger' : ''}`}
                onClick={() => {
                  setOpen(false);
                  item.run();
                }}
              >
                {item.label}
              </button>
            ),
          )}
        </div>
      ) : null}
    </span>
  );
}

/* ------------------------------------------------------------------ *
 * One thread
 * ------------------------------------------------------------------ */

/**
 * One thread, whichever target it is pointed at. A private chat and the
 * default chatroom differ only in `target`.
 */
export function ChatThread({ api, socket, self, target, placeholder, emptyText, disabledReason = '' }) {
  const [draft, setDraft] = useState('');
  const bottomRef = useRef(null);

  const { messages, loading, hasMore, loadOlder, typingUserIds, throttledUntil, send, retry, setTyping } =
    useChat({ api, socket: socket ?? undefined, target, self });

  const throttled = throttledUntil !== null && throttledUntil > Date.now();
  const disabled = throttled || Boolean(disabledReason);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: 'end' });
  }, [messages.length]);

  const submit = async (event) => {
    event.preventDefault();
    const body = draft.trim();
    if (!body || disabled) return;
    setDraft('');
    setTyping(false);
    await send({ body });
  };

  return (
    <div className="thread">
      <div className="thread__messages">
        {hasMore && (
          <button type="button" className="btn btn--tiny" onClick={() => loadOlder()}>
            Load earlier messages
          </button>
        )}

        {loading && <p className="thread__empty">Loading…</p>}
        {!loading && messages.length === 0 && <p className="thread__empty">{emptyText}</p>}

        {messages.map((message) => (
          <div
            key={message.clientMessageId ?? message.messageId}
            className={[
              'bubble',
              message.author?.userId === self.userId ? 'bubble--mine' : '',
              message.delivery === 'failed' ? 'bubble--failed' : '',
              message.delivery === 'sending' ? 'bubble--pending' : '',
            ]
              .filter(Boolean)
              .join(' ')}
          >
            {message.author?.userId !== self.userId && (
              <span className="bubble__author">{message.author?.displayName}</span>
            )}
            <span className="bubble__body">{message.deletedAt ? <em>Message deleted</em> : message.body}</span>
            {message.delivery === 'failed' && (
              <button type="button" className="bubble__retry" onClick={() => retry(message.clientMessageId)}>
                Not sent — retry
              </button>
            )}
          </div>
        ))}
        <div ref={bottomRef} />
      </div>

      {typingUserIds.length > 0 && (
        <p className="thread__typing">
          {typingUserIds.length === 1 ? 'Someone is typing…' : `${typingUserIds.length} people are typing…`}
        </p>
      )}

      {disabledReason ? <p className="rooms-notice">{disabledReason}</p> : null}

      <form className="thread__composer" onSubmit={submit}>
        <input
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value);
            setTyping(event.target.value.length > 0);
          }}
          placeholder={throttled ? 'Slow mode — wait a moment' : placeholder}
          disabled={disabled}
          aria-label={placeholder}
        />
        <button type="submit" className="btn btn--tiny" disabled={!draft.trim() || disabled}>
          Send
        </button>
      </form>
    </div>
  );
}

/* ------------------------------------------------------------------ *
 * The list and the open chat
 * ------------------------------------------------------------------ */

export default function ChatRooms({ rooms, view, onViewChange, api, socket, self, roomId = null, sessionBlocks = null }) {
  const [status, setStatus] = useState(null);

  const openId = view.type === 'lobby' ? 'lobby' : view.type === 'conversation' ? view.id : null;
  const { setOpen } = rooms;
  useEffect(() => {
    setOpen(openId);
    return () => setOpen(null);
  }, [openId, setOpen]);

  const run = async (fn, doneText) => {
    setStatus(null);
    try {
      await fn();
      if (doneText) setStatus({ text: doneText });
    } catch (cause) {
      setStatus({ error: true, text: cause?.detail ?? cause?.message ?? 'That did not work. Try again.' });
    }
  };

  const muteItems = (item, onMute, onUnmute) =>
    isMutedNow(item)
      ? [{ id: 'unmute', label: 'Turn notifications back on', run: () => run(onUnmute, 'Notifications are on again.') }]
      : MUTE_CHOICES.map((choice) => ({
          id: choice.id,
          label: choice.label,
          run: () => run(() => onMute(untilFor(choice)), 'Muted.'),
        }));

  /* ---- an open chat ---- */

  if (view.type === 'lobby' && rooms.lobby) {
    const lobby = rooms.lobby;
    return (
      <div className="rooms">
        <header className="rooms-head">
          <button type="button" className="btn btn--tiny" onClick={() => onViewChange({ type: 'list' })} aria-label="Back to Rooms">
            ←
          </button>
          <p className="rooms-head__title">
            # {lobby.name}
            {mutedLabel(lobby) ? <span className="rooms-head__sub">{mutedLabel(lobby)}</span> : null}
          </p>
          <ChatMenu items={muteItems(lobby, (until) => rooms.muteLobby(until), () => rooms.unmuteLobby())} />
        </header>
        {status ? <p className={`rooms-status${status.error ? ' rooms-status--error' : ''}`}>{status.text}</p> : null}
        <ChatThread
          key={`ch:${lobby.channelId}`}
          api={api}
          socket={socket}
          self={self}
          target={{ kind: 'channel', channelId: lobby.channelId }}
          placeholder="Message everyone"
          emptyText="Nothing here yet. Say hello."
        />
      </div>
    );
  }

  if (view.type === 'conversation') {
    const conversation = rooms.conversations.find((c) => c.conversationId === view.id);
    if (!conversation) {
      return (
        <div className="rooms">
          <p className="rooms-notice">This chat is no longer in your list.</p>
          <button type="button" className="btn btn--tiny" onClick={() => onViewChange({ type: 'list' })}>
            Back to Rooms
          </button>
        </div>
      );
    }

    const title = titleOf(conversation, self.userId);
    const other = conversation.kind === 'direct' ? otherParticipant(conversation, self.userId) : null;
    const blockedHere = Boolean(other && sessionBlocks?.enabled && sessionBlocks.blocked.has(other.userId));

    const items = [
      ...muteItems(
        conversation,
        (until) => rooms.mute(conversation.conversationId, until),
        () => rooms.unmute(conversation.conversationId),
      ),
      { id: 'sep-1', separator: true },
      ...(other && sessionBlocks?.enabled
        ? [
            blockedHere
              ? { id: 'unblock', label: `Unblock ${title} for this lesson`, run: () => run(() => sessionBlocks.unblock(other.userId), `${title} can write to you again.`) }
              : { id: 'block', label: `Block ${title} for this lesson`, danger: true, run: () => run(() => sessionBlocks.block(other.userId), `${title} cannot write to you during this lesson.`) },
          ]
        : []),
      {
        id: 'delete',
        label: 'Delete chat for me',
        danger: true,
        run: () => {
          const sure = window.confirm(
            `Delete the chat with ${title}? It disappears for you only — ${title} keeps it. If they write again, it comes back without the old messages.`,
          );
          if (!sure) return;
          run(async () => {
            await rooms.remove(conversation.conversationId);
            onViewChange({ type: 'list' });
          });
        },
      },
    ];

    return (
      <div className="rooms">
        <header className="rooms-head">
          <button type="button" className="btn btn--tiny" onClick={() => onViewChange({ type: 'list' })} aria-label="Back to Rooms">
            ←
          </button>
          <p className="rooms-head__title">
            {title}
            {mutedLabel(conversation) ? <span className="rooms-head__sub">{mutedLabel(conversation)}</span> : null}
          </p>
          <ChatMenu items={items} />
        </header>
        {status ? <p className={`rooms-status${status.error ? ' rooms-status--error' : ''}`}>{status.text}</p> : null}
        <ChatThread
          key={`dm:${conversation.conversationId}`}
          api={api}
          socket={socket}
          self={self}
          target={{ kind: 'conversation', conversationId: conversation.conversationId }}
          placeholder={`Message ${title}`}
          emptyText={`This is the start of your conversation with ${title}.`}
          disabledReason={blockedHere ? `You blocked ${title} for this lesson. Unblock them in the ⋯ menu to write again.` : ''}
        />
      </div>
    );
  }

  /* ---- the list ---- */

  return (
    <div className="rooms">
      {rooms.error && !rooms.lobby && rooms.conversations.length === 0 ? (
        <div className="rooms-notice">
          <p>The chats could not be loaded.</p>
          <button type="button" className="btn btn--tiny" onClick={() => rooms.refresh()}>
            Try again
          </button>
        </div>
      ) : null}

      {rooms.loading && !rooms.lobby ? <p className="rooms-notice">Loading…</p> : null}

      <div className="rooms-list" role="list">
        {rooms.lobby ? (
          <button
            type="button"
            role="listitem"
            className={`rooms-row${rooms.lobby.unreadCount ? ' rooms-row--unread' : ''}`}
            onClick={() => onViewChange({ type: 'lobby' })}
          >
            <span className="rooms-row__avatar" aria-hidden="true">#</span>
            <span className="rooms-row__main">
              <span className="rooms-row__name">{rooms.lobby.name}</span>
              <span className="rooms-row__preview">{mutedLabel(rooms.lobby) ?? 'Default chatroom · everyone'}</span>
            </span>
            <span className="rooms-row__time">{shortTime(rooms.lobby.lastMessageAt)}</span>
            {rooms.lobby.unreadCount ? (
              <span className={`rooms-badge${isMutedNow(rooms.lobby) ? ' rooms-badge--muted' : ''}`}>
                {rooms.lobby.unreadCount > 99 ? '99+' : rooms.lobby.unreadCount}
              </span>
            ) : null}
          </button>
        ) : null}

        <p className="rooms-list__group">Private chats</p>

        {rooms.conversations.length === 0 && !rooms.loading ? (
          <p className="rooms-notice">
            {roomId
              ? 'No private chats yet. Click a person under People to start one.'
              : 'No private chats yet. Open a lesson and click a person to start one.'}
          </p>
        ) : null}

        {rooms.conversations.map((conversation) => {
          const title = titleOf(conversation, self.userId);
          const preview = conversation.lastMessagePreview;
          const muted = isMutedNow(conversation);
          return (
            <button
              key={conversation.conversationId}
              type="button"
              role="listitem"
              className={`rooms-row${conversation.unreadCount ? ' rooms-row--unread' : ''}`}
              onClick={() => onViewChange({ type: 'conversation', id: conversation.conversationId })}
            >
              <span className="rooms-row__avatar" aria-hidden="true">{title.charAt(0).toUpperCase()}</span>
              <span className="rooms-row__main">
                <span className="rooms-row__name">
                  {title}
                  {muted ? <span className="rooms-row__muted" title={mutedLabel(conversation)}> 🔕</span> : null}
                </span>
                <span className="rooms-row__preview">
                  {preview ? `${preview.authorId === self.userId ? 'You: ' : ''}${preview.body}` : 'No messages yet'}
                </span>
              </span>
              <span className="rooms-row__time">{shortTime(conversation.lastMessageAt ?? conversation.createdAt)}</span>
              {conversation.unreadCount ? (
                <span className={`rooms-badge${muted ? ' rooms-badge--muted' : ''}`}>
                  {conversation.unreadCount > 99 ? '99+' : conversation.unreadCount}
                </span>
              ) : null}
            </button>
          );
        })}
      </div>

      {status ? <p className={`rooms-status${status.error ? ' rooms-status--error' : ''}`}>{status.text}</p> : null}
    </div>
  );
}
