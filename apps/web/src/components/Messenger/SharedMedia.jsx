import { useEffect, useState } from 'react';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDate } from '../../lib/preferences.js';
import { VoicePlayer } from '../ChatKit/MessageFiles.jsx';

/**
 * Everything shared in a conversation  (Messages)
 *
 * Three tabs, newest first: Media (pictures and videos as a grid), Files
 * (documents and other files) and Voice (voice messages, playable here).
 * "Show more" loads older ones. Only what you can still see in the chat.
 */

const TABS = [
  { kind: 'media', label: 'Media' },
  { kind: 'files', label: 'Files' },
  { kind: 'voice', label: 'Voice' },
];

export default function SharedMedia({ api, conversationId, refreshKey = 0 }) {
  const [kind, setKind] = useState('media');
  const [state, setState] = useState({ items: null, nextBefore: null, error: null });
  const [more, setMore] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    setState({ items: null, nextBefore: null, error: null });
    api
      .media(conversationId, { kind }, controller.signal)
      .then((page) => setState({ items: page.items, nextBefore: page.nextBefore, error: null }))
      .catch(() => !controller.signal.aborted && setState({ items: [], nextBefore: null, error: 'This could not be loaded.' }));
    return () => controller.abort();
  }, [api, conversationId, kind, refreshKey]);

  const loadMore = async () => {
    setMore(true);
    try {
      const page = await api.media(conversationId, { kind, before: state.nextBefore });
      setState((current) => ({ ...current, items: [...current.items, ...page.items], nextBefore: page.nextBefore }));
    } finally {
      setMore(false);
    }
  };

  const items = state.items ?? [];
  return (
    <div className="mx-shared">
      <div className="mx-tabs" role="tablist" aria-label="Shared in this chat">
        {TABS.map((tab) => (
          <button key={tab.kind} type="button" role="tab" aria-selected={kind === tab.kind} className={kind === tab.kind ? 'is-on' : ''} onClick={() => setKind(tab.kind)}>
            {tab.label}
          </button>
        ))}
      </div>
      {state.items === null ? <p className="mx-muted">Loading…</p> : null}
      {state.error ? <p className="mx-muted">{state.error}</p> : null}
      {state.items && !items.length && !state.error ? (
        <p className="mx-muted">{kind === 'media' ? 'No pictures or videos yet.' : kind === 'files' ? 'No files yet.' : 'No voice messages yet.'}</p>
      ) : null}

      {kind === 'media' && items.length ? (
        <ul className="mx-shared__grid">
          {items.map((item) => (
            <li key={`${item.messageId}-${item.fileId}`}>
              <a href={fileHref(item.openUrl)} target="_blank" rel="noopener noreferrer" title={`${item.name} · ${item.authorName}, ${formatDate(item.sentAt)}`}>
                {item.kind === 'image' ? <img src={fileHref(item.openUrl)} alt={item.name} loading="lazy" decoding="async" /> : <span className="mx-shared__video" aria-hidden="true">▶</span>}
              </a>
            </li>
          ))}
        </ul>
      ) : null}

      {kind === 'files' && items.length ? (
        <ul className="mx-shared__list">
          {items.map((item) => (
            <li key={`${item.messageId}-${item.fileId}`}>
              <span aria-hidden="true">{iconFor(item.kind)}</span>
              <span className="mx-shared__text">
                <a href={fileHref(item.openUrl)} target="_blank" rel="noopener noreferrer">{item.name}</a>
                <span className="mx-muted">{fileMeta(item)} · {item.authorName}, {formatDate(item.sentAt)}</span>
              </span>
            </li>
          ))}
        </ul>
      ) : null}

      {kind === 'voice' && items.length ? (
        <ul className="mx-shared__list">
          {items.map((item) => (
            <li key={`${item.messageId}-${item.fileId}`} className="mx-shared__voice">
              <span className="mx-muted">{item.authorName}, {formatDate(item.sentAt)}</span>
              <VoicePlayer src={fileHref(item.openUrl)} durationMs={item.durationMs ?? 0} />
            </li>
          ))}
        </ul>
      ) : null}

      {state.nextBefore ? (
        <button type="button" className="btn" onClick={loadMore} disabled={more}>
          {more ? 'Loading…' : 'Show more'}
        </button>
      ) : null}
    </div>
  );
}
