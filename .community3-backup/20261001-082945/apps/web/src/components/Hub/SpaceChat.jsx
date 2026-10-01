import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { useCore } from '@classroom/core-client';
import { onUserEvent } from '../../lib/userEvents.js';
import { dayLabel, groupMessages } from './hubModel.js';

/**
 * The chat of a space  (Community, part 2)
 *
 * Quick messages next to the threads. New messages arrive at once when the
 * server can tell this tab (hub:chat), and otherwise within a few seconds.
 * Enter sends, Shift+Enter starts a new line. People you blocked, or who
 * blocked you, are not shown.
 */

const POLL_MS = 5_000;

export default function SpaceChat({ hub, space }) {
  const core = useCore();
  const [items, setItems] = useState(null);
  const [blocked, setBlocked] = useState(null);
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [error, setError] = useState(null);
  const cursor = useRef(null);
  const listRef = useRef(null);
  const nearBottom = useRef(true);
  const busy = useRef(false);

  const merge = useCallback((incoming) => {
    if (!incoming.length) return;
    setItems((current) => {
      const seen = new Set((current ?? []).map((item) => item.messageId));
      return [...(current ?? []), ...incoming.filter((item) => !seen.has(item.messageId))];
    });
  }, []);

  const fetchNew = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    try {
      const page = await hub.chat(space.spaceId, cursor.current);
      if (cursor.current === null) setItems(page.items);
      else merge(page.items);
      cursor.current = page.nextCursor ?? cursor.current;
      setBlocked(page.postingBlocked);
    } catch {
      setItems((current) => current ?? []);
    } finally {
      busy.current = false;
    }
  }, [hub, space.spaceId, merge]);

  useEffect(() => {
    cursor.current = null;
    fetchNew();
    const timer = window.setInterval(() => document.visibilityState === 'visible' && fetchNew(), POLL_MS);
    const off = onUserEvent(core, 'hub:chat', (payload) => {
      if (!payload?.spaceId || payload.spaceId === space.spaceId) fetchNew();
    });
    return () => {
      window.clearInterval(timer);
      off();
    };
  }, [core, fetchNew, space.spaceId]);

  // Stay at the bottom while the reader is there; never yank them down while they scroll back.
  useLayoutEffect(() => {
    const list = listRef.current;
    if (list && nearBottom.current) list.scrollTop = list.scrollHeight;
  }, [items]);

  const onScroll = () => {
    const list = listRef.current;
    nearBottom.current = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
  };

  const send = async () => {
    const body = draft.trim();
    if (!body || sending) return;
    setSending(true);
    setError(null);
    try {
      const message = await hub.sendChat(space.spaceId, body);
      nearBottom.current = true;
      merge([message]);
      cursor.current = message.cursor;
      setDraft('');
    } catch (cause) {
      setError(cause?.detail ?? 'Not sent. Try again.');
    } finally {
      setSending(false);
    }
  };

  const remove = async (messageId) => {
    await hub.removeChat(messageId).catch(() => undefined);
    setItems((current) => (current ?? []).filter((item) => item.messageId !== messageId));
  };

  const groups = groupMessages(items ?? []);
  let lastDay = null;

  return (
    <div className="hb-chat">
      <div className="hb-chat__list" ref={listRef} onScroll={onScroll} aria-live="polite">
        {items === null ? <p className="hb-muted">Loading…</p> : null}
        {items?.length === 0 ? <p className="hb-chat__empty">No messages yet. Say hello to the space.</p> : null}
        {groups.map((group) => {
          const day = dayLabel(group.items[0].createdAt);
          const divider = day !== lastDay ? <p className="hb-chat__day" key={`d-${group.key}`}>{day}</p> : null;
          lastDay = day;
          return [
            divider,
            <div key={group.key} className={group.author.you ? 'hb-msggroup is-mine' : 'hb-msggroup'}>
              {!group.author.you ? (
                <span className="hb-avatar hb-avatar--small" aria-hidden="true">
                  {group.author.displayName.charAt(0).toUpperCase()}
                </span>
              ) : null}
              <div className="hb-msggroup__body">
                <p className="hb-msggroup__who">
                  {group.author.you ? 'You' : group.author.displayName}
                  <span className="hb-muted">
                    {new Date(group.items[0].createdAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                  </span>
                </p>
                {group.items.map((message) => (
                  <div key={message.messageId} className="hb-msg">
                    <p className="hb-msg__text">{message.body}</p>
                    {message.canRemove ? (
                      <button type="button" className="hb-msg__remove" aria-label="Remove message" onClick={() => remove(message.messageId)}>
                        ×
                      </button>
                    ) : null}
                  </div>
                ))}
              </div>
            </div>,
          ];
        })}
      </div>

      {blocked ? (
        <p className="hb-note">{blocked}</p>
      ) : (
        <form
          className="hb-chat__composer"
          onSubmit={(event) => {
            event.preventDefault();
            send();
          }}
        >
          <textarea
            className="hb-input"
            rows={1}
            maxLength={2000}
            placeholder={`Message ${space.name}`}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                send();
              }
            }}
            aria-label="Message"
          />
          <button type="submit" className="btn btn--primary" disabled={sending || !draft.trim()}>
            Send
          </button>
        </form>
      )}
      {error ? <p className="hb-error">{error}</p> : null}
    </div>
  );
}
