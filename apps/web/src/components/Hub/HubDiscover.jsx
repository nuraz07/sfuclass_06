import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ACCESS, KIND_LABEL, endsLabel, spaceMark } from './hubModel.js';

/**
 * Spaces in your organisation you are not in yet. Invite-only spaces never
 * appear here. Open spaces can be joined at once; the others take a request.
 */
export default function HubDiscover({ hub, onChanged }) {
  const [q, setQ] = useState('');
  const [kind, setKind] = useState('');
  const [items, setItems] = useState(null);
  const [busy, setBusy] = useState(null);
  const [asking, setAsking] = useState(null);
  const [answer, setAnswer] = useState('');

  const load = async (signal) => {
    try {
      setItems((await hub.spaces({ scope: 'discover', q: q.trim() || undefined, kind: kind || undefined }, signal)).items);
    } catch {
      if (!signal?.aborted) setItems([]);
    }
  };

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => load(controller.signal), 250);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hub, q, kind]);

  const join = async (space, withAnswer = null) => {
    setBusy(space.spaceId);
    try {
      await hub.join(space.spaceId, withAnswer);
      setAsking(null);
      setAnswer('');
      await load();
      onChanged();
    } finally {
      setBusy(null);
    }
  };

  return (
    <div>
      <header className="hb-head">
        <h1>Discover</h1>
        <p className="hb-muted">Spaces in your organisation. Joining shows your name to members — never your email.</p>
      </header>
      <div className="hb-toolbar">
        <input className="hb-input hb-search" type="search" placeholder="Search by name, topic or tag" value={q} onChange={(event) => setQ(event.target.value)} aria-label="Search spaces" />
        <select className="hb-input" value={kind} onChange={(event) => setKind(event.target.value)} aria-label="Kind">
          <option value="">All kinds</option>
          <option value="topic">Topics</option>
          <option value="study">Study groups</option>
          <option value="class">Classes</option>
        </select>
      </div>
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? <p className="hb-muted">Nothing found. <Link to="/community?tab=new">Create the space you are looking for.</Link></p> : null}
      <div className="hb-cards">
        {(items ?? []).map((space) => {
          const access = ACCESS.find((entry) => entry.value === space.access);
          const ends = endsLabel(space.endsAt);
          return (
            <article key={space.spaceId} className="hb-card">
              <div className="hb-card__top">
                <span className={`hb-mark hb-mark--${space.kind} hb-mark--big`} aria-hidden="true">
                  {spaceMark(space)}
                </span>
                <div>
                  <p className="hb-card__name">{space.name}</p>
                  <p className="hb-muted">
                    {KIND_LABEL[space.kind]}, {space.memberCount} {space.memberCount === 1 ? 'member' : 'members'}
                    {ends ? `, ${ends.toLowerCase()}` : ''}
                  </p>
                </div>
              </div>
              {space.description ? <p className="hb-card__text">{space.description}</p> : null}
              {space.tags.length ? (
                <p className="hb-tags">
                  {space.tags.map((tag) => (
                    <button key={tag} type="button" className="hb-tag" onClick={() => setQ(tag)}>
                      {tag}
                    </button>
                  ))}
                </p>
              ) : null}
              <div className="hb-card__foot">
                {space.access === 'open' ? (
                  <>
                    <Link to={`/community/spaces/${space.spaceId}`} className="hb-link">
                      Look inside
                    </Link>
                    <button type="button" className="btn btn--primary" disabled={busy === space.spaceId} onClick={() => join(space)}>
                      Join
                    </button>
                  </>
                ) : space.myRequest === 'pending' ? (
                  <span className="hb-muted">Request sent. A moderator decides.</span>
                ) : asking === space.spaceId ? (
                  <div className="hb-ask">
                    {space.joinQuestion ? <label className="hb-label">{space.joinQuestion}</label> : null}
                    <input className="hb-input" maxLength={500} placeholder={space.joinQuestion ? 'Your answer' : 'A short note (optional)'} value={answer} onChange={(event) => setAnswer(event.target.value)} />
                    <div className="hb-inline">
                      <button type="button" className="btn btn--primary" disabled={busy === space.spaceId} onClick={() => join(space, answer.trim() || null)}>
                        Send request
                      </button>
                      <button type="button" className="hb-link" onClick={() => setAsking(null)}>
                        Cancel
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <span className="hb-muted">{access?.label}</span>
                    <button type="button" className="btn" onClick={() => setAsking(space.spaceId)}>
                      Ask to join
                    </button>
                  </>
                )}
              </div>
            </article>
          );
        })}
      </div>
    </div>
  );
}
