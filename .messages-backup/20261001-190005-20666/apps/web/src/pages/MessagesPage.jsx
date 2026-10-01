import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createChatApi, useConversations, useCore } from '@classroom/core-client';
import ChatRooms from '../components/Chat/ChatRooms.jsx';
import '../components/Chat/chatRooms.css';

/**
 * Messages  (F6)
 *
 * The same Rooms list as inside a lesson — the default chatroom and every
 * private chat — for reading and answering outside a lesson. /messages/:id
 * opens one chat directly, so a link to a conversation works.
 *
 * Blocking for a lesson is not offered here: it belongs to a running lesson.
 * New private chats start from a person in a lesson.
 */
export default function MessagesPage() {
  const { http, chatSocket, session } = useCore();
  const { conversationId } = useParams();
  const navigate = useNavigate();

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
    setView(next);
    if (next.type === 'conversation') navigate(`/messages/${next.id}`);
    else if (conversationId) navigate('/messages');
  };

  return (
    <section className="page messages-page">
      <h1>Messages {rooms.unreadTotal > 0 ? <span className="rooms-badge">{rooms.unreadTotal}</span> : null}</h1>
      <ChatRooms rooms={rooms} view={view} onViewChange={onViewChange} api={api} socket={chatSocket} self={self} />
    </section>
  );
}
