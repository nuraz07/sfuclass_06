import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  createChatApi,
  createProfileApi,
  titleOf,
  useConversations,
  useCore,
} from '@classroom/core-client';

import ParticipantList from './ParticipantList.jsx';
import ChatRooms, { useSessionBlocks } from '../Chat/ChatRooms.jsx';
import '../Chat/chatRooms.css';

/**
 * The sidebar of a lesson  (F1, F6)
 *
 * Two tabs, and only two:
 *
 *   People   who is here. Clicking a person opens a small dialog —
 *            "Send a private message?" and "Block for this lesson" — instead
 *            of opening a chat straight away.
 *   Rooms    the default chatroom and every private chat, one under the other
 *            (ChatRooms). A chat opens when its row is clicked, nowhere else.
 *
 * A private chat is created only after the confirmation in the dialog, and
 * appears in Rooms under the default chatroom. The other person sees it once
 * the first message arrives — with a badge on the Rooms tab and a short notice
 * at the top, so nobody has to click the sender to find out they were written
 * to. Muted chats count neither in the badge nor in the notice.
 */
export default function ClassroomChatPanel({ roomId, peers, selfPeerId, canModerate, onHostAction }) {
  const { http, chatSocket, session } = useCore();

  // One instance each for the life of the panel.
  const api = useMemo(() => createChatApi(http), [http]);
  const profiles = useMemo(() => createProfileApi(http), [http]);

  const self = useMemo(
    () => ({
      userId: session?.userId ?? '',
      displayName: session?.displayName ?? 'You',
      avatarUrl: session?.avatarUrl ?? null,
    }),
    [session],
  );

  const [tab, setTab] = useState('people');
  const [view, setView] = useState({ type: 'list' });
  const [person, setPerson] = useState(null);
  const [toast, setToast] = useState(null);
  const toastTimer = useRef(null);

  const onIncoming = useCallback(
    (conversation) => {
      setToast({ conversationId: conversation.conversationId, title: titleOf(conversation, self.userId) });
      window.clearTimeout(toastTimer.current);
      toastTimer.current = window.setTimeout(() => setToast(null), 8_000);
    },
    [self.userId],
  );
  useEffect(() => () => window.clearTimeout(toastTimer.current), []);

  const rooms = useConversations({
    api,
    socket: chatSocket ?? undefined,
    selfUserId: self.userId,
    enabled: Boolean(self.userId),
    onIncoming,
  });
  const sessionBlocks = useSessionBlocks({ api, roomId });

  const showConversation = useCallback((conversationId) => {
    setTab('rooms');
    setView({ type: 'conversation', id: conversationId });
    setToast(null);
  }, []);

  return (
    <aside className="panel">
      <nav className="panel__tabs" role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={tab === 'people'}
          className={tab === 'people' ? 'panel__tab is-active' : 'panel__tab'}
          onClick={() => setTab('people')}
        >
          People <span className="panel__count">{peers.length}</span>
        </button>

        <button
          type="button"
          role="tab"
          aria-selected={tab === 'rooms'}
          className={tab === 'rooms' ? 'panel__tab is-active' : 'panel__tab'}
          onClick={() => setTab('rooms')}
        >
          Rooms
          {rooms.unreadTotal > 0 ? (
            <span className="rooms-badge" aria-label={`${rooms.unreadTotal} unread`}>
              {rooms.unreadTotal > 99 ? '99+' : rooms.unreadTotal}
            </span>
          ) : null}
        </button>
      </nav>

      {toast && !(tab === 'rooms' && view.type === 'conversation' && view.id === toast.conversationId) ? (
        <button type="button" className="rooms-toast" onClick={() => showConversation(toast.conversationId)}>
          <span className="rooms-toast__text">New message from {toast.title}</span>
          <span aria-hidden="true">Open</span>
        </button>
      ) : null}

      {tab === 'people' && (
        <ParticipantList
          peers={peers}
          selfPeerId={selfPeerId}
          canModerate={canModerate}
          onHostAction={onHostAction}
          onMessage={(peer) => setPerson(peer)}
        />
      )}

      {tab === 'rooms' && (
        <ChatRooms
          rooms={rooms}
          view={view}
          onViewChange={setView}
          api={api}
          socket={chatSocket}
          self={self}
          roomId={roomId}
          sessionBlocks={sessionBlocks}
        />
      )}

      {person ? (
        <PersonDialog
          peer={person}
          roomId={roomId}
          profiles={profiles}
          rooms={rooms}
          sessionBlocks={sessionBlocks}
          onClose={() => setPerson(null)}
          onOpened={(conversation) => {
            setPerson(null);
            showConversation(conversation.conversationId);
          }}
        />
      ) : null}
    </aside>
  );
}

