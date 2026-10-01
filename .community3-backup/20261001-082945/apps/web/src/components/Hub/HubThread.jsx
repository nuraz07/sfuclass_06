import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import ReportButton from './ReportButton.jsx';
import { paragraphs, spaceMark } from './hubModel.js';
import { relativeTime } from '../Settings/notificationsModel.js';

/**
 * One thread  (Community, part 1)
 *
 * The question or opening post, then the replies. For a question: the
 * accepted answer is marked and shown first below the question, "me too"
 * counts who shares it (never who), and the asker or a moderator can mark
 * any reply as the answer. Text is shown as text — never as HTML.
 *
 * Part 2: a reply can be posted as a hidden solution — others see it folded
 * and open it deliberately, after trying themselves. Moderators can save any
 * reply as a knowledge card for the space.
 */

function Folded({ children }) {
  const [open, setOpen] = useState(false);
  if (open) return children;
  return (
    <div className="hb-folded">
      <div className="hb-folded__veil" aria-hidden="true">
        {children}
      </div>
      <div className="hb-folded__cover">
        <p className="hb-label">Solution hidden</p>
        <p className="hb-muted">Try it yourself first. Open it when you are ready.</p>
        <button type="button" className="btn btn--tiny" onClick={() => setOpen(true)}>
          Show solution
        </button>
      </div>
    </div>
  );
}

function SaveCard({ hub, thread, post, onSaved }) {
  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState(thread.title);
  const [state, setState] = useState('idle');
  if (state === 'saved') return <span className="hb-muted">Saved as a knowledge card.</span>;
  if (!open) {
    return (
      <button type="button" className="hb-link" onClick={() => setOpen(true)}>
        Save as knowledge card
      </button>
    );
  }
  const save = async () => {
    setState('saving');
    try {
      await hub.createCard(thread.space.spaceId, { title: title.trim(), body: post.body, postId: post.postId });
      setState('saved');
      onSaved?.();
    } catch {
      setState('error');
    }
  };
  return (
    <span className="hb-savecard">
      <input className="hb-input hb-input--small" value={title} maxLength={160} onChange={(event) => setTitle(event.target.value)} aria-label="Card title" />
      <button type="button" className="btn btn--primary btn--tiny" disabled={state === 'saving' || title.trim().length < 3} onClick={save}>
        Save
      </button>
      <button type="button" className="hb-link" onClick={() => setOpen(false)}>
        Cancel
      </button>
      {state === 'error' ? <span className="hb-error">Not saved.</span> : null}
    </span>
  );
}

function Body({ text }) {
  return (
    <div className="hb-post__body">
      {paragraphs(text).map((part, index) => (
        <p key={index}>{part}</p>
      ))}
    </div>
  );
}

function Author({ author }) {
  if (author.anonymous && !author.you && !author.revealedToModerator) {
    return <span className="hb-anon">Anonymous</span>;
  }
  return (
    <span className="hb-post__author">
      {author.displayName}
      {author.you ? ' (you)' : ''}
      {author.anonymous && author.you ? <span className="hb-badge">Shown as anonymous</span> : null}
      {author.revealedToModerator ? <span className="hb-badge hb-badge--warn">Anonymous to members</span> : null}
    </span>
  );
}

