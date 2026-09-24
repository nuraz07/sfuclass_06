import { useCallback, useEffect, useMemo, useState } from 'react';
import { createChatApi, useChat, useCore } from '@classroom/core-client';

import ParticipantList from './ParticipantList.jsx';

/**
 * Chat inside a lesson  (F1, F6)
 *
 * Three tabs over one sidebar: who is here, the room's own channel, and a
 * direct message with one of them.
 *
 * ChatDock is deliberately not reused. It is a floating panel built for the app
 * shell, and it is hidden inside a lesson on purpose — two chats competing for
 * the same screen while someone is teaching is one too many. This is the same
 * data in a layout that fits beside a video grid.
 *
 * The DM is opened from the participant list rather than from a separate "new
 * message" flow, which is the same rule the rest of the product follows:
 * clicking a person is how a conversation starts, everywhere.
 */
export default function ClassroomChatPanel({
  roomId,
  peers,
  selfPeerId,
  canModerate,
  onHostAction,
}) {
  const { http, chatSocket, session } = useCore();
  const [tab, setTab] = useState('people');
  /** { conversationId, displayName } while a DM is open. */
  const [dm, setDm] = useState(null);
  const [roomChannelId, setRoomChannelId] = useState(null);
  const [roomChannelError, setRoomChannelError] = useState(false);
  const [roomChannelRetry, setRoomChannelRetry] = useState(0);

  // One instance for the life of the panel; a new one per render would reset
  // every request the hook has in flight.
  const api = useMemo(() => createChatApi(http), [http]);

  // Resolved once when the tab is first opened, not on mount: somebody who
  // never opens the chat should not create a channel by arriving.
  // Channels are provisioned server-side — SpaceService creates them when a
  // course is published — so this finds one rather than creating it. The
  // tenant's public channel is the honest fallback for a room that has no
  // course behind it yet.
  useEffect(() => {
    if (tab !== 'room' || roomChannelId) return;
    setRoomChannelError(false);
    void api
      .listChannels({ scope: 'public' })
      .then((result) => {
        setRoomChannelId(result.items[0]?.channelId ?? null);
      })
      .catch(() => setRoomChannelError(true));
  }, [api, tab, roomChannelId, roomChannelRetry]);

  const self = useMemo(
    () => ({
      userId: session?.userId ?? '',
      displayName: session?.displayName ?? 'You',
      avatarUrl: session?.avatarUrl ?? null,
    }),
    [session]
  );

  const openDirectMessage = useCallback(
    async (peer) => {
      try {
        // Idempotent on the server: it returns the existing conversation or
        // creates one. There is no second code path for "first message".
        const conversation = await http.post('/messaging/conversations/direct', {
          userId: peer.user.userId,
        });
        setDm({
          conversationId: conversation.conversationId ?? conversation.id,
          displayName: peer.user.displayName,
        });
        setTab('direct');
      } catch {
        // Blocked, or DM policy forbids it. The server decides; saying so
        // without detail is deliberate — "this person blocked you" is not
        // information they agreed to share.
        setDm({ conversationId: null, displayName: peer.user.displayName });
        setTab('direct');
      }
    },
    [http]
  );

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
          aria-selected={tab === 'room'}
          className={tab === 'room' ? 'panel__tab is-active' : 'panel__tab'}
          onClick={() => setTab('room')}
        >
          Room
        </button>

        {dm && (
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'direct'}
            className={tab === 'direct' ? 'panel__tab is-active' : 'panel__tab'}
            onClick={() => setTab('direct')}
          >
            {dm.displayName.split(' ')[0]}
          </button>
        )}
      </nav>

      {tab === 'people' && (
        <ParticipantList
          peers={peers}
          selfPeerId={selfPeerId}
          canModerate={canModerate}
          onHostAction={onHostAction}
          onMessage={openDirectMessage}
        />
      )}

      {/*
        Keyed so switching target tears the hook down and rebuilds it. Without a
        key, React reuses the instance and the new target inherits the old
        thread's messages for a frame.
      */}
      {/*
        A channel, not `{ kind: 'room' }`. The socket gateway routes a room
        target, but messaging.routes.js exposes no HTTP endpoint for one — and
        the first page of history always comes over HTTP. A course-scoped
        channel is the same thing with a persistence story the rest of the
        messaging domain already understands.
      */}
      {tab === 'room' && roomChannelId && (
        <ChatThread
          key={`ch:${roomChannelId}`}
          api={api}
          socket={chatSocket}
          self={self}
          target={{ kind: 'channel', channelId: roomChannelId }}
          placeholder="Message everyone in this lesson"
          emptyText="Nothing here yet. Whatever is written stays with the lesson."
        />
      )}

      {tab === 'room' && !roomChannelId && (
        roomChannelError ? (
          <div className="panel__notice">
            <p>Unable to open the lesson chat.</p>
            <button
              type="button"
              className="btn btn--tiny"
              onClick={() => {
                setRoomChannelError(false);
                setRoomChannelRetry((value) => value + 1);
              }}
            >
              Try again
            </button>
          </div>
        ) : (
          <p className="panel__notice">Opening the lesson channel…</p>
        )
      )}

      {tab === 'direct' &&
        (dm?.conversationId ? (
          <ChatThread
            key={`dm:${dm.conversationId}`}
            api={api}
            socket={chatSocket}
            self={self}
            target={{ kind: 'conversation', conversationId: dm.conversationId }}
            placeholder={`Message ${dm.displayName}`}
            emptyText={`This is the start of your conversation with ${dm.displayName}.`}
          />
        ) : (
          <p className="panel__notice">
            You cannot message {dm?.displayName} right now.
          </p>
        ))}
    </aside>
  );
}

