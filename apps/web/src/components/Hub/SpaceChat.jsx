import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { createChatApi, createFilesApi, createProfileApi, useCore } from '@classroom/core-client';
import { onUserEvent } from '../../lib/userEvents.js';
import { formatDate, formatTime } from '../../lib/preferences.js';
import { CALM_CHOICES, calmLabel } from './hubModel.js';
import LateNightNudge from './LateNightNudge.jsx';
import Avatar from '../Messenger/Avatar.jsx';
import { ProfileDialog } from '../Messenger/ProfileCard.jsx';
import { ConfirmDialog } from '../Messenger/Dialogs.jsx';
import SharedMedia from '../Messenger/SharedMedia.jsx';
import { dayLabel, highlightParts, searchHits, snippet, threadRows } from '../Messenger/messengerModel.js';
import Composer from '../ChatKit/Composer.jsx';
import MessageFiles from '../ChatKit/MessageFiles.jsx';
import { ReactionChips, ReactionPicker } from '../ChatKit/Reactions.jsx';
import { filesLabel, toggleAction } from '../ChatKit/chatKitModel.js';
import '../ChatKit/chatkit.css';
import './spaceChat.css';

/**
 * The chat of a space  (Community)
 *
 * The same building blocks as Messages — reactions, files and pictures, voice
 * messages, reply, edit, search, everything shared — without calls: those are
 * what the space's rooms are for.
 *
 *   beside the chat   Members (how many, who, their role; a name opens the
 *                     profile, from where you can write privately) and Shared
 *                     (media · files · voice of this chat)
 *   deleting          your own messages, for everyone; owners and moderators
 *                     may remove anyone's ("Removed by a moderator")
 *   staying current   the server says which messages changed — new, edited,
 *                     deleted or reacted to — so every open chat shows the same
 *   kept              calm mode, paused posting, the late-night nudge
 */

const POLL_MS = 5_000;
const ROLE_LABEL = { owner: 'Owner', moderator: 'Moderator' };
const WIDE_PANEL = '(min-width: 1280px)';

let localSeq = 0;

function Text({ body, query }) {
  return highlightParts(body, query).map((part, index) => (part.hit ? <mark key={index}>{part.text}</mark> : <span key={index}>{part.text}</span>));
}

/** Incoming changes into the list: replace what we have, add what is new, keep the order. */
export const mergeChanges = (current, incoming) => {
  if (!incoming.length) return current;
  const list = [...current];
  const index = new Map(list.map((m, i) => [m.messageId, i]));
  const oldest = list.find((m) => !m.local)?.createdAt ?? null;
  for (const message of incoming) {
    if (index.has(message.messageId)) list[index.get(message.messageId)] = message;
    else if (!oldest || message.createdAt >= oldest) {
      list.push(message);
      index.set(message.messageId, list.length - 1);
    }
  }
  return list.sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0));
};

