import { useEffect, useState } from 'react';
import ThreadRow from './ThreadRow.jsx';

/**
 * Questions from all your spaces in one place. "Most shared" puts the
 * questions with the most "me too" first — what many people are stuck on.
 */
export default function HubQuestions({ hub }) {
  const [filter, setFilter] = useState('unanswered');
  const [sort, setSort] = useState('metoo');
  const [items, setItems] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    setItems(null);
    hub
      .questions({ filter, sort }, controller.signal)
      .then((result) => setItems(result.items))
      .catch(() => !controller.signal.aborted && setItems([]));
    return () => controller.abort();
  }, [hub, filter, sort]);

  return (
    <div>
      <header className="hb-head">
        <h1>Questions</h1>
        <p className="hb-muted">From every space you are in. “Me too” shows what many people are stuck on.</p>
      </header>
      <div className="hb-toolbar">
        <div className="hb-segment" role="tablist" aria-label="Which questions">
          {[
            ['unanswered', 'Open'],
            ['answered', 'Answered'],
            ['all', 'All'],
          ].map(([value, label]) => (
            <button key={value} type="button" role="tab" aria-selected={filter === value} className={filter === value ? 'is-on' : ''} onClick={() => setFilter(value)}>
              {label}
            </button>
          ))}
        </div>
        <label className="hb-sort">
          Sort
          <select className="hb-input" value={sort} onChange={(event) => setSort(event.target.value)}>
            <option value="metoo">Most shared</option>
            <option value="new">Newest</option>
          </select>
        </label>
      </div>
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? (
        <p className="hb-muted">{filter === 'unanswered' ? 'No open questions. Nice.' : 'Nothing here yet.'}</p>
      ) : null}
      <div className="hb-list">
        {(items ?? []).map((thread) => (
          <ThreadRow key={thread.threadId} thread={thread} showSpace />
        ))}
      </div>
    </div>
  );
}
