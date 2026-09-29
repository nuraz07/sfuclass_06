import { useCallback, useEffect, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import ThreadRow from './ThreadRow.jsx';
import ReportButton from './ReportButton.jsx';
import { ACCESS, KIND_LABEL, ROLE_LABEL, TIMEOUTS, endsLabel, spaceMark, tabFrom, validateThreadForm } from './hubModel.js';
import { relativeTime } from '../Settings/notificationsModel.js';

/**
 * One space  (Community, part 1)
 *
 *   threads   discussions and questions; start one, filter to open questions
 *   members   names and roles — or only the moderators, if the space says so
 *   requests  people asking to join                       moderators
 *   reports   what members reported                       moderators
 *   about     description, rules of entry; settings        moderators edit
 */

function NewThread({ hub, space, onCreated }) {
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState('discussion');
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [anonymous, setAnonymous] = useState(false);
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const errors = validateThreadForm({ title, body });
  const navigate = useNavigate();

  if (!open) {
    return (
      <div className="hb-starter">
        <button type="button" className="hb-starter__button" onClick={() => { setKind('question'); setOpen(true); }}>
          Ask a question
        </button>
        <button type="button" className="hb-starter__button" onClick={() => { setKind('discussion'); setOpen(true); }}>
          Start a discussion
        </button>
      </div>
    );
  }

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length) return;
    setBusy(true);
    setError(null);
    try {
      const thread = await hub.createThread(space.spaceId, { title: title.trim(), body: body.trim(), kind, anonymous: kind === 'question' && anonymous });
      onCreated();
      navigate(`/community/threads/${thread.threadId}`);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'It was not posted.');
      setBusy(false);
    }
  };

  return (
    <form className="hb-composer" onSubmit={submit} noValidate>
      <div className="hb-segment" role="tablist" aria-label="Kind">
        <button type="button" role="tab" aria-selected={kind === 'question'} className={kind === 'question' ? 'is-on' : ''} onClick={() => setKind('question')}>
          Question
        </button>
        <button type="button" role="tab" aria-selected={kind === 'discussion'} className={kind === 'discussion' ? 'is-on' : ''} onClick={() => setKind('discussion')}>
          Discussion
        </button>
      </div>
      <input className="hb-input hb-input--title" placeholder={kind === 'question' ? 'Your question in one line' : 'Title'} maxLength={160} value={title} onChange={(event) => setTitle(event.target.value)} aria-invalid={Boolean(touched && errors.title)} autoFocus />
      {touched && errors.title ? <p className="hb-error">{errors.title}</p> : null}
      <textarea className="hb-input" rows={5} maxLength={10000} placeholder={kind === 'question' ? 'What have you tried? Where exactly are you stuck?' : 'What would you like to talk about?'} value={body} onChange={(event) => setBody(event.target.value)} aria-invalid={Boolean(touched && errors.body)} />
      {touched && errors.body ? <p className="hb-error">{errors.body}</p> : null}
      {kind === 'question' ? (
        <label className="hb-check">
          <input type="checkbox" checked={anonymous} onChange={(event) => setAnonymous(event.target.checked)} />
          <span>
            <span className="hb-label">Ask anonymously</span>
            <span className="hb-muted">Members see “Anonymous”. Moderators can see it was you, so it stays safe for everyone.</span>
          </span>
        </label>
      ) : null}
      {error ? <p className="hb-error" role="alert">{error}</p> : null}
      <div className="hb-inline">
        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Posting…' : kind === 'question' ? 'Ask' : 'Post'}
        </button>
        <button type="button" className="hb-link" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
    </form>
  );
}

function Threads({ hub, space, version, bump }) {
  const [filter, setFilter] = useState('all');
  const [items, setItems] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    hub
      .threads(space.spaceId, filter, controller.signal)
      .then((result) => setItems(result.items))
      .catch(() => !controller.signal.aborted && setItems([]));
    return () => controller.abort();
  }, [hub, space.spaceId, filter, version]);

  return (
    <>
      {space.me?.postingBlocked ? (
        space.me.role ? <p className="hb-note">{space.me.postingBlocked}</p> : null
      ) : (
        <NewThread hub={hub} space={space} onCreated={bump} />
      )}
      <div className="hb-toolbar">
        <div className="hb-segment" role="tablist" aria-label="Show">
          {[
            ['all', 'Everything'],
            ['questions', 'Questions'],
            ['unanswered', 'Open questions'],
          ].map(([value, label]) => (
            <button key={value} type="button" role="tab" aria-selected={filter === value} className={filter === value ? 'is-on' : ''} onClick={() => setFilter(value)}>
              {label}
            </button>
          ))}
        </div>
      </div>
      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? <p className="hb-muted">Nothing here yet. Be the first.</p> : null}
      <div className="hb-list">
        {(items ?? []).map((thread) => (
          <ThreadRow key={thread.threadId} thread={thread} />
        ))}
      </div>
    </>
  );
}

