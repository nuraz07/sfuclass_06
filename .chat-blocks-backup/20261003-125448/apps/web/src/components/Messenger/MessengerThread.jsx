import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createFilesApi, useChat, useCore } from '@classroom/core-client';
import Composer from '../ChatKit/Composer.jsx';
import MessageFiles from '../ChatKit/MessageFiles.jsx';
import { ReactionChips, ReactionPicker } from '../ChatKit/Reactions.jsx';
import { filesLabel, toggleAction } from '../ChatKit/chatKitModel.js';
import '../ChatKit/chatkit.css';
import { formatDate, formatTime } from '../../lib/preferences.js';
import Avatar from './Avatar.jsx';
import { ConfirmDialog } from './Dialogs.jsx';
import { canDelete, canEdit, dayLabel, highlightParts, lastEditable, searchHits, snippet, threadRows } from './messengerModel.js';

/**
 * One conversation  (Messages)
 *
 *   messages   grouped by day and by person; names and pictures open the
 *              person's profile
 *   actions    on hover (or always on touch screens): React, Reply, Edit (your
 *              own, within the edit window), Copy, Delete (your own, for
 *              everyone). Edits, deletes and reactions reach the other side live.
 *   files      pictures, videos, documents and voice messages in the bubble
 *   composer   the chat kit's: text, files (📎, drop, paste) and voice (🎤);
 *              ↑ in an empty composer edits your last message, Esc cancels a reply
 *   search     finds text in the loaded messages, highlights it and jumps
 *              between hits; "Load earlier" reaches further back
 *
 * Sending, editing and deleting go through useChat (core-client), the same as
 * everywhere else, so the server's rules (blocks, privacy, edit window) apply.
 */

const MAX_LENGTH = 4000;

function Text({ body, query }) {
  return highlightParts(body, query).map((part, index) => (part.hit ? <mark key={index}>{part.text}</mark> : <span key={index}>{part.text}</span>));
}

