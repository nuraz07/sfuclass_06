import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { DAYS, PARTS, parseSubjects, toggleSlot } from './hubModel.js';
import { relativeTime } from '../Settings/notificationsModel.js';

/**
 * Study partners  (Community, part 3)
 *
 * Opt in with what you study and when you are free. Suggestions come from
 * others who opted in, with the reasons in words; nothing more is shown.
 * Ask, and the other person decides. Partners can open a room for the two of
 * them with one click. Turning the profile off removes you from everyone's
 * suggestions at once.
 */
function ProfileEditor({ hub, profile, onSaved }) {
  const [active, setActive] = useState(profile.exists ? profile.active : true);
  const [subjects, setSubjects] = useState(profile.subjects.join(', '));
  const [slots, setSlots] = useState(profile.availability);
  const [note, setNote] = useState(profile.note ?? '');
  const [state, setState] = useState('idle');

  const save = async () => {
    setState('saving');
    try {
      onSaved(await hub.saveStudyProfile({ active, subjects: parseSubjects(subjects), availability: slots, note: note.trim() || null }));
      setState('saved');
    } catch {
      setState('error');
    }
  };

  return (
    <section className="hb-fieldset hb-profile">
      <legend>Your study profile</legend>
      <label className="hb-check">
        <input type="checkbox" checked={active} onChange={(event) => setActive(event.target.checked)} />
        <span>
          <span className="hb-label">Find me study partners</span>
          <span className="hb-muted">Others who opted in see your name, your note and what you have in common. Never your email.</span>
        </span>
      </label>
      <label className="hb-field">
        <span className="hb-label">What you study</span>
        <input className="hb-input" value={subjects} placeholder="maths, physics, spanish" onChange={(event) => setSubjects(event.target.value)} />
      </label>
      <div className="hb-field">
        <span className="hb-label" id="hb-times">When you are free</span>
        <div className="hb-slots" role="group" aria-labelledby="hb-times">
          <span />
          {DAYS.map((day) => (
            <span key={day.value} className="hb-slots__head">
              {day.label}
            </span>
          ))}
          {PARTS.map((part) => [
            <span key={part.value} className="hb-slots__row">
              {part.label}
            </span>,
            ...DAYS.map((day) => {
              const slot = `${day.value}-${part.value}`;
              const on = slots.includes(slot);
              return (
                <button
                  key={slot}
                  type="button"
                  className={on ? 'hb-slot is-on' : 'hb-slot'}
                  aria-pressed={on}
                  aria-label={`${day.label} ${part.label}`}
                  onClick={() => setSlots((current) => toggleSlot(current, slot))}
                />
              );
            }),
          ])}
        </div>
      </div>
      <label className="hb-field">
        <span className="hb-label">A short note (optional)</span>
        <input className="hb-input" maxLength={200} value={note} placeholder="e.g. Preparing for the June exam, happy to explain algebra" onChange={(event) => setNote(event.target.value)} />
      </label>
      <div className="hb-inline">
        <button type="button" className="btn btn--primary" disabled={state === 'saving'} onClick={save}>
          Save
        </button>
        {state === 'saved' ? <span className="hb-muted">Saved.</span> : null}
        {state === 'error' ? <span className="hb-error">Not saved.</span> : null}
      </div>
    </section>
  );
}