function Members({ hub, space, version, bump }) {
  const [members, setMembers] = useState(null);
  const moderator = space.me?.moderator;
  const owner = space.me?.role === 'owner';

  const load = useCallback(async () => {
    try {
      setMembers(await hub.members(space.spaceId));
    } catch {
      setMembers({ listVisible: false, count: 0, items: [] });
    }
  }, [hub, space.spaceId]);

  useEffect(() => {
    load();
  }, [load, version]);

  if (!members) return <p className="hb-muted">Loading…</p>;
  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
    bump();
  };

  return (
    <div>
      <p className="hb-muted">
        {members.count} {members.count === 1 ? 'member' : 'members'}.{' '}
        {members.listVisible ? 'Names and roles only — never email addresses or phone numbers.' : 'Only moderators see who else is here.'}
      </p>
      <ul className="hb-members">
        {members.items.map((member) => (
          <li key={member.userId} className="hb-member">
            <span className="hb-avatar" aria-hidden="true">
              {member.displayName.charAt(0).toUpperCase()}
            </span>
            <span className="hb-member__name">
              {member.displayName}
              {member.you ? ' (you)' : ''}
              {member.role !== 'member' ? <span className="hb-badge">{ROLE_LABEL[member.role]}</span> : null}
              {member.timeoutUntil && new Date(member.timeoutUntil) > new Date() ? <span className="hb-badge hb-badge--warn">Paused</span> : null}
            </span>
            {moderator && !member.you && member.role !== 'owner' ? (
              <span className="hb-member__actions">
                {owner ? (
                  <button type="button" className="hb-link" onClick={() => act(() => hub.updateMember(space.spaceId, member.userId, { role: member.role === 'moderator' ? 'member' : 'moderator' }))}>
                    {member.role === 'moderator' ? 'Make member' : 'Make moderator'}
                  </button>
                ) : null}
                <select
                  className="hb-input hb-input--small"
                  value=""
                  aria-label={`Pause ${member.displayName}`}
                  onChange={(event) => {
                    const minutes = Number(event.target.value);
                    if (minutes >= 0) act(() => hub.updateMember(space.spaceId, member.userId, { timeoutMinutes: minutes }));
                  }}
                >
                  <option value="" disabled>
                    Pause posting…
                  </option>
                  {TIMEOUTS.map((entry) => (
                    <option key={entry.minutes} value={entry.minutes}>
                      for {entry.label}
                    </option>
                  ))}
                  <option value="0">End the pause</option>
                </select>
                <button type="button" className="hb-link hb-link--danger" onClick={() => window.confirm(`Remove ${member.displayName} from the space?`) && act(() => hub.removeMember(space.spaceId, member.userId))}>
                  Remove
                </button>
              </span>
            ) : !member.you && space.me?.role ? (
              <ReportButton hub={hub} spaceId={space.spaceId} targetType="user" targetId={member.userId} />
            ) : null}
          </li>
        ))}
      </ul>
    </div>
  );
}

function Requests({ hub, space, bump }) {
  const [items, setItems] = useState(null);
  const load = useCallback(async () => {
    try {
      setItems((await hub.requests(space.spaceId)).items);
    } catch {
      setItems([]);
    }
  }, [hub, space.spaceId]);
  useEffect(() => {
    load();
  }, [load]);
  const decide = async (userId, approve) => {
    await hub.decide(space.spaceId, userId, approve).catch(() => undefined);
    await load();
    bump();
  };
  if (!items) return <p className="hb-muted">Loading…</p>;
  if (items.length === 0) return <p className="hb-muted">Nobody is waiting.</p>;
  return (
    <ul className="hb-members">
      {items.map((request) => (
        <li key={request.userId} className="hb-member hb-member--request">
          <span className="hb-avatar" aria-hidden="true">
            {request.displayName.charAt(0).toUpperCase()}
          </span>
          <span className="hb-member__name">
            {request.displayName}
            <span className="hb-muted">
              {request.answer ? `“${request.answer}”` : 'No note'}, {relativeTime(request.at)}
            </span>
          </span>
          <span className="hb-member__actions">
            <button type="button" className="btn btn--primary btn--tiny" onClick={() => decide(request.userId, true)}>
              Let in
            </button>
            <button type="button" className="btn btn--tiny" onClick={() => decide(request.userId, false)}>
              Decline
            </button>
          </span>
        </li>
      ))}
    </ul>
  );
}

