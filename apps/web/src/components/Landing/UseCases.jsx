import { useLayoutEffect, useRef, useState } from 'react';

/**
 * Who it is for  (Landing)
 *
 * Tabs for four kinds of people, each with what changes for them. A
 * highlighter slides to the chosen tab and the content settles in.
 * Arrow keys move between tabs, as tabs should.
 */

const CASES = [
  {
    id: 'teachers',
    label: 'Teachers',
    title: 'Your lessons, without the admin around them',
    points: [
      'Plan a room once, repeat it weekly, and every date gets its own link',
      'Learners join muted and wait in a lobby until the doors open',
      'Your camera, microphone and sound settings follow you to every lesson',
      'Focus during lessons holds back messages; you get one summary afterwards',
    ],
  },
  {
    id: 'schools',
    label: 'Schools',
    title: 'One place for classes, staff and families',
    points: [
      'Courses, live lessons and community spaces for each class',
      'Clear rules for who may message whom, with blocks that work everywhere',
      'Two-step sign-in and passkeys for staff accounts',
      'Every sign-in and settings change visible to the account owner',
    ],
  },
  {
    id: 'tutors',
    label: 'Tutors and coaches',
    title: 'Small groups that start on time',
    points: [
      'Seat limits with a waiting list, so a full session is not a lost student',
      'Let people in yourself when privacy matters',
      'Share one link; guests see the time in their own time zone',
      'Private messages for the questions people do not ask in front of others',
    ],
  },
  {
    id: 'learners',
    label: 'Learners',
    title: 'Know where to be, and feel safe there',
    points: [
      'Reminders a day and ten minutes before, in the app, by email or push',
      'Quiet hours: nothing buzzes at night unless a lesson is about to start',
      'Decide who can message you, and see what others see of your profile',
      'Download your data, or delete your account, whenever you want',
    ],
  },
];

export default function UseCases() {
  const [active, setActive] = useState(0);
  const [mark, setMark] = useState(null);
  const listRef = useRef(null);
  const tabRefs = useRef([]);

  useLayoutEffect(() => {
    const tab = tabRefs.current[active];
    const list = listRef.current;
    if (!tab || !list) return;
    const a = list.getBoundingClientRect();
    const b = tab.getBoundingClientRect();
    setMark({ left: b.left - a.left, width: b.width });
  }, [active]);

  const onKeyDown = (event) => {
    const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
    if (!step) return;
    event.preventDefault();
    const next = (active + step + CASES.length) % CASES.length;
    setActive(next);
    tabRefs.current[next]?.focus();
  };

  const current = CASES[active];

  return (
    <div className="lp-cases">
      <div className="lp-cases__tabs" role="tablist" aria-label="Who it is for" ref={listRef} onKeyDown={onKeyDown}>
        {mark ? <span className="lp-cases__mark" style={{ transform: `translateX(${mark.left}px)`, width: mark.width }} aria-hidden="true" /> : null}
        {CASES.map((entry, index) => (
          <button
            key={entry.id}
            ref={(el) => {
              tabRefs.current[index] = el;
            }}
            type="button"
            role="tab"
            id={`lp-tab-${entry.id}`}
            aria-selected={index === active}
            aria-controls="lp-case-panel"
            tabIndex={index === active ? 0 : -1}
            className={index === active ? 'lp-cases__tab is-on' : 'lp-cases__tab'}
            onClick={() => setActive(index)}
          >
            {entry.label}
          </button>
        ))}
      </div>
      <div className="lp-cases__panel" id="lp-case-panel" role="tabpanel" aria-labelledby={`lp-tab-${current.id}`} key={current.id}>
        <h3 className="lp-cases__title">{current.title}</h3>
        <ul className="lp-cases__points">
          {current.points.map((point, index) => (
            <li key={point} style={{ '--i': index }}>
              {point}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
