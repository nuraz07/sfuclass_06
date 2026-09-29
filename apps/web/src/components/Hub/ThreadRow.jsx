import { Link } from 'react-router-dom';
import { relativeTime } from '../Settings/notificationsModel.js';
import { threadBadge } from './hubModel.js';

/** One thread in a list: title, excerpt, who, when, replies, "me too". */
export default function ThreadRow({ thread, showSpace = false }) {
  const badge = threadBadge(thread);
  return (
    <Link to={`/community/threads/${thread.threadId}`} className={thread.pinned ? 'hb-row is-pinned' : 'hb-row'}>
      <div className="hb-row__main">
        <p className="hb-row__meta">
          {badge ? <span className={`hb-badge hb-badge--${badge.tone}`}>{badge.text}</span> : null}
          {thread.pinned ? <span className="hb-badge hb-badge--pin">Pinned</span> : null}
          {thread.locked ? <span className="hb-badge">Locked</span> : null}
          {showSpace && thread.spaceName ? (
            <span className="hb-row__space">
              {thread.spaceEmoji ? `${thread.spaceEmoji} ` : ''}
              {thread.spaceName}
            </span>
          ) : null}
        </p>
        <p className="hb-row__title">{thread.title}</p>
        {thread.excerpt ? <p className="hb-row__excerpt">{thread.excerpt}</p> : null}
        <p className="hb-row__by">
          {thread.author.anonymous && !thread.author.you ? <span className="hb-anon">Anonymous</span> : thread.author.displayName}
          {thread.author.you ? ' (you)' : ''}, {relativeTime(thread.lastPostAt) || 'just now'}
        </p>
      </div>
      <div className="hb-row__stats" aria-label={`${thread.replies} replies${thread.kind === 'question' ? `, ${thread.metoo} with the same question` : ''}`}>
        <span className="hb-stat">
          <strong>{thread.replies}</strong> {thread.replies === 1 ? 'reply' : 'replies'}
        </span>
        {thread.kind === 'question' && thread.metoo > 0 ? (
          <span className={thread.myMetoo ? 'hb-stat is-mine' : 'hb-stat'}>
            <strong>{thread.metoo}</strong> me too
          </span>
        ) : null}
      </div>
    </Link>
  );
}