function Reports({ hub, space }) {
  const [items, setItems] = useState(null);
  const load = useCallback(async () => {
    try {
      setItems((await hub.reports(space.spaceId)).items);
    } catch {
      setItems([]);
    }
  }, [hub, space.spaceId]);
  useEffect(() => {
    load();
  }, [load]);
  const resolve = async (reportId, action) => {
    await hub.resolveReport(space.spaceId, reportId, action).catch(() => undefined);
    await load();
  };
  if (!items) return <p className="hb-muted">Loading…</p>;
  if (items.length === 0) return <p className="hb-muted">No open reports.</p>;
  return (
    <ul className="hb-reports">
      {items.map((report) => (
        <li key={report.reportId} className="hb-reportcard">
          <p className="hb-label">
            {report.targetType === 'user' ? `Person: ${report.targetName ?? 'unknown'}` : report.threadTitle ?? 'A post'}
            <span className="hb-badge hb-badge--warn">{report.reason}</span>
          </p>
          {report.excerpt ? <p className="hb-muted">“{report.excerpt}”</p> : null}
          {report.note ? <p>{report.note}</p> : null}
          <div className="hb-inline">
            {report.threadId ? (
              <Link className="hb-link" to={`/community/threads/${report.threadId}`}>
                Open
              </Link>
            ) : null}
            <button type="button" className="btn btn--danger btn--tiny" onClick={() => resolve(report.reportId, 'remove')}>
              {report.targetType === 'user' ? 'Remove from space' : 'Remove'}
            </button>
            <button type="button" className="btn btn--tiny" onClick={() => resolve(report.reportId, 'dismiss')}>
              Dismiss
            </button>
          </div>
        </li>
      ))}
    </ul>
  );
}

function About({ hub, space, bump }) {
  const navigate = useNavigate();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState({ description: space.description ?? '', access: space.access, memberList: space.memberList, joinQuestion: space.joinQuestion ?? '' });
  const [error, setError] = useState(null);
  const moderator = space.me?.moderator;
  const access = ACCESS.find((entry) => entry.value === space.access);

  const save = async () => {
    setError(null);
    try {
      await hub.updateSpace(space.spaceId, {
        description: draft.description.trim() || null,
        access: draft.access,
        memberList: draft.memberList,
        joinQuestion: draft.access === 'request' ? draft.joinQuestion.trim() || null : null,
      });
      setEditing(false);
      bump();
    } catch (cause) {
      setError(cause?.detail ?? 'Not saved.');
    }
  };

  const leave = async () => {
    setError(null);
    try {
      await hub.leave(space.spaceId);
      bump();
      navigate('/community');
    } catch (cause) {
      setError(cause?.detail ?? 'You could not leave.');
    }
  };

  const archive = async () => {
    if (!window.confirm('Archive this space? It becomes read-only and leaves everyone’s list.')) return;
    await hub.archiveSpace(space.spaceId).catch(() => undefined);
    bump();
    navigate('/community');
  };

  return (
    <div className="hb-about">
      {editing ? (
        <div className="hb-form">
          <label className="hb-field">
            <span className="hb-label">Description</span>
            <textarea className="hb-input" rows={3} maxLength={500} value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} />
          </label>
          <label className="hb-field">
            <span className="hb-label">Who gets in</span>
            <select className="hb-input" value={draft.access} onChange={(event) => setDraft({ ...draft, access: event.target.value })}>
              {ACCESS.map((entry) => (
                <option key={entry.value} value={entry.value}>
                  {entry.label}: {entry.hint}
                </option>
              ))}
            </select>
          </label>
          {draft.access === 'request' ? (
            <label className="hb-field">
              <span className="hb-label">Question for people who ask to join</span>
              <input className="hb-input" maxLength={200} value={draft.joinQuestion} onChange={(event) => setDraft({ ...draft, joinQuestion: event.target.value })} />
            </label>
          ) : null}
          <label className="hb-check">
            <input type="checkbox" checked={draft.memberList === 'moderators'} onChange={(event) => setDraft({ ...draft, memberList: event.target.checked ? 'moderators' : 'members' })} />
            <span className="hb-label">Only moderators see who is in this space</span>
          </label>
          {error ? <p className="hb-error">{error}</p> : null}
          <div className="hb-inline">
            <button type="button" className="btn btn--primary" onClick={save}>
              Save
            </button>
            <button type="button" className="hb-link" onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <>
          <p>{space.description || <span className="hb-muted">No description yet.</span>}</p>
          <dl className="hb-facts">
            <div>
              <dt>Kind</dt>
              <dd>{KIND_LABEL[space.kind]}</dd>
            </div>
            <div>
              <dt>Who gets in</dt>
              <dd>{access?.label}: {access?.hint}</dd>
            </div>
            <div>
              <dt>Member list</dt>
              <dd>{space.memberList === 'moderators' ? 'Visible to moderators only' : 'Visible to members'}</dd>
            </div>
            {space.endsAt ? (
              <div>
                <dt>Ends</dt>
                <dd>{endsLabel(space.endsAt)}</dd>
              </div>
            ) : null}
          </dl>
          {error ? <p className="hb-error">{error}</p> : null}
          <div className="hb-inline">
            {moderator ? (
              <button type="button" className="btn" onClick={() => setEditing(true)}>
                Edit
              </button>
            ) : null}
            {space.me?.role ? (
              <button type="button" className="btn" onClick={leave}>
                Leave space
              </button>
            ) : null}
            {space.me?.role === 'owner' ? (
              <button type="button" className="btn btn--danger" onClick={archive}>
                Archive
              </button>
            ) : null}
          </div>
        </>
      )}
    </div>
  );
}

