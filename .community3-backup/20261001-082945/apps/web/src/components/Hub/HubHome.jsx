import { Link } from 'react-router-dom';
import ThreadRow from './ThreadRow.jsx';
import { spaceMark } from './hubModel.js';

/**
 * Community home: what is new in your spaces, in time order — no ranking, no
 * "you might like". Replies to your own threads first, then everything else.
 */
export default function HubHome({ home, displayName }) {
  if (!home) return <p className="hb-muted">Loading…</p>;
  const first = (displayName ?? '').split(' ')[0];

  if (home.spaces.length === 0) {
    return (
      <div className="hb-empty">
        <p className="hb-empty__title">{first ? `Welcome, ${first}.` : 'Welcome.'} Find your people.</p>
        <p className="hb-muted">
          Spaces are groups around a class, a subject or a goal. Nobody in them sees your email or phone number — only your name, and
          only what your privacy settings allow.
        </p>
        <div className="hb-inline">
          <Link className="btn btn--primary" to="/community?tab=discover">
            Discover spaces
          </Link>
          <Link className="btn" to="/community?tab=new">
            Create a space
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div className="hb-home">
      <header className="hb-head">
        <h1>{first ? `Hello, ${first}` : 'Community'}</h1>
        <p className="hb-muted">
          {home.openQuestions > 0 ? (
            <>
              {home.openQuestions} open {home.openQuestions === 1 ? 'question' : 'questions'} in your spaces.{' '}
              <Link to="/community?tab=questions">Help someone</Link>
            </>
          ) : (
            'Every question in your spaces is answered.'
          )}
        </p>
      </header>

      {home.live?.length ? (
        <section className="hb-block hb-block--live" aria-label="Live now">
          {home.live.map((room) => (
            <div key={room.code} className="hb-livebar">
              <span className="hb-livedot" aria-hidden="true" />
              <span>
                <strong>Live in {room.spaceName}:</strong> {room.title}, {room.here} {room.here === 1 ? 'person' : 'people'} inside
              </span>
              <Link className="btn btn--primary btn--tiny" to={`/rooms/${room.code}/lobby`}>
                Join
              </Link>
            </div>
          ))}
        </section>
      ) : null}

      <div className="hb-tiles">
        {home.spaces.slice(0, 6).map((space) => (
          <Link key={space.spaceId} to={`/community/spaces/${space.spaceId}`} className="hb-tile">
            <span className={`hb-mark hb-mark--${space.kind} hb-mark--big`} aria-hidden="true">
              {spaceMark(space)}
            </span>
            <span className="hb-tile__name">{space.name}</span>
            <span className="hb-muted">
              {space.newActivity > 0 ? `${space.newActivity} new` : `${space.memberCount} ${space.memberCount === 1 ? 'member' : 'members'}`}
            </span>
          </Link>
        ))}
      </div>

      {home.myThreads.length > 0 ? (
        <section className="hb-block">
          <h2 className="hb-block__title">Replies to what you wrote</h2>
          <div className="hb-list">
            {home.myThreads.map((thread) => (
              <ThreadRow key={thread.threadId} thread={thread} showSpace />
            ))}
          </div>
        </section>
      ) : null}

      <section className="hb-block">
        <h2 className="hb-block__title">Latest in your spaces</h2>
        {home.recent.length === 0 ? (
          <p className="hb-muted">Quiet so far. Start a thread in one of your spaces.</p>
        ) : (
          <div className="hb-list">
            {home.recent.map((thread) => (
              <ThreadRow key={thread.threadId} thread={thread} showSpace />
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