function AutoTextarea({ value, onChange, onKeyDown, placeholder, disabled, inputRef, label }) {
  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 180)}px`;
  }, [value, inputRef]);
  return (
    <textarea
      ref={inputRef}
      rows={1}
      value={value}
      maxLength={MAX_LENGTH}
      placeholder={placeholder}
      aria-label={label}
      disabled={disabled}
      onChange={onChange}
      onKeyDown={onKeyDown}
    />
  );
}

function MessageActions({ message, mine, editable, deletable, onReact, onReply, onEdit, onCopy, onDelete }) {
  if (message.deletedAt || message.delivery !== 'sent') return null;
  return (
    <span className={`mx-actions${mine ? ' is-mine' : ''}`} role="toolbar" aria-label="Message actions">
      <button type="button" onClick={onReact} title="React" aria-label="React">☺</button>
      <button type="button" onClick={onReply} title="Reply" aria-label="Reply">↩</button>
      {editable ? <button type="button" onClick={onEdit} title="Edit" aria-label="Edit">✎</button> : null}
      {message.body ? <button type="button" onClick={onCopy} title="Copy text" aria-label="Copy text">⧉</button> : null}
      {deletable ? <button type="button" className="is-danger" onClick={onDelete} title="Delete" aria-label="Delete">🗑</button> : null}
    </span>
  );
}

export default function MessengerThread({ api, socket, self, conversation, title, other, editWindowMin, search, onSearchChange, searchOpen, onCloseSearch, onOpenProfile, disabledReason = '' }) {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const target = useMemo(() => ({ kind: 'conversation', conversationId: conversation.conversationId }), [conversation.conversationId]);
  const { messages, loading, loadingOlder, hasMore, loadOlder, typingUserIds, throttledUntil, send, retry, edit, remove, react, setTyping, error } = useChat({
    api,
    socket: socket ?? undefined,
    target,
    self,
  });

  const [replyTo, setReplyTo] = useState(null);
  const [pickerFor, setPickerFor] = useState(null);
  const [editing, setEditing] = useState(null); // { messageId, text }
  const [editError, setEditError] = useState(null);
  const [confirmDelete, setConfirmDelete] = useState(null);
  const [notice, setNotice] = useState(null);
  const [hitIndex, setHitIndex] = useState(0);
  const scrollRef = useRef(null);
  const composerRef = useRef(null);
  const editRef = useRef(null);
  const stickToBottom = useRef(true);
  const noticeTimer = useRef(null);

  const rules = { selfUserId: self.userId, windowMin: editWindowMin };
  const rows = useMemo(() => threadRows(messages), [messages]);
  const byId = useMemo(() => new Map(messages.map((m) => [m.messageId, m])), [messages]);
  const hits = useMemo(() => searchHits(messages, search), [messages, search]);
  const throttled = throttledUntil !== null && throttledUntil > Date.now();
  const disabled = throttled || Boolean(disabledReason);

  const say = (text) => {
    window.clearTimeout(noticeTimer.current);
    setNotice(text);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 3500);
  };
  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);

  // Stay at the bottom while new messages arrive, unless the person scrolled up to read.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el && stickToBottom.current) el.scrollTop = el.scrollHeight;
  }, [messages.length]);
  const onScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    stickToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  };

  // A new chat: start at the bottom, composer focused, nothing half-done.
  useEffect(() => {
    stickToBottom.current = true;
    setReplyTo(null);
    setPickerFor(null);
    setEditing(null);
    composerRef.current?.focus({ preventScroll: true });
  }, [conversation.conversationId]);

  // Search: jump to the newest hit, then wherever the arrows say.
  useEffect(() => setHitIndex(Math.max(0, hits.length - 1)), [search]); // eslint-disable-line react-hooks/exhaustive-deps
  const activeHit = hits.length ? hits[Math.min(hitIndex, hits.length - 1)] : null;
  useEffect(() => {
    if (!activeHit) return;
    stickToBottom.current = false;
    scrollRef.current?.querySelector(`[data-message-id="${CSS.escape(activeHit)}"]`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }, [activeHit]);

  const jumpTo = (messageId) => {
    stickToBottom.current = false;
    const el = scrollRef.current?.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`);
    if (!el) return say('That message is further back. Load earlier messages to see it.');
    el.scrollIntoView({ block: 'center', behavior: 'smooth' });
    el.classList.add('is-flash');
    window.setTimeout(() => el.classList.remove('is-flash'), 1400);
    return undefined;
  };

  const sendFromComposer = async ({ body, files: ready, voice }) => {
    stickToBottom.current = true;
    const reply = replyTo;
    setReplyTo(null);
    await send({
      body,
      fileIds: ready.map((f) => f.fileId),
      previewFiles: ready.map((f) => ({ ...f, voice: Boolean(voice), durationMs: voice?.durationMs ?? null })),
      ...(voice ? { voice } : {}),
      ...(reply ? { replyToId: reply.messageId } : {}),
    });
  };

  const toggleReaction = async (message, emoji) => {
    try {
      await react(message.messageId, emoji, toggleAction(message.reactions, emoji));
    } catch (cause) {
      say(cause?.detail ?? 'The reaction was not saved.');
    }
  };

  const startEdit = useCallback((message) => {
    setEditError(null);
    setEditing({ messageId: message.messageId, text: message.body });
    window.requestAnimationFrame(() => {
      const el = editRef.current;
      if (el) {
        el.focus();
        el.setSelectionRange(el.value.length, el.value.length);
      }
    });
  }, []);

  const saveEdit = async () => {
    const message = byId.get(editing.messageId);
    const text = editing.text.trim();
    if (!text) return setEditError('A message cannot be empty. Delete it instead.');
    if (text === message?.body) return setEditing(null);
    try {
      await edit(editing.messageId, text);
      setEditing(null);
      setEditError(null);
      composerRef.current?.focus();
    } catch (cause) {
      setEditError(cause?.detail ?? 'The change was not saved.');
    }
    return undefined;
  };

  const copy = async (message) => {
    try {
      await navigator.clipboard.writeText(message.body);
      say('Copied.');
    } catch {
      say('Copying is not allowed in this browser.');
    }
  };

  const typingName = typingUserIds.length === 1 ? (typingUserIds[0] === other?.userId ? other?.profile?.displayName : 'Someone') : null;

  return (
    <div className="mx-thread">
      {searchOpen ? (
        <div className="mx-findbar" role="search">
          <input
            type="search"
            autoFocus
            placeholder="Search in this chat"
            aria-label="Search in this chat"
            value={search}
            onChange={(event) => onSearchChange(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') setHitIndex((i) => (event.shiftKey ? Math.min(hits.length - 1, i + 1) : Math.max(0, i - 1)));
              if (event.key === 'Escape') onCloseSearch();
            }}
          />
          <span className="mx-findbar__count" aria-live="polite">
            {search.trim() ? (hits.length ? `${Math.min(hitIndex, hits.length - 1) + 1} of ${hits.length}` : 'No results') : ''}
          </span>
          <button type="button" className="mx-iconbtn" disabled={!hits.length || hitIndex <= 0} onClick={() => setHitIndex((i) => Math.max(0, i - 1))} aria-label="Earlier result">↑</button>
          <button type="button" className="mx-iconbtn" disabled={!hits.length || hitIndex >= hits.length - 1} onClick={() => setHitIndex((i) => Math.min(hits.length - 1, i + 1))} aria-label="Later result">↓</button>
          <button type="button" className="mx-iconbtn" onClick={onCloseSearch} aria-label="Close search">×</button>
        </div>
      ) : null}

      <div className="mx-messages" ref={scrollRef} onScroll={onScroll} data-ck-dropzone>
        <div className="mx-messages__inner">
          {hasMore ? (
            <button type="button" className="mx-loadmore" onClick={() => loadOlder()} disabled={loadingOlder}>
              {loadingOlder ? 'Loading…' : 'Load earlier messages'}
            </button>
          ) : null}
          {!loading && !hasMore ? (
            <div className="mx-start">
              <Avatar name={title} url={other?.profile?.avatarUrl ?? null} seed={other?.userId ?? conversation.conversationId} size={72} />
              <p className="mx-start__title">{title}</p>
              <p className="mx-muted">This is the start of your conversation{other ? ` with ${title}` : ''}.</p>
            </div>
          ) : null}
          {loading ? <p className="mx-muted mx-center">Loading messages…</p> : null}
          {error && !loading && messages.length === 0 ? <p className="mx-error mx-center">Messages could not be loaded.</p> : null}

          {rows.map((row) => {
            if (row.type === 'day') {
              return (
                <div key={row.key} className="mx-day" role="separator">
                  <span>{dayLabel(row.at, new Date(), formatDate)}</span>
                </div>
              );
            }
            const { message, firstInGroup, lastInGroup } = row;
            const mine = message.author?.userId === self.userId;
            const author = message.author ?? { userId: null, displayName: 'Unknown' };
            const reply = message.replyToId ? byId.get(message.replyToId) : null;
            const isEditing = editing?.messageId === message.messageId;
            const isHit = activeHit === message.messageId;
            return (
              <div
                key={row.key}
                data-message-id={message.messageId}
                className={[
                  'mx-msg',
                  mine ? 'is-mine' : 'is-theirs',
                  firstInGroup ? 'is-first' : '',
                  lastInGroup ? 'is-last' : '',
                  message.delivery === 'failed' ? 'is-failed' : '',
                  message.delivery === 'sending' ? 'is-sending' : '',
                  isHit ? 'is-hit' : '',
                ].filter(Boolean).join(' ')}
              >
                {!mine ? (
                  <span className="mx-msg__gutter">
                    {lastInGroup ? (
                      <button type="button" className="mx-msg__avatar" onClick={() => onOpenProfile(author)} aria-label={`Profile of ${author.displayName}`}>
                        <Avatar name={author.displayName} url={author.avatarUrl ?? null} seed={author.userId} size={32} />
                      </button>
                    ) : null}
                  </span>
                ) : null}
                <div className="mx-msg__col">
                  {!mine && firstInGroup ? (
                    <button type="button" className="mx-msg__author" onClick={() => onOpenProfile(author)}>
                      {author.displayName}
                    </button>
                  ) : null}
                  <div className="mx-msg__line">
                    <div className="mx-bubble">
                      {message.replyToId ? (
                        <button type="button" className="mx-quote" onClick={() => jumpTo(message.replyToId)}>
                          <strong>{reply ? (reply.author?.userId === self.userId ? 'You' : reply.author?.displayName) : 'Reply'}</strong>
                          <span>{reply ? (reply.deletedAt ? 'Message deleted' : snippet(reply.body) || filesLabel(reply.files)) : 'to an earlier message'}</span>
                        </button>
                      ) : null}
                      {isEditing ? (
                        <form
                          className="mx-edit"
                          onSubmit={(event) => {
                            event.preventDefault();
                            saveEdit();
                          }}
                        >
                          <AutoTextarea
                            inputRef={editRef}
                            label="Edit message"
                            value={editing.text}
                            onChange={(event) => setEditing({ ...editing, text: event.target.value })}
                            onKeyDown={(event) => {
                              if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
                                event.preventDefault();
                                saveEdit();
                              }
                              if (event.key === 'Escape') {
                                event.stopPropagation();
                                setEditing(null);
                                setEditError(null);
                                composerRef.current?.focus();
                              }
                            }}
                          />
                          <span className="mx-edit__hint">
                            Enter to save · Esc to cancel
                            <span className="mx-edit__buttons">
                              <button type="button" className="mx-textbtn" onClick={() => setEditing(null)}>Cancel</button>
                              <button type="submit" className="mx-textbtn is-primary">Save</button>
                            </span>
                          </span>
                          {editError ? <span className="mx-error">{editError}</span> : null}
                        </form>
                      ) : message.deletedAt ? (
                        <em className="mx-deleted">This message was deleted</em>
                      ) : (
                        <>
                          <MessageFiles files={message.files ?? []} mine={mine} />
                          {message.body ? (
                            <span className="mx-bubble__text">
                              <Text body={message.body} query={search} />
                            </span>
                          ) : null}
                        </>
                      )}
                      {!isEditing ? (
                        <span className="mx-bubble__meta">
                          {message.editedAt && !message.deletedAt ? <span>edited · </span> : null}
                          {message.delivery === 'sending' ? 'Sending…' : formatTime(new Date(message.createdAt))}
                        </span>
                      ) : null}
                    </div>
                    {pickerFor === message.messageId ? (
                      <ReactionPicker align={mine ? 'end' : 'start'} onPick={(emoji) => toggleReaction(message, emoji)} onClose={() => setPickerFor(null)} />
                    ) : null}
                    {!isEditing ? (
                      <MessageActions
                        message={message}
                        mine={mine}
                        editable={canEdit(message, rules)}
                        deletable={canDelete(message, rules)}
                        onReact={() => setPickerFor(message.messageId)}
                        onReply={() => {
                          setReplyTo(message);
                          composerRef.current?.focus();
                        }}
                        onEdit={() => startEdit(message)}
                        onCopy={() => copy(message)}
                        onDelete={() => setConfirmDelete(message)}
                      />
                    ) : null}
                  </div>
                  {!message.deletedAt ? <ReactionChips reactions={message.reactions ?? []} mine={mine} onToggle={(emoji) => toggleReaction(message, emoji)} /> : null}
                  {message.delivery === 'failed' ? (
                    <button type="button" className="mx-retry" onClick={() => retry(message.clientMessageId)}>
                      Not sent. Tap to try again.
                    </button>
                  ) : null}
                </div>
              </div>
            );
          })}
          {typingUserIds.length ? <p className="mx-typing">{typingName ? `${typingName} is typing…` : 'Someone is typing…'}</p> : null}
        </div>
      </div>

      {notice ? <p className="mx-toast" role="status">{notice}</p> : null}

      <div className="mx-composer">
        <Composer
          files={files}
          inputRef={composerRef}
          placeholder={throttled ? 'Slow down a little — you can write again in a moment' : `Message ${title}`}
          disabled={disabled}
          disabledReason={disabledReason}
          onSend={sendFromComposer}
          onTyping={setTyping}
          onArrowUp={() => {
            const last = lastEditable(messages, rules);
            if (last) startEdit(last);
            return Boolean(last);
          }}
          onEscape={() => setReplyTo(null)}
          top={
            replyTo ? (
              <div className="mx-replychip">
                <span>
                  <strong>Replying to {replyTo.author?.userId === self.userId ? 'yourself' : replyTo.author?.displayName}</strong>
                  <span>{snippet(replyTo.body) || filesLabel(replyTo.files)}</span>
                </span>
                <button type="button" className="mx-iconbtn" onClick={() => setReplyTo(null)} aria-label="Cancel reply">×</button>
              </div>
            ) : null
          }
        />
      </div>

      {confirmDelete ? (
        <ConfirmDialog
          title="Delete this message?"
          body={`It is removed for everyone in this chat, with its files, and shows as “This message was deleted”. ${snippet(confirmDelete.body, 60) ? `“${snippet(confirmDelete.body, 60)}”` : filesLabel(confirmDelete.files)}`}
          confirmLabel="Delete for everyone"
          danger
          onConfirm={() => remove(confirmDelete.messageId)}
          onClose={() => setConfirmDelete(null)}
        />
      ) : null}
    </div>
  );
}
