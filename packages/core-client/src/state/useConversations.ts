/**
 * useConversations  (F6)
 *
 * The "Rooms" list: the lesson's default chatroom (the tenant lobby) and every
 * private chat of the signed-in person, newest activity first, each with its
 * own unread count and mute state.
 *
 * Kept live without subscribing to every thread: the server pushes each
 * changed row to the person's own socket room (`chat:conversation.created` /
 * `.updated`, see chatGateway.notifyConversationUpdated), with that person's
 * unread count already in it. A chat someone else opened appears here with its
 * first message; a chat you deleted comes back when someone writes again.
 *
 * The lobby's badge is refreshed on focus and every 30 seconds rather than by
 * subscription: subscriptions belong to the open thread (useChat), and two
 * owners of one subscription would unsubscribe each other.
 *
 * What is open is reported with setOpen(): an open thread counts as read here
 * at once, even before the server's read marker catches up.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ChatEvents } from '@classroom/contracts';
import type { ChatApi, ChannelView, ConversationView } from '../api/chatApi.js';
import type { SignalingTransport } from '../rtc/SfuClient.js';

const { CHAT_SERVER_EVENTS: SERVER } = ChatEvents;

const REFRESH_MS = 30_000;
const LOBBY = 'lobby';

// ---------------------------------------------------------------------------
// Pure helpers (exported for tests and for components)
// ---------------------------------------------------------------------------

/** A mute whose end time has passed is no longer a mute. */
export const isMutedNow = (
  item: { muted?: boolean; mutedUntil?: string | null } | null | undefined,
  now = Date.now(),
): boolean => Boolean(item?.muted) && (!item?.mutedUntil || Date.parse(item.mutedUntil) > now);

const activityOf = (conversation: ConversationView): number =>
  Date.parse(conversation.lastMessageAt ?? conversation.createdAt) || 0;

export const sortByActivity = (list: ConversationView[]): ConversationView[] =>
  [...list].sort((a, b) => activityOf(b) - activityOf(a));

/** The other person of a direct chat, or null. */
export const otherParticipant = (conversation: ConversationView, selfUserId: string) =>
  conversation.participants.find((participant) => participant.userId !== selfUserId) ?? null;

/** What a chat is called in the list: the other person, or the group title. */
export const titleOf = (conversation: ConversationView, selfUserId: string): string => {
  if (conversation.kind === 'group') return conversation.title ?? 'Group';
  return otherParticipant(conversation, selfUserId)?.profile.displayName ?? 'Private chat';
};

/**
 * Merges one pushed row into the list. Returns the new list and whether the
 * row is news for the person: more unread than before, not written by them,
 * not open, not muted.
 */
export const mergeConversation = (
  current: ConversationView[],
  incoming: ConversationView,
  { openId, selfUserId, now = Date.now() }: { openId: string | null; selfUserId: string; now?: number },
): { list: ConversationView[]; isNews: boolean } => {
  const previous = current.find((c) => c.conversationId === incoming.conversationId);
  const isOpen = openId === incoming.conversationId;
  const next = isOpen ? { ...incoming, unreadCount: 0 } : incoming;

  const isNews =
    !isOpen &&
    incoming.unreadCount > (previous?.unreadCount ?? 0) &&
    incoming.lastMessagePreview?.authorId !== selfUserId &&
    !isMutedNow(incoming, now);

  return {
    list: sortByActivity([next, ...current.filter((c) => c.conversationId !== incoming.conversationId)]),
    isNews,
  };
};

export const unreadTotalOf = (
  lobby: ChannelView | null,
  conversations: ConversationView[],
  now = Date.now(),
): number =>
  conversations.reduce((sum, c) => sum + (isMutedNow(c, now) ? 0 : c.unreadCount), 0) +
  (lobby && !isMutedNow(lobby, now) ? lobby.unreadCount : 0);

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

export interface UseConversationsOptions {
  api: ChatApi;
  /** The `/chat` namespace connection. Without it the list refreshes by polling only. */
  socket?: SignalingTransport | null;
  selfUserId: string;
  enabled?: boolean;
  /** A row became news (see mergeConversation). For a toast or a sound. */
  onIncoming?(conversation: ConversationView): void;
}

export interface UseConversationsResult {
  lobby: ChannelView | null;
  conversations: ConversationView[];
  loading: boolean;
  error: unknown;
  /** Unread across the list, muted chats excluded. */
  unreadTotal: number;
  refresh(): Promise<void>;
  /** Opens (or reopens) a private chat and puts it in the list. */
  open(userId: string, options?: { roomId?: string | null }): Promise<ConversationView>;
  /** What is on screen now: a conversationId, 'lobby', or null. */
  setOpen(id: string | null): void;
  mute(conversationId: string, until: string | null): Promise<void>;
  unmute(conversationId: string): Promise<void>;
  remove(conversationId: string): Promise<void>;
  muteLobby(until: string | null): Promise<void>;
  unmuteLobby(): Promise<void>;
}

