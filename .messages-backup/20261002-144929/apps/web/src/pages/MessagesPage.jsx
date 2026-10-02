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
 *
 * Wide screens show the list and the open conversation side by side, like a
 * messenger on the web; narrow screens show one at a time, with a back button.
 */

const WIDE = '(min-width: 960px)';

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
  const [composing, setComposing] = useState(false);
  const wide = useWide();

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
  const shared = { rooms, api, socket: chatSocket, self, showLobby: false, hideEmpty: true };

  return (
    <section className={`page messages-page${inChat ? ' is-chat' : ''}${wide ? ' is-wide' : ''}`}>
      <header className="messages-page__head">
        <h1>
          Messages {unread > 0 ? <span className="rooms-badge">{unread}</span> : null}
        </h1>
        {!inChat || wide ? (
          <button type="button" className="btn btn--primary" onClick={() => setComposing((value) => !value)} aria-expanded={composing}>
            New message
          </button>
        ) : null}
      </header>
      {composing && (!inChat || wide) ? <NewMessage onOpen={openWith} onClose={() => setComposing(false)} /> : null}
      {wide ? (
        <div className="messages-split">
          {/* The list first: of the two, the open chat must be the last to tell `rooms` what is open. */}
          <div className="messages-page__panel messages-split__list">
            <ChatRooms {...shared} view={{ type: 'list' }} onViewChange={onViewChange} activeId={inChat ? view.id : null} />
          </div>
          <div className="messages-page__panel messages-split__chat">
            {inChat ? (
              <ChatRooms {...shared} view={view} onViewChange={onViewChange} />
            ) : (
              <div className="messages-split__empty">
                <span aria-hidden="true">💬</span>
                <p className="messages-split__title">Choose a conversation</p>
                <p className="muted">Or start one with “New message”.</p>
              </div>
            )}
          </div>
        </div>
      ) : (
        <div className="messages-page__panel">
          <ChatRooms {...shared} view={view} onViewChange={onViewChange} />
        </div>
      )}
    </section>
  );
}