function MembersPanel({ hub, space, selfUserId, onOpenProfile }) {
  const [members, setMembers] = useState(null);
  useEffect(() => {
    const controller = new AbortController();
    hub
      .members(space.spaceId, controller.signal)
      .then(setMembers)
      .catch(() => !controller.signal.aborted && setMembers({ listVisible: false, count: space.memberCount ?? 0, items: [] }));
    return () => controller.abort();
  }, [hub, space.spaceId, space.memberCount]);
  if (!members) return <p className="sc-muted">Loading…</p>;
  const order = { owner: 0, moderator: 1 };
  const items = [...members.items].sort((a, b) => (order[a.role] ?? 2) - (order[b.role] ?? 2) || a.displayName.localeCompare(b.displayName));
  return (
    <div className="sc-members">
      <p className="sc-members__count">
        <strong>{members.count}</strong> {members.count === 1 ? 'member' : 'members'}
      </p>
      {!members.listVisible ? <p className="sc-muted">Only moderators see who is in this space.</p> : null}
      <ul>
        {items.map((member) => (
          <li key={member.userId}>
            <button type="button" onClick={() => onOpenProfile({ userId: member.userId, displayName: member.displayName })}>
              <Avatar name={member.displayName} seed={member.userId} size={36} />
              <span className="sc-members__name">
                {member.displayName}
                {member.userId === selfUserId || member.you ? <span className="sc-muted"> (you)</span> : null}
              </span>
              {ROLE_LABEL[member.role] ? <span className={`sc-role sc-role--${member.role}`}>{ROLE_LABEL[member.role]}</span> : null}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default function SpaceChat({ hub, space }) {
  const core = useCore();
  const { http, session } = core;
  const navigate = useNavigate();
  const files = useMemo(() => createFilesApi(http), [http]);
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const chatApi = useMemo(() => createChatApi(http), [http]);
  const selfUserId = session?.userId ?? '';

  const [items, setItems] = useState(null);
  const [state, setState] = useState({ blocked: null, calmSeconds: 0, canModerate: false, editWindowMin: 15 });
  const [replyTo, setReplyTo] = useState(null);
  const [editing, setEditing] = useState(null);
  const [editError, setEditError] = useState(null);
  const [pickerFor, setPickerFor] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [profileOf, setProfileOf] = useState(null);
  const [notice, setNotice] = useState(null);
  const [searchOpen, setSearchOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [hitIndex, setHitIndex] = useState(0);
  const [panel, setPanel] = useState(() => (typeof window !== 'undefined' && window.matchMedia?.(WIDE_PANEL).matches ? 'members' : null));
  const cursor = useRef(null);
  const busy = useRef(false);
  const listRef = useRef(null);
  const rootRef = useRef(null);
  const nearBottom = useRef(true);
  const noticeTimer = useRef(null);
  const composerRef = useRef(null);
  const editRef = useRef(null);

  const say = (text) => {
    window.clearTimeout(noticeTimer.current);
    setNotice(text);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 3500);
  };
  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);

  // Fill the window below the space's header and tabs.
  useLayoutEffect(() => {
    const fit = () => {
      const el = rootRef.current;
      if (el) el.style.setProperty('--sc-top', `${Math.max(0, Math.round(el.getBoundingClientRect().top + window.scrollY))}px`);
    };
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  const fetchChanges = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    try {
      const page = await hub.chat(space.spaceId, cursor.current);
      setItems((current) => (cursor.current === null || current === null ? page.items : mergeChanges(current, page.items)));
      cursor.current = page.nextCursor ?? cursor.current;
      setState({ blocked: page.postingBlocked, calmSeconds: page.calmSeconds ?? 0, canModerate: Boolean(page.canModerate), editWindowMin: page.editWindowMin ?? 15 });
    } catch {
      setItems((current) => current ?? []);
    } finally {
      busy.current = false;
    }
  }, [hub, space.spaceId]);

  // The live signal needs the core; a new core object must not restart the chat.
  const coreRef = useRef(core);
  coreRef.current = core;

  useEffect(() => {
    cursor.current = null;
    setItems(null);
    fetchChanges();
    const timer = window.setInterval(() => document.visibilityState === 'visible' && fetchChanges(), POLL_MS);
    const off = onUserEvent(coreRef.current, 'hub:chat', (payload) => {
      if (!payload?.spaceId || payload.spaceId === space.spaceId) fetchChanges();
    });
    return () => {
      window.clearInterval(timer);
      off();
    };
  }, [fetchChanges, space.spaceId]);

  useLayoutEffect(() => {
    const list = listRef.current;
    if (list && nearBottom.current) list.scrollTop = list.scrollHeight;
  }, [items?.length]);
  const onScroll = () => {
    const list = listRef.current;
    if (list) nearBottom.current = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
  };

  const messages = items ?? [];
  const byId = useMemo(() => new Map(messages.map((m) => [m.messageId, m])), [messages]);
  const rows = useMemo(
    () => threadRows(messages.map((m) => ({ ...m, author: { ...m.author, userId: m.author.userId } }))),
    [messages],
  );
  const hits = useMemo(() => searchHits(messages, searchOpen ? search : ''), [messages, search, searchOpen]);
  useEffect(() => setHitIndex(Math.max(0, hits.length - 1)), [search]); // eslint-disable-line react-hooks/exhaustive-deps
  const activeHit = hits.length ? hits[Math.min(hitIndex, hits.length - 1)] : null;
  useEffect(() => {
    if (!activeHit) return;
    nearBottom.current = false;
    listRef.current?.querySelector(`[data-message-id="${CSS.escape(activeHit)}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }, [activeHit]);

  const replace = (message) => setItems((current) => (current ?? []).map((m) => (m.messageId === message.messageId ? { ...m, ...message } : m)));

  const send = async ({ body, files: ready, voice }) => {
    nearBottom.current = true;
    const reply = replyTo;
    setReplyTo(null);
    const localId = `local-${(localSeq += 1)}`;
    const optimistic = {
      messageId: localId, local: true, sending: true, body,
      author: { userId: selfUserId, displayName: session?.displayName ?? 'You', you: true },
      createdAt: new Date().toISOString(), files: ready.map((f) => ({ ...f, voice: Boolean(voice), durationMs: voice?.durationMs ?? null })),
      reactions: [], replyToId: reply?.messageId ?? null,
    };
    setItems((current) => [...(current ?? []), optimistic]);
    try {
      const saved = await hub.sendChat(space.spaceId, { body, fileIds: ready.map((f) => f.fileId), ...(voice ? { voice } : {}), ...(reply ? { replyToId: reply.messageId } : {}) });
      setItems((current) => mergeChanges((current ?? []).filter((m) => m.messageId !== localId), [saved]));
    } catch (cause) {
      setItems((current) => (current ?? []).filter((m) => m.messageId !== localId));
      throw cause;
    }
  };

  const startEdit = (message) => {
    setEditError(null);
    setEditing({ messageId: message.messageId, text: message.body });
    window.requestAnimationFrame(() => editRef.current?.focus());
  };
  const saveEdit = async () => {
    const text = editing.text.trim();
    if (!text) return setEditError('A message cannot be empty. Delete it instead.');
    if (text === byId.get(editing.messageId)?.body) return setEditing(null);
    try {
      replace(await hub.editChat(editing.messageId, text));
      setEditing(null);
    } catch (cause) {
      setEditError(cause?.detail ?? 'The change was not saved.');
    }
    return undefined;
  };

  const toggleReaction = async (message, emoji) => {
    try {
      const result = await hub.reactChat(message.messageId, { emoji, action: toggleAction(message.reactions, emoji) });
      setItems((current) =>
        (current ?? []).map((m) => {
          if (m.messageId !== message.messageId) return m;
          const others = (m.reactions ?? []).filter((r) => r.emoji !== emoji);
          if (!result.count) return { ...m, reactions: others };
          const position = (m.reactions ?? []).findIndex((r) => r.emoji === emoji);
          const next = [...others];
          next.splice(position === -1 ? next.length : position, 0, { emoji, count: result.count, reacted: result.reacted, names: result.names ?? [] });
          return { ...m, reactions: next };
        }),
      );
    } catch (cause) {
      say(cause?.detail ?? 'The reaction was not saved.');
    }
  };

  const remove = async (message) => {
    const result = await hub.removeChat(message.messageId);
    replace({ messageId: message.messageId, body: '', files: [], reactions: [], deletedAt: new Date().toISOString(), deletedBy: result?.as ?? message.removeAs, canRemove: false, canEdit: false });
  };

  const copy = async (message) => {
    try {
      await navigator.clipboard.writeText(message.body);
      say('Copied.');
    } catch {
      say('Copying is not allowed in this browser.');
    }
  };

  const messagePrivately = async (person) => {
    const conversation = await chatApi.openDirect(person.userId);
    navigate(`/messages/${conversation.conversationId}`);
  };

  const lastEditable = () => [...messages].reverse().find((m) => m.canEdit && m.author.userId === selfUserId) ?? null;
  const mediaApi = useMemo(() => ({ media: (id, query, signal) => hub.chatMedia(id, query, signal) }), [hub]);

  return (
    <div className={`sc${panel ? ' has-panel' : ''}`} ref={rootRef}>
      <section className="sc-chat" aria-label={`Chat of ${space.name}`}>
        <header className="sc-head">
          <div className="sc-head__who">
            <strong>Chat</strong>
            <button type="button" className="sc-head__count" onClick={() => setPanel(panel === 'members' ? null : 'members')}>
              {space.memberCount ?? '…'} {space.memberCount === 1 ? 'member' : 'members'}
            </button>
            {state.calmSeconds > 0 ? <span className="sc-calm">🌿 {calmLabel(state.calmSeconds)}</span> : null}
          </div>
          <div className="sc-head__actions">
            {state.canModerate ? (
              <select
                className="sc-select"
                value={state.calmSeconds}
                aria-label="Calm mode for the chat"
                onChange={async (event) => {
                  const seconds = Number(event.target.value);
                  await hub.setChatCalm(space.spaceId, seconds).catch(() => undefined);
                  setState((current) => ({ ...current, calmSeconds: seconds }));
                }}
              >
                {CALM_CHOICES.map((choice) => (
                  <option key={choice.seconds} value={choice.seconds}>
                    {choice.seconds ? `Calm: ${choice.label}` : 'Calm mode off'}
                  </option>
                ))}
              </select>
            ) : null}
            <button type="button" className={`sc-iconbtn${searchOpen ? ' is-on' : ''}`} onClick={() => (setSearchOpen((v) => !v), setSearch(''))} aria-label="Search in this chat" title="Search in this chat">⌕</button>
            <button type="button" className={`sc-iconbtn${panel === 'members' ? ' is-on' : ''}`} onClick={() => setPanel(panel === 'members' ? null : 'members')} aria-label="Members" title="Members">👥</button>
            <button type="button" className={`sc-iconbtn${panel === 'shared' ? ' is-on' : ''}`} onClick={() => setPanel(panel === 'shared' ? null : 'shared')} aria-label="Shared in this chat" title="Media, files and voice">🖼</button>
          </div>
        </header>

        {searchOpen ? (
          <div className="sc-findbar" role="search">
            <input
              type="search"
              autoFocus
              placeholder="Search in this chat"
              aria-label="Search in this chat"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter') setHitIndex((i) => (event.shiftKey ? Math.min(hits.length - 1, i + 1) : Math.max(0, i - 1)));
                if (event.key === 'Escape') (setSearchOpen(false), setSearch(''));
              }}
            />
            <span className="sc-muted">{search.trim() ? (hits.length ? `${Math.min(hitIndex, hits.length - 1) + 1} of ${hits.length}` : 'No results') : ''}</span>
          </div>
        ) : null}

        <div className="sc-messages" ref={listRef} onScroll={onScroll} data-ck-dropzone>
          <div className="sc-messages__inner">
            {items === null ? <p className="sc-muted sc-center">Loading…</p> : null}
            {items?.length === 0 ? (
              <div className="sc-start">
                <Avatar name={space.name} seed={space.spaceId} size={64} />
                <p className="sc-start__title">Welcome to the chat of {space.name}</p>
                <p className="sc-muted">Say hello, share a picture or ask something quick. Longer questions fit better in Threads.</p>
              </div>
            ) : null}
            {rows.map((row) => {
              if (row.type === 'day') return <div key={row.key} className="sc-day" role="separator"><span>{dayLabel(row.at, new Date(), formatDate)}</span></div>;
              const { message, firstInGroup, lastInGroup } = row;
              const mine = message.author.userId === selfUserId;
              const reply = message.replyToId ? byId.get(message.replyToId) : null;
              const isEditing = editing?.messageId === message.messageId;
              return (
                <div key={row.key} data-message-id={message.messageId} className={['sc-msg', mine ? 'is-mine' : 'is-theirs', firstInGroup ? 'is-first' : '', lastInGroup ? 'is-last' : '', message.sending ? 'is-sending' : '', activeHit === message.messageId ? 'is-hit' : ''].filter(Boolean).join(' ')}>
                  {!mine ? (
                    <span className="sc-msg__gutter">
                      {lastInGroup ? (
                        <button type="button" className="sc-avatarbtn" onClick={() => setProfileOf(message.author)} aria-label={`Profile of ${message.author.displayName}`}>
                          <Avatar name={message.author.displayName} seed={message.author.userId} size={32} />
                        </button>
                      ) : null}
                    </span>
                  ) : null}
                  <div className="sc-msg__col">
                    {!mine && firstInGroup ? (
                      <button type="button" className="sc-msg__author" onClick={() => setProfileOf(message.author)}>{message.author.displayName}</button>
                    ) : null}
                    <div className="sc-msg__line">
                      <div className="sc-bubble">
                        {message.replyToId ? (
                          <span className="sc-quote">
                            <strong>{reply ? (reply.author.userId === selfUserId ? 'You' : reply.author.displayName) : 'Reply'}</strong>
                            <span>{reply ? (reply.deletedAt ? 'Message deleted' : snippet(reply.body) || filesLabel(reply.files)) : 'to an earlier message'}</span>
                          </span>
                        ) : null}
                        {isEditing ? (
                          <form className="sc-edit" onSubmit={(event) => (event.preventDefault(), saveEdit())}>
                            <textarea
                              ref={editRef}
                              rows={2}
                              aria-label="Edit message"
                              value={editing.text}
                              maxLength={2000}
                              onChange={(event) => setEditing({ ...editing, text: event.target.value })}
                              onKeyDown={(event) => {
                                if (event.key === 'Enter' && !event.shiftKey) (event.preventDefault(), saveEdit());
                                if (event.key === 'Escape') (event.stopPropagation(), setEditing(null));
                              }}
                            />
                            <span className="sc-edit__hint">Enter to save · Esc to cancel</span>
                            {editError ? <span className="sc-error">{editError}</span> : null}
                          </form>
                        ) : message.deletedAt ? (
                          <em className="sc-deleted">{message.deletedBy === 'moderator' ? 'Removed by a moderator' : 'This message was deleted'}</em>
                        ) : (
                          <>
                            <MessageFiles files={message.files ?? []} mine={mine} />
                            {message.body ? <span className="sc-bubble__text"><Text body={message.body} query={searchOpen ? search : ''} /></span> : null}
                          </>
                        )}
                        {!isEditing ? (
                          <span className="sc-bubble__meta">
                            {message.editedAt && !message.deletedAt ? 'edited · ' : ''}
                            {message.sending ? 'Sending…' : formatTime(new Date(message.createdAt))}
                          </span>
                        ) : null}
                      </div>
                      {pickerFor === message.messageId ? <ReactionPicker align={mine ? 'end' : 'start'} onPick={(emoji) => toggleReaction(message, emoji)} onClose={() => setPickerFor(null)} /> : null}
                      {!message.deletedAt && !message.local && !isEditing ? (
                        <span className="sc-actions" role="toolbar" aria-label="Message actions">
                          <button type="button" onClick={() => setPickerFor(message.messageId)} aria-label="React" title="React">☺</button>
                          <button type="button" onClick={() => (setReplyTo(message), composerRef.current?.focus())} aria-label="Reply" title="Reply">↩</button>
                          {message.canEdit && mine ? <button type="button" onClick={() => startEdit(message)} aria-label="Edit" title="Edit">✎</button> : null}
                          {message.body ? <button type="button" onClick={() => copy(message)} aria-label="Copy text" title="Copy text">⧉</button> : null}
                          {message.removeAs ? (
                            <button type="button" className="is-danger" onClick={() => setConfirm(message)} aria-label={message.removeAs === 'moderator' ? 'Remove as moderator' : 'Delete'} title={message.removeAs === 'moderator' ? 'Remove as moderator' : 'Delete'}>🗑</button>
                          ) : null}
                        </span>
                      ) : null}
                    </div>
                    {!message.deletedAt ? <ReactionChips reactions={message.reactions ?? []} mine={mine} onToggle={(emoji) => toggleReaction(message, emoji)} /> : null}
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {notice ? <p className="sc-toast" role="status">{notice}</p> : null}

        <div className="sc-composer">
          <Composer
            files={files}
            inputRef={composerRef}
            placeholder={`Message ${space.name}`}
            disabled={Boolean(state.blocked)}
            disabledReason={state.blocked ?? ''}
            onSend={send}
            onArrowUp={() => {
              const last = lastEditable();
              if (last) startEdit(last);
              return Boolean(last);
            }}
            onEscape={() => setReplyTo(null)}
            top={
              replyTo ? (
                <div className="sc-replychip">
                  <span>
                    <strong>Replying to {replyTo.author.userId === selfUserId ? 'yourself' : replyTo.author.displayName}</strong>
                    <span>{snippet(replyTo.body) || filesLabel(replyTo.files)}</span>
                  </span>
                  <button type="button" className="sc-iconbtn" onClick={() => setReplyTo(null)} aria-label="Cancel reply">×</button>
                </div>
              ) : null
            }
            below={(draft, clear) =>
              state.blocked ? null : (
                <div className="sc-nudge">
                  <LateNightNudge hub={hub} build={() => (draft.trim() ? { kind: 'chat', targetId: space.spaceId, body: draft.trim() } : null)} onScheduled={clear} />
                </div>
              )
            }
          />
        </div>
      </section>

      {panel ? (
        <>
          <button type="button" className="sc-scrim" aria-label="Close panel" onClick={() => setPanel(null)} />
          <aside className="sc-panel" aria-label={panel === 'members' ? 'Members' : 'Shared in this chat'}>
            <div className="sc-panel__tabs" role="tablist">
              <button type="button" role="tab" aria-selected={panel === 'members'} className={panel === 'members' ? 'is-on' : ''} onClick={() => setPanel('members')}>Members</button>
              <button type="button" role="tab" aria-selected={panel === 'shared'} className={panel === 'shared' ? 'is-on' : ''} onClick={() => setPanel('shared')}>Shared</button>
              <button type="button" className="sc-iconbtn" onClick={() => setPanel(null)} aria-label="Close panel">×</button>
            </div>
            <div className="sc-panel__body">
              {panel === 'members' ? <MembersPanel hub={hub} space={space} selfUserId={selfUserId} onOpenProfile={setProfileOf} /> : <SharedMedia api={mediaApi} conversationId={space.spaceId} refreshKey={messages.length} />}
            </div>
          </aside>
        </>
      ) : null}

      {confirm ? (
        <ConfirmDialog
          title={confirm.removeAs === 'moderator' ? `Remove ${confirm.author.displayName}'s message?` : 'Delete this message?'}
          body={
            confirm.removeAs === 'moderator'
              ? 'Everyone sees “Removed by a moderator” instead. The removal is noted in the space’s log.'
              : 'It is removed for everyone, with its files, and shows as “This message was deleted”.'
          }
          confirmLabel={confirm.removeAs === 'moderator' ? 'Remove' : 'Delete for everyone'}
          danger
          onConfirm={() => remove(confirm)}
          onClose={() => setConfirm(null)}
        />
      ) : null}
      {profileOf ? <ProfileDialog person={profileOf} profiles={profiles} selfUserId={selfUserId} onMessage={messagePrivately} onClose={() => setProfileOf(null)} /> : null}
    </div>
  );
}
