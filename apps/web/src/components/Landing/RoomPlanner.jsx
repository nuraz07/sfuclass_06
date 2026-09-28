import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { DOORS, LENGTHS, clock, exampleStart, guestTimes, plannerNext, timelineFor } from './landingModel.js';

/**
 * "Plan a room" — try it before signing up  (Landing)
 *
 * The same choices as the real room editor, answered instantly: when the
 * doors open, how long it runs, how many seats, who can come in. The
 * timeline, the invitation card and the times for guests elsewhere update as
 * you move the controls. Nothing is sent anywhere; "Create this room" takes
 * you through sign-up to the editor.
 */

const viewerZone = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
};

export default function RoomPlanner({ signedIn }) {
  const zone = useMemo(viewerZone, []);
  const locale = typeof navigator !== 'undefined' ? navigator.language : undefined;
  const start = useMemo(() => exampleStart(), []);

  const [title, setTitle] = useState('Maths revision');
  const [length, setLength] = useState(60);
  const [doors, setDoors] = useState(DOORS.default);
  const [seats, setSeats] = useState(12);
  const [access, setAccess] = useState('invited');
  const [approval, setApproval] = useState(false);

  const timeline = timelineFor({ start, lengthMinutes: length, doorsMinutes: doors });
  const guests = guestTimes({ time: timeline.startsAt, ownZone: zone, locale, count: 3 });
  const createHref = signedIn ? plannerNext : `/signup?next=${encodeURIComponent(plannerNext)}`;

  return (
    <div className="lp-planner">
      <form className="lp-planner__controls" onSubmit={(event) => event.preventDefault()} aria-label="Plan an example room">
        <label className="lp-field">
          <span className="lp-field__label">Name</span>
          <input className="lp-input" value={title} maxLength={60} onChange={(event) => setTitle(event.target.value)} />
        </label>

        <fieldset className="lp-field">
          <legend className="lp-field__label">Length</legend>
          <div className="lp-pills">
            {LENGTHS.map((minutes) => (
              <button
                key={minutes}
                type="button"
                className={length === minutes ? 'lp-pill is-on' : 'lp-pill'}
                aria-pressed={length === minutes}
                onClick={() => setLength(minutes)}
              >
                {minutes} min
              </button>
            ))}
          </div>
        </fieldset>

        <label className="lp-field">
          <span className="lp-field__label">
            Doors open <strong>{doors} minutes</strong> before the start
          </span>
          <input
            className="lp-range"
            type="range"
            min={DOORS.min}
            max={DOORS.max}
            value={doors}
            onChange={(event) => setDoors(Number(event.target.value))}
            aria-valuetext={`${doors} minutes`}
          />
          <span className="lp-range__scale" aria-hidden="true">
            <span>{DOORS.min}</span>
            <span>{DOORS.max} min</span>
          </span>
        </label>

        <div className="lp-field">
          <span className="lp-field__label" id="lp-seats">
            Seats
          </span>
          <div className="lp-stepper" role="group" aria-labelledby="lp-seats">
            <button type="button" onClick={() => setSeats((n) => Math.max(2, n - 1))} aria-label="One seat fewer">
              −
            </button>
            <output aria-live="polite">{seats}</output>
            <button type="button" onClick={() => setSeats((n) => Math.min(300, n + 1))} aria-label="One seat more">
              +
            </button>
          </div>
        </div>

        <fieldset className="lp-field">
          <legend className="lp-field__label">Who can come in</legend>
          <div className="lp-segment">
            <button type="button" className={access === 'invited' ? 'is-on' : ''} aria-pressed={access === 'invited'} onClick={() => setAccess('invited')}>
              People I invite
            </button>
            <button type="button" className={access === 'link' ? 'is-on' : ''} aria-pressed={access === 'link'} onClick={() => setAccess('link')}>
              Anyone with the link
            </button>
          </div>
          <label className="lp-check">
            <input type="checkbox" checked={approval} onChange={(event) => setApproval(event.target.checked)} />
            <span>I let people in myself</span>
          </label>
        </fieldset>
      </form>

      <div className="lp-planner__result" aria-live="polite">
        <div className="lp-timeline" role="img" aria-label={`Timeline: doors open at ${clock(timeline.doorsAt, zone, locale)}, starts at ${clock(timeline.startsAt, zone, locale)}, closes at ${clock(timeline.endsAt, zone, locale)}.`}>
          <div className="lp-timeline__track">
            <span
              className="lp-timeline__early"
              style={{ left: `${timeline.marks[1].position}%`, width: `${timeline.marks[2].position - timeline.marks[1].position}%` }}
            />
            <span className="lp-timeline__live" style={{ left: `${timeline.marks[2].position}%`, right: 0 }} />
            {timeline.marks.map((mark) => (
              <span key={mark.id} className={`lp-timeline__mark lp-timeline__mark--${mark.id}`} style={{ left: `${mark.position}%` }} />
            ))}
          </div>
          <ol className="lp-timeline__legend">
            {timeline.marks.map((mark) => (
              <li key={mark.id} className={`lp-legend lp-legend--${mark.id}`}>
                <span className="lp-legend__time">{clock(mark.time, zone, locale)}</span>
                <span className="lp-legend__label">{mark.label}</span>
              </li>
            ))}
          </ol>
        </div>

        <article className="lp-invite">
          <p className="lp-invite__from">You are invited</p>
          <h3 className="lp-invite__title">{title.trim() || 'Your room'}</h3>
          <p className="lp-invite__when">
            Today, {clock(timeline.startsAt, zone, locale)}–{clock(timeline.endsAt, zone, locale)}
          </p>
          <ul className="lp-invite__facts">
            <li>Doors open at {clock(timeline.doorsAt, zone, locale)}</li>
            <li>{seats} seats{seats <= 4 ? ', with a waiting list when full' : ''}</li>
            <li>{access === 'link' ? 'Anyone in your organisation with the link' : 'Only invited people'}</li>
            {approval ? <li>The host lets people in</li> : null}
          </ul>
          <div className="lp-invite__zones">
            {guests.map((guest) => (
              <span key={guest.zone} className={guest.own ? 'lp-zone is-own' : 'lp-zone'}>
                <strong>{guest.time}</strong>
                {guest.shift > 0 ? <sup>+1</sup> : guest.shift < 0 ? <sup>−1</sup> : null} {guest.own ? 'your time' : guest.city}
              </span>
            ))}
          </div>
        </article>

        <Link className="lp-button lp-button--primary" to={createHref}>
          Create this room
        </Link>
      </div>
    </div>
  );
}