export default function SpaceView({ hub, spaceId, version, bump }) {
  const location = useLocation();
  const navigate = useNavigate();
  const [space, setSpace] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState('');

  useEffect(() => {
    const controller = new AbortController();
    hub
      .space(spaceId, controller.signal)
      .then((result) => {
        setSpace(result);
        setError(null);
      })
      .catch((cause) => !controller.signal.aborted && setError(cause?.detail ?? 'This space does not exist, or it is not shared with you.'));
    return () => controller.abort();
  }, [hub, spaceId, version]);

  if (error) return <p className="hb-error">{error}</p>;
  if (!space) return <p className="hb-muted">Loading…</p>;

  const moderator = space.me?.moderator;
  const member = Boolean(space.me?.role);
  const tabs = ['threads', 'members', 'about', ...(moderator ? ['requests', 'reports'] : [])];
  const tab = space.view === 'preview' ? 'about' : tabFrom(location.search, tabs, 'threads');
  const labels = { threads: 'Threads', members: 'Members', about: 'About', requests: 'Requests', reports: 'Reports' };
  const ends = endsLabel(space.endsAt);

  const join = async () => {
    setBusy(true);
    try {
      setSpace(await hub.join(space.spaceId, answer.trim() || null));
      bump();
    } catch (cause) {
      setError(cause?.detail ?? 'You could not join.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="hb-space">
      <header className="hb-space__head">
        <span className={`hb-mark hb-mark--${space.kind} hb-mark--huge`} aria-hidden="true">
          {spaceMark(space)}
        </span>
        <div className="hb-space__title">
          <h1>{space.name}</h1>
          <p className="hb-muted">
            {KIND_LABEL[space.kind]}, {space.memberCount} {space.memberCount === 1 ? 'member' : 'members'}
            {space.openQuestions ? `, ${space.openQuestions} open ${space.openQuestions === 1 ? 'question' : 'questions'}` : ''}
            {ends ? `, ${ends.toLowerCase()}` : ''}
          </p>
        </div>
        <div className="hb-space__action">
          {member ? (
            <span className="hb-badge hb-badge--done">{moderator ? 'You moderate' : 'Member'}</span>
          ) : space.me?.request === 'pending' ? (
            <span className="hb-muted">Request sent</span>
          ) : space.access === 'open' || space.courseId ? (
            <button type="button" className="btn btn--primary" disabled={busy} onClick={join}>
              Join
            </button>
          ) : null}
        </div>
      </header>

      {!member && space.access === 'request' && space.me?.request !== 'pending' ? (
        <div className="hb-joinbox">
          <p className="hb-label">This space admits people by request.</p>
          {space.joinQuestion ? <p className="hb-muted">{space.joinQuestion}</p> : null}
          <div className="hb-inline">
            <input className="hb-input" maxLength={500} placeholder={space.joinQuestion ? 'Your answer' : 'A short note (optional)'} value={answer} onChange={(event) => setAnswer(event.target.value)} />
            <button type="button" className="btn btn--primary" disabled={busy} onClick={join}>
              Ask to join
            </button>
          </div>
        </div>
      ) : null}

      {space.view === 'full' ? (
        <nav className="hb-tabs" aria-label="In this space">
          {tabs.map((name) => (
            <button key={name} type="button" className={tab === name ? 'hb-tab is-on' : 'hb-tab'} aria-current={tab === name ? 'page' : undefined} onClick={() => navigate(`/community/spaces/${space.spaceId}${name === 'threads' ? '' : `?tab=${name}`}`)}>
              {labels[name]}
            </button>
          ))}
        </nav>
      ) : null}

      <div className="hb-panel" key={tab}>
        {tab === 'threads' ? <Threads hub={hub} space={space} version={version} bump={bump} /> : null}
        {tab === 'members' ? <Members hub={hub} space={space} version={version} bump={bump} /> : null}
        {tab === 'requests' ? <Requests hub={hub} space={space} bump={bump} /> : null}
        {tab === 'reports' ? <Reports hub={hub} space={space} /> : null}
        {tab === 'about' ? <About hub={hub} space={space} bump={bump} /> : null}
      </div>
    </div>
  );
}
