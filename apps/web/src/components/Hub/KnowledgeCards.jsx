import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { paragraphs } from './hubModel.js';
import { relativeTime } from '../Settings/notificationsModel.js';

/**
 * Knowledge cards  (Community, part 2)
 *
 * Good answers, saved once and found again — so the same question does not
 * have to be answered every term. Moderators save cards (from any reply, or
 * written here); everyone in the space searches and reads them.
 */
export default function KnowledgeCards({ hub, space }) {
  const [q, setQ] = useState('');
  const [data, setData] = useState(null);
  const [open, setOpen] = useState(null);
  const [editing, setEditing] = useState(null);
  const [draft, setDraft] = useState({ title: '', body: '' });
  const [error, setError] = useState(null);

  const load = useCallback(
    async (signal) => {
      try {
        setData(await hub.cards(space.spaceId, q.trim(), signal));
      } catch {
        if (!signal?.aborted) setData({ items: [], canCurate: false });
      }
    },
    [hub, space.spaceId, q],
  );

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => load(controller.signal), 200);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [load]);

  const save = async () => {
    setError(null);
    try {
      if (editing === 'new') await hub.createCard(space.spaceId, { title: draft.title.trim(), body: draft.body.trim() });
      else await hub.updateCard(editing, { title: draft.title.trim(), body: draft.body.trim() });
      setEditing(null);
      await load();
    } catch (cause) {
      setError(cause?.detail ?? 'Not saved.');
    }
  };

  const remove = async (cardId) => {
    if (!window.confirm('Remove this card?')) return;
    await hub.removeCard(cardId).catch(() => undefined);
    await load();
  };

  const editor = (
    <div className="hb-composer">
      <input className="hb-input hb-input--title" placeholder="What does this card answer?" maxLength={160} value={draft.title} onChange={(event) => setDraft({ ...draft, title: event.target.value })} autoFocus />
      <textarea className="hb-input" rows={6} maxLength={10000} placeholder="The answer, written so it helps someone next term." value={draft.body} onChange={(event) => setDraft({ ...draft, body: event.target.value })} />
      {error ? <p className="hb-error">{error}</p> : null}
      <div className="hb-inline">
        <button type="button" className="btn btn--primary" disabled={draft.title.trim().length < 3 || !draft.body.trim()} onClick={save}>
          Save card
        </button>
        <button type="button" className="hb-link" onClick={() => setEditing(null)}>
          Cancel
        </button>
      </div>
    </div>
  );

  return (
    <div>
      <div className="hb-toolbar">
        <input className="hb-input hb-search" type="search" placeholder="Search the knowledge of this space" value={q} onChange={(event) => setQ(event.target.value)} aria-label="Search cards" />
        {data?.canCurate && editing === null ? (
          <button type="button" className="btn" onClick={() => { setDraft({ title: '', body: '' }); setEditing('new'); }}>
            New card
          </button>
        ) : null}
      </div>
      {editing === 'new' ? editor : null}
      {data === null ? <p className="hb-muted">Loading…</p> : null}
      {data?.items.length === 0 && editing === null ? (
        <p className="hb-muted">
          {q ? 'No card matches.' : 'No knowledge cards yet.'}
          {data.canCurate && !q ? ' Save a good answer from any thread with “Save as knowledge card”.' : ''}
        </p>
      ) : null}
      <div className="hb-cardlist">
        {(data?.items ?? []).map((card) =>
          editing === card.cardId ? (
            <div key={card.cardId}>{editor}</div>
          ) : (
            <article key={card.cardId} className={open === card.cardId ? 'hb-kcard is-open' : 'hb-kcard'}>
              <button type="button" className="hb-kcard__head" aria-expanded={open === card.cardId} onClick={() => setOpen(open === card.cardId ? null : card.cardId)}>
                <span className="hb-kcard__title">{card.title}</span>
                <span className="hb-kcard__chev" aria-hidden="true" />
              </button>
              <div className="hb-kcard__body">
                <div>
                  {paragraphs(card.body).map((part, index) => (
                    <p key={index}>{part}</p>
                  ))}
                  <p className="hb-kcard__meta">
                    {card.createdBy ? `Saved by ${card.createdBy}, ` : ''}
                    {relativeTime(card.updatedAt)}
                    {card.threadId ? (
                      <>
                        {' '}
                        <Link to={`/community/threads/${card.threadId}`}>From this thread</Link>
                      </>
                    ) : null}
                  </p>
                  {data.canCurate ? (
                    <div className="hb-inline">
                      <button type="button" className="hb-link" onClick={() => { setDraft({ title: card.title, body: card.body }); setEditing(card.cardId); }}>
                        Edit
                      </button>
                      <button type="button" className="hb-link hb-link--danger" onClick={() => remove(card.cardId)}>
                        Remove
                      </button>
                    </div>
                  ) : null}
                </div>
              </div>
            </article>
          ),
        )}
      </div>
    </div>
  );
}