export default function HubPartners({ hub }) {
  const navigate = useNavigate();
  const [profile, setProfile] = useState(null);
  const [suggestions, setSuggestions] = useState(null);
  const [page, setPage] = useState(null);
  const [asking, setAsking] = useState(null);
  const [message, setMessage] = useState('');
  const [error, setError] = useState(null);
  const [editing, setEditing] = useState(false);

  const load = useCallback(async () => {
    const [p, s, r] = await Promise.all([
      hub.studyProfile().catch(() => null),
      hub.studySuggestions().catch(() => ({ items: [], needsProfile: true })),
      hub.partners().catch(() => ({ partners: [], incoming: [], outgoing: [] })),
    ]);
    setProfile(p);
    setSuggestions(s);
    setPage(r);
  }, [hub]);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (fn) => {
    setError(null);
    try {
      return await fn();
    } catch (cause) {
      setError(cause?.detail ?? 'That did not work.');
      return null;
    } finally {
      await load();
    }
  };

  if (!profile || !page || !suggestions) return <p className="hb-muted">Loading…</p>;
  const showEditor = editing || !profile.exists;

  return (
    <div className="hb-partners">
      <header className="hb-head">
        <h1>Study partners</h1>
        <p className="hb-muted">Find people who study what you study, when you are free. Nothing is shared until both of you agree.</p>
      </header>
      {error ? <p className="hb-error" role="alert">{error}</p> : null}

      {page.incoming.length ? (
        <section className="hb-block">
          <h2 className="hb-block__title">Asking you</h2>
          <ul className="hb-members">
            {page.incoming.map((request) => (
              <li key={request.userId} className="hb-member hb-member--request">
                <span className="hb-avatar" aria-hidden="true">{request.displayName.charAt(0).toUpperCase()}</span>
                <span className="hb-member__name">
                  {request.displayName}
                  <span className="hb-muted">{request.message ? `“${request.message}”` : 'No note'}, {relativeTime(request.at)}</span>
                </span>
                <span className="hb-member__actions">
                  <button type="button" className="btn btn--primary btn--tiny" onClick={() => act(() => hub.respondPartner(request.userId, true))}>
                    Study together
                  </button>
                  <button type="button" className="btn btn--tiny" onClick={() => act(() => hub.respondPartner(request.userId, false))}>
                    Not now
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {page.partners.length ? (
        <section className="hb-block">
          <h2 className="hb-block__title">Your study partners</h2>
          <ul className="hb-members">
            {page.partners.map((partner) => (
              <li key={partner.userId} className="hb-member">
                <span className="hb-avatar hb-avatar--partner" aria-hidden="true">{partner.displayName.charAt(0).toUpperCase()}</span>
                <span className="hb-member__name">
                  {partner.displayName}
                  <span className="hb-muted">{partner.sharedTimes.length ? `Both free ${partner.sharedTimes.slice(0, 2).join(' and ')}` : 'No shared free time yet'}</span>
                </span>
                <span className="hb-member__actions">
                  <button
                    type="button"
                    className="btn btn--primary btn--tiny"
                    onClick={async () => {
                      const result = await act(() => hub.studyNow(partner.userId));
                      if (result?.code) navigate(`/rooms/${result.code}/lobby`);
                    }}
                  >
                    Study together now
                  </button>
                  <button type="button" className="hb-link hb-link--quiet" onClick={() => window.confirm(`End the study partnership with ${partner.displayName}?`) && act(() => hub.endPartner(partner.userId))}>
                    End
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {showEditor ? (
        <ProfileEditor
          hub={hub}
          profile={profile}
          onSaved={(saved) => {
            setProfile(saved);
            setEditing(false);
            load();
          }}
        />
      ) : (
        <p className="hb-inline hb-profile-line">
          <span className={profile.active ? 'hb-badge hb-badge--done' : 'hb-badge'}>{profile.active ? 'Looking for partners' : 'Not looking'}</span>
          <span className="hb-muted">{profile.subjects.length ? profile.subjects.join(', ') : 'No subjects yet'}</span>
          <button type="button" className="hb-link" onClick={() => setEditing(true)}>
            Edit profile
          </button>
        </p>
      )}

      {profile.exists && profile.active ? (
        <section className="hb-block">
          <h2 className="hb-block__title">Suggestions</h2>
          {suggestions.items.length === 0 ? (
            <p className="hb-muted">Nobody with something in common yet. Add subjects and free times, or join a few spaces.</p>
          ) : (
            <div className="hb-cards">
              {suggestions.items.map((person) => (
                <article key={person.userId} className="hb-card hb-suggestion">
                  <div className="hb-card__top">
                    <span className="hb-avatar hb-avatar--big" aria-hidden="true">{person.displayName.charAt(0).toUpperCase()}</span>
                    <p className="hb-card__name">{person.displayName}</p>
                  </div>
                  <ul className="hb-reasons">
                    {person.reasons.map((reason) => (
                      <li key={reason}>{reason}</li>
                    ))}
                  </ul>
                  {person.note ? <p className="hb-card__text">“{person.note}”</p> : null}
                  <div className="hb-card__foot">
                    {asking === person.userId ? (
                      <div className="hb-ask">
                        <input className="hb-input" maxLength={300} placeholder="A short note (optional)" value={message} onChange={(event) => setMessage(event.target.value)} />
                        <div className="hb-inline">
                          <button
                            type="button"
                            className="btn btn--primary"
                            onClick={async () => {
                              await act(() => hub.requestPartner(person.userId, message.trim() || null));
                              setAsking(null);
                              setMessage('');
                            }}
                          >
                            Send
                          </button>
                          <button type="button" className="hb-link" onClick={() => setAsking(null)}>
                            Cancel
                          </button>
                        </div>
                      </div>
                    ) : (
                      <button type="button" className="btn" onClick={() => setAsking(person.userId)}>
                        Ask to study together
                      </button>
                    )}
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      ) : null}

      {page.outgoing.length ? (
        <p className="hb-muted hb-outgoing">
          Asked: {page.outgoing.map((request) => request.displayName).join(', ')}. They decide when they are ready.
        </p>
      ) : null}
    </div>
  );
}