/**
 * What clicking a person offers. Nothing is created until the person confirms:
 * "Send a private message" opens (or reopens) the chat and shows it in Rooms.
 * Whether writing is allowed comes from the server, with the same rule the send
 * path enforces, so a button that is on here does not fail afterwards.
 */
function PersonDialog({ peer, roomId, profiles, rooms, sessionBlocks, onClose, onOpened }) {
  const dialogRef = useRef(null);
  const name = peer.user?.displayName ?? 'this person';
  const userId = peer.user?.userId;

  const [profile, setProfile] = useState(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState(null);

  const blockedHere = sessionBlocks.enabled && sessionBlocks.blocked.has(userId);

  useEffect(() => {
    const el = dialogRef.current;
    if (el && !el.open) el.showModal();
  }, []);

  useEffect(() => {
    let cancelled = false;
    profiles
      .get(userId, { roomId })
      .then((result) => !cancelled && setProfile(result))
      .catch(() => !cancelled && setProfile({ canMessage: true, cannotMessageReason: null }));
    return () => {
      cancelled = true;
    };
  }, [profiles, userId, roomId, blockedHere]);

  const act = async (fn) => {
    setBusy(true);
    setMessage(null);
    try {
      await fn();
    } catch (cause) {
      setMessage(cause?.detail ?? cause?.message ?? 'That did not work. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const openChat = () =>
    act(async () => {
      const conversation = await rooms.open(userId, { roomId });
      onOpened(conversation);
    });

  const canMessage = profile ? profile.canMessage && !blockedHere : false;

  return (
    <dialog
      ref={dialogRef}
      className="person-dialog"
      aria-label={name}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <div className="person-dialog__body">
        <h2 className="person-dialog__title">{name}</h2>

        {!profile ? <p className="person-dialog__hint">Checking…</p> : null}

        {profile ? (
          <p className="person-dialog__hint">
            {blockedHere
              ? `You blocked ${name} for this lesson.`
              : canMessage
                ? `Send ${name} a private message? The chat appears under Rooms.`
                : (profile.cannotMessageReason ?? `${name} is not accepting private messages.`)}
          </p>
        ) : null}

        {message ? <p className="person-dialog__hint rooms-status--error">{message}</p> : null}

        <div className="person-dialog__actions">
          <button type="button" className="btn" disabled={busy || !canMessage} onClick={openChat}>
            {busy ? 'Opening…' : 'Send a private message'}
          </button>

          {sessionBlocks.enabled ? (
            blockedHere ? (
              <button type="button" className="btn" disabled={busy} onClick={() => act(() => sessionBlocks.unblock(userId))}>
                Unblock for this lesson
              </button>
            ) : (
              <button
                type="button"
                className="btn btn--danger"
                disabled={busy}
                onClick={() =>
                  act(async () => {
                    await sessionBlocks.block(userId);
                    setMessage(`${name} cannot write to you privately until this lesson ends.`);
                  })
                }
              >
                Block for this lesson
              </button>
            )
          ) : null}

          <button type="button" className="btn btn--tiny" onClick={onClose}>
            Cancel
          </button>
        </div>
      </div>
    </dialog>
  );
}
