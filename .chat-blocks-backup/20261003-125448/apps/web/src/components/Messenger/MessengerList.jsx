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
