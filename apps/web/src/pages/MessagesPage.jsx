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