/**
 * One thread, whichever target it is pointed at. A direct message and a room
 * channel differ only in what they are addressed to, so they differ only in
 * the `target` prop here.
 */
function ChatThread({ api, socket, self, target, placeholder, emptyText }) {
  const [draft, setDraft] = useState('');

  const {
    messages,
    loading,
    hasMore,
    loadOlder,
    typingUserIds,
    throttledUntil,
    send,
    retry,
    setTyping,
  } = useChat({ api, socket: socket ?? undefined, target, self });

  const throttled = throttledUntil !== null && throttledUntil > Date.now();

  const submit = async (event) => {
    event.preventDefault();
    const body = draft.trim();
    if (!body || throttled) return;
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
        {!loading && messages.length === 0 && (
          <p className="thread__empty">{emptyText}</p>
        )}

        {messages.map((message) => (
          <div
            key={message.clientMessageId ?? message.messageId}
            className={[
              'bubble',
              message.author.userId === self.userId ? 'bubble--mine' : '',
              // A failed send keeps its bubble rather than vanishing: losing
              // what somebody wrote is worse than showing it did not arrive.
              message.delivery === 'failed' ? 'bubble--failed' : '',
              message.delivery === 'sending' ? 'bubble--pending' : '',
            ]
              .filter(Boolean)
              .join(' ')}
          >
            {message.author.userId !== self.userId && (
              <span className="bubble__author">{message.author.displayName}</span>
            )}

            <span className="bubble__body">
              {message.deletedAt ? <em>Message deleted</em> : message.body}
            </span>

            {message.delivery === 'failed' && (
              <button
                type="button"
                className="bubble__retry"
                onClick={() => retry(message.clientMessageId)}
              >
                Not sent — retry
              </button>
            )}
          </div>
        ))}
      </div>

      {typingUserIds.length > 0 && (
        <p className="thread__typing">
          {typingUserIds.length === 1
            ? 'Someone is typing…'
            : `${typingUserIds.length} people are typing…`}
        </p>
      )}

      <form className="thread__composer" onSubmit={submit}>
        <input
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value);
            setTyping(event.target.value.length > 0);
          }}
          placeholder={throttled ? 'Slow mode — wait a moment' : placeholder}
          disabled={throttled}
          aria-label={placeholder}
        />
        <button
          type="submit"
          className="btn btn--tiny"
          disabled={!draft.trim() || throttled}
        >
          Send
        </button>
      </form>
    </div>
  );
}