export const useConversations = (options: UseConversationsOptions): UseConversationsResult => {
  const { api, socket, selfUserId, enabled = true } = options;

  const [lobby, setLobby] = useState<ChannelView | null>(null);
  const [conversations, setConversations] = useState<ConversationView[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<unknown>(null);
  // Re-renders now and then so a mute that has run out shows as off.
  const [clock, setClock] = useState(0);

  const conversationsRef = useRef<ConversationView[]>([]);
  conversationsRef.current = conversations;
  const openRef = useRef<string | null>(null);
  const onIncomingRef = useRef(options.onIncoming);
  onIncomingRef.current = options.onIncoming;

  const refresh = useCallback(async () => {
    try {
      const [channels, page] = await Promise.all([
        api.listChannels({ scope: 'public' }),
        api.listConversations({ limit: 50 }),
      ]);
      const first = channels.items[0] ?? null;
      setLobby(first && openRef.current === LOBBY ? { ...first, unreadCount: 0 } : first);
      setConversations(
        sortByActivity(
          page.items.map((c) => (openRef.current === c.conversationId ? { ...c, unreadCount: 0 } : c)),
        ),
      );
      setError(null);
    } catch (cause) {
      setError(cause);
    } finally {
      setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    if (!enabled) return undefined;
    void refresh();
    const poll = setInterval(() => void refresh(), REFRESH_MS);
    const tick = setInterval(() => setClock((n) => n + 1), 15_000);
    const onFocus = () => void refresh();
    const hasWindow = typeof window !== 'undefined' && typeof window.addEventListener === 'function';
    if (hasWindow) window.addEventListener('focus', onFocus);
    return () => {
      clearInterval(poll);
      clearInterval(tick);
      if (hasWindow) window.removeEventListener('focus', onFocus);
    };
  }, [enabled, refresh]);

  const upsert = useCallback(
    (incoming: ConversationView) => {
      const { list, isNews } = mergeConversation(conversationsRef.current, incoming, {
        openId: openRef.current,
        selfUserId,
      });
      conversationsRef.current = list;
      setConversations(list);
      if (isNews) onIncomingRef.current?.(incoming);
    },
    [selfUserId],
  );

  // Rows pushed to this person's own socket room.
  useEffect(() => {
    if (!socket || !enabled) return undefined;
    const onRow = (payload: { conversation?: ConversationView }) => {
      if (payload?.conversation?.conversationId) upsert(payload.conversation);
    };
    socket.on(SERVER.conversationCreated, onRow as (p: never) => void);
    socket.on(SERVER.conversationUpdated, onRow as (p: never) => void);
    return () => {
      socket.off(SERVER.conversationCreated, onRow as (p: never) => void);
      socket.off(SERVER.conversationUpdated, onRow as (p: never) => void);
    };
  }, [socket, enabled, upsert]);

  const setOpen = useCallback((id: string | null) => {
    openRef.current = id;
    if (!id) return;
    if (id === LOBBY) {
      setLobby((current) => (current ? { ...current, unreadCount: 0 } : current));
      return;
    }
    setConversations((current) =>
      current.map((c) => (c.conversationId === id ? { ...c, unreadCount: 0 } : c)),
    );
  }, []);

  const open = useCallback(
    async (userId: string, openOptions: { roomId?: string | null } = {}) => {
      const conversation = await api.openDirect(userId, openOptions);
      upsert(conversation);
      return conversation;
    },
    [api, upsert],
  );

  const mute = useCallback(
    async (conversationId: string, until: string | null) => {
      upsert(await api.muteConversation(conversationId, { muted: true, until }));
    },
    [api, upsert],
  );

  const unmute = useCallback(
    async (conversationId: string) => {
      upsert(await api.muteConversation(conversationId, { muted: false }));
    },
    [api, upsert],
  );

  const remove = useCallback(
    async (conversationId: string) => {
      await api.deleteConversation(conversationId);
      if (openRef.current === conversationId) openRef.current = null;
      setConversations((current) => current.filter((c) => c.conversationId !== conversationId));
    },
    [api],
  );

  const muteLobby = useCallback(
    async (until: string | null) => {
      if (!lobby) return;
      const result = await api.muteChannel(lobby.channelId, { muted: true, until });
      setLobby((current) => (current ? { ...current, muted: result.muted, mutedUntil: result.mutedUntil } : current));
    },
    [api, lobby],
  );

  const unmuteLobby = useCallback(async () => {
    if (!lobby) return;
    await api.muteChannel(lobby.channelId, { muted: false });
    setLobby((current) => (current ? { ...current, muted: false, mutedUntil: null } : current));
  }, [api, lobby]);

  // `clock` is a dependency on purpose: a mute that ran out changes the total.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const unreadTotal = useMemo(() => unreadTotalOf(lobby, conversations), [lobby, conversations, clock]);

  return {
    lobby,
    conversations,
    loading,
    error,
    unreadTotal,
    refresh,
    open,
    setOpen,
    mute,
    unmute,
    remove,
    muteLobby,
    unmuteLobby,
  };
};