export default function HubThread({ hub, threadId, bump }) {
  const navigate = useNavigate();
  const [thread, setThread] = useState(null);
  const [error, setError] = useState(null);
  const [reply, setReply] = useState('');
  const [hiddenSolution, setHiddenSolution] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    hub
      .thread(threadId, controller.signal)
      .then(setThread)
      .catch((cause) => !controller.signal.aborted && setError(cause?.detail ?? 'This thread does not exist, or it is not shared with you.'));
    return () => controller.abort();
  }, [hub, threadId]);

  if (error) return <p className="hb-error">{error}</p>;
  if (!thread) return <p className="hb-muted">Loading…</p>;

  const run = async (fn) => {
    setBusy(true);
    try {
      const next = await fn();
      if (next?.threadId) setThread(next);
      return next;
    } catch (cause) {
      setError(cause?.detail ?? 'That did not work.');
      return null;
    } finally {
      setBusy(false);
    }
  };

  const send = async (event) => {
    event.preventDefault();
    if (!reply.trim()) return;
    const next = await run(() => hub.reply(thread.threadId, reply.trim(), null, question && hiddenSolution));
    if (next) {
      setReply('');
      setHiddenSolution(false);
      bump();
    }
  };

  const [first, ...rest] = thread.posts;
  const answer = rest.find((post) => post.answer);
  const others = rest.filter((post) => !post.answer);
  const question = thread.kind === 'question';

  const Post = ({ post, highlight = false }) => (
    <article className={`hb-post${highlight ? ' is-answer' : ''}`} id={`post-${post.postId}`}>
      <header className="hb-post__head">
        <Author author={post.author} />
        <span className="hb-muted">{relativeTime(post.createdAt) || 'just now'}</span>
        {highlight ? <span className="hb-badge hb-badge--done">Answer</span> : null}
        {post.hiddenSolution && !post.folded ? <span className="hb-badge hb-badge--pin">Hidden solution</span> : null}
      </header>
      {post.folded ? (
        <Folded>
          <Body text={post.body} />
        </Folded>
      ) : (
        <Body text={post.body} />
      )}
      <footer className="hb-post__foot">
        {thread.me.canMarkAnswer && !post.first ? (
          <button type="button" className="hb-link" disabled={busy} onClick={() => run(() => hub.markAnswer(thread.threadId, post.answer ? null : post.postId))}>
            {post.answer ? 'Unmark answer' : 'Mark as the answer'}
          </button>
        ) : null}
        {post.canRemove ? (
          <button type="button" className="hb-link hb-link--danger" disabled={busy} onClick={() => window.confirm('Remove this reply?') && run(() => hub.removePost(post.postId))}>
            Remove
          </button>
        ) : null}
        {thread.me.canSaveCard && !post.first ? <SaveCard hub={hub} thread={thread} post={post} /> : null}
        {!post.author.you && !post.first ? <ReportButton hub={hub} spaceId={thread.space.spaceId} targetType="post" targetId={post.postId} /> : null}
      </footer>
    </article>
  );

  return (
    <div className="hb-thread">
      <p className="hb-crumbs">
        <Link to={`/community/spaces/${thread.space.spaceId}`}>
          <span className={`hb-mark hb-mark--${thread.space.kind}`} aria-hidden="true">
            {spaceMark(thread.space)}
          </span>
          {thread.space.name}
        </Link>
      </p>

      <article className="hb-post hb-post--first">
        <p className="hb-row__meta">
          {question ? <span className={thread.answered ? 'hb-badge hb-badge--done' : 'hb-badge hb-badge--open'}>{thread.answered ? 'Answered' : 'Question'}</span> : null}
          {thread.pinned ? <span className="hb-badge hb-badge--pin">Pinned</span> : null}
          {thread.locked ? <span className="hb-badge">Locked</span> : null}
        </p>
        <h1 className="hb-thread__title">{thread.title}</h1>
        <header className="hb-post__head">
          <Author author={first.author} />
          <span className="hb-muted">{relativeTime(first.createdAt) || 'just now'}</span>
        </header>
        <Body text={first.body} />
        <footer className="hb-post__foot">
          {question ? (
            <button
              type="button"
              className={thread.myMetoo ? 'hb-metoo is-on' : 'hb-metoo'}
              disabled={busy || !thread.me.canMetoo}
              aria-pressed={thread.myMetoo}
              title={thread.me.canMetoo ? 'Shows how many people share this question. Names are never listed.' : undefined}
              onClick={() => run(() => hub.metoo(thread.threadId))}
            >
              {thread.myMetoo ? 'You have this question too' : 'I have this question too'}
              <span className="hb-metoo__count">{thread.metoo}</span>
            </button>
          ) : null}
          {thread.me.moderator ? (
            <>
              <button type="button" className="hb-link" disabled={busy} onClick={() => run(() => hub.moderateThread(thread.threadId, { pinned: !thread.pinned }))}>
                {thread.pinned ? 'Unpin' : 'Pin'}
              </button>
              <button type="button" className="hb-link" disabled={busy} onClick={() => run(() => hub.moderateThread(thread.threadId, { locked: !thread.locked }))}>
                {thread.locked ? 'Unlock' : 'Lock'}
              </button>
            </>
          ) : null}
          {thread.me.canRemoveThread ? (
            <button
              type="button"
              className="hb-link hb-link--danger"
              disabled={busy}
              onClick={async () => {
                if (!window.confirm('Remove this thread and its replies?')) return;
                const done = await run(() => hub.removeThread(thread.threadId));
                if (done) {
                  bump();
                  navigate(`/community/spaces/${thread.space.spaceId}`);
                }
              }}
            >
              Remove thread
            </button>
          ) : null}
          {!first.author.you ? <ReportButton hub={hub} spaceId={thread.space.spaceId} targetType="thread" targetId={thread.threadId} /> : null}
        </footer>
      </article>

      {answer ? <Post post={answer} highlight /> : null}

      <h2 className="hb-thread__count">
        {thread.replies === 0 ? 'No replies yet' : `${thread.replies} ${thread.replies === 1 ? 'reply' : 'replies'}`}
      </h2>
      {others.map((post) => (
        <Post key={post.postId} post={post} />
      ))}

      {thread.me.canReply ? (
        <form className="hb-composer hb-composer--reply" onSubmit={send}>
          <label className="hb-label" htmlFor="hb-reply">
            {question && !thread.answered ? 'Your answer' : 'Your reply'}
          </label>
          <textarea id="hb-reply" className="hb-input" rows={4} maxLength={10000} value={reply} onChange={(event) => setReply(event.target.value)} placeholder={question ? 'Explain it the way you would have wanted it explained.' : 'Write a reply'} />
          {question ? (
            <label className="hb-check">
              <input type="checkbox" checked={hiddenSolution} onChange={(event) => setHiddenSolution(event.target.checked)} />
              <span>
                <span className="hb-label">Hide as a solution</span>
                <span className="hb-muted">Others see it folded and open it when they are ready — so they can try first.</span>
              </span>
            </label>
          ) : null}
          <div className="hb-inline">
            <button type="submit" className="btn btn--primary" disabled={busy || !reply.trim()}>
              {busy ? 'Sending…' : 'Reply'}
            </button>
          </div>
        </form>
      ) : (
        <p className="hb-note">{thread.me.replyBlocked ?? 'Join the space to reply.'}</p>
      )}
    </div>
  );
}
