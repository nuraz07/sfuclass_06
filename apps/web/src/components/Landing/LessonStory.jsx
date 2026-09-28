import { useEffect, useRef, useState } from 'react';
import { activeStep } from './landingModel.js';
import { prefersReducedMotion } from './motion.js';

/**
 * "A lesson, start to finish" — the homepage's second big moment  (Landing)
 *
 * The steps scroll past on the left; on the right one screen stays in place
 * and changes with them, the way a product page walks you through a device.
 * Each screen is a small drawing of the real one. On phones the screens sit
 * between the steps instead of beside them.
 */

export const STEPS = [
  {
    id: 'plan',
    title: 'Plan it in a minute',
    text: 'Name, time, how long, how many seats. Pick when the doors open — 3 to 10 minutes before the start — and whether you let people in yourself.',
  },
  {
    id: 'invite',
    title: 'Send one link',
    text: 'Invitations arrive in the app and by email, with reminders a day and ten minutes before. Everyone sees the time in their own time zone, and can add it to their calendar.',
  },
  {
    id: 'doors',
    title: 'The doors open on time',
    text: 'Early arrivals wait in a lobby with a countdown and a camera check. When the room is full, they join a waiting list and get the next free seat.',
  },
  {
    id: 'teach',
    title: 'Teach, and see who needs you',
    text: 'Share your screen, see who is speaking, notice a raised hand. Learners join muted if you want them to, and reactions never interrupt.',
  },
  {
    id: 'talk',
    title: 'Questions have a place',
    text: 'A chat beside the lesson, and a private message when someone needs one — with blocks and read receipts under each person’s own control.',
  },
  {
    id: 'after',
    title: 'The class continues after the call',
    text: 'The room closes on time. Courses, materials and the community space carry on, and the next lesson is one click to plan again.',
  },
];

function Screen({ id }) {
  switch (id) {
    case 'plan':
      return (
        <div className="lp-scr lp-scr--plan">
          <p className="lp-scr__label">New room</p>
          <p className="lp-scr__field">Maths revision</p>
          <div className="lp-scr__row">
            <span className="lp-scr__chip is-on">60 min</span>
            <span className="lp-scr__chip">90 min</span>
            <span className="lp-scr__chip">12 seats</span>
          </div>
          <p className="lp-scr__small">Doors open 5 minutes before the start</p>
          <span className="lp-scr__slider" aria-hidden="true">
            <i />
          </span>
          <span className="lp-scr__cta">Create room</span>
        </div>
      );
    case 'invite':
      return (
        <div className="lp-scr lp-scr--invite">
          <div className="lp-scr__card">
            <p className="lp-scr__small">You are invited</p>
            <p className="lp-scr__title">Maths revision</p>
            <p className="lp-scr__small">Thursday, 16:00–17:00</p>
            <div className="lp-scr__row">
              <span className="lp-scr__zone is-own">16:00 your time</span>
              <span className="lp-scr__zone">15:00 London</span>
              <span className="lp-scr__zone">10:00 New York</span>
            </div>
          </div>
          <p className="lp-scr__link">classroom.app/rooms/kqz-7hfd-2mx</p>
        </div>
      );
    case 'doors':
      return (
        <div className="lp-scr lp-scr--doors">
          <p className="lp-scr__small">Doors open in</p>
          <p className="lp-scr__count">2:47</p>
          <p className="lp-scr__knock">
            <span>Jonas wants to join</span>
            <b>Admit</b>
          </p>
          <p className="lp-scr__small">Waiting list: 2 people</p>
        </div>
      );
    case 'teach':
      return (
        <div className="lp-scr lp-scr--teach">
          <div className="lp-scr__slide">½ + ¼ = ¾</div>
          <div className="lp-scr__strip">
            <i className="is-sky is-speaking" />
            <i className="is-mint" />
            <i className="is-sun has-hand" />
            <i className="is-rose" />
          </div>
        </div>
      );
    case 'talk':
      return (
        <div className="lp-scr lp-scr--talk">
          <p className="lp-scr__msg">Why is it ¾ and not ⅔?</p>
          <p className="lp-scr__msg is-mine">Great question — look at the bars 👀</p>
          <p className="lp-scr__msg is-private">Private: can I stay 5 minutes after class?</p>
          <p className="lp-scr__seen">Seen</p>
        </div>
      );
    default:
      return (
        <div className="lp-scr lp-scr--after">
          {['Fractions', 'Decimals', 'Percentages'].map((name, index) => (
            <p key={name} className={index < 2 ? 'lp-scr__lesson is-done' : 'lp-scr__lesson is-now'}>
              {name}
            </p>
          ))}
          <p className="lp-scr__thread">
            <b>Year 7 maths space</b>
            Notes from today are up 📎
          </p>
        </div>
      );
  }
}

export default function LessonStory() {
  const [active, setActive] = useState(0);
  const stepRefs = useRef([]);

  useEffect(() => {
    let frame = 0;
    const measure = () => {
      frame = 0;
      const tops = stepRefs.current.map((el) => (el ? el.getBoundingClientRect().top : Infinity));
      setActive(activeStep(tops, window.innerHeight * 0.55));
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', schedule);
    };
  }, []);

  const still = prefersReducedMotion();

  return (
    <div className="lp-story">
      <ol className="lp-story__steps">
        {STEPS.map((step, index) => (
          <li
            key={step.id}
            ref={(el) => {
              stepRefs.current[index] = el;
            }}
            className={index === active ? 'lp-story__step is-active' : 'lp-story__step'}
          >
            <span className="lp-story__num" aria-hidden="true">
              {index + 1}
            </span>
            <h3 className="lp-story__title">{step.title}</h3>
            <p className="lp-story__text">{step.text}</p>
            {/* Phones: the screen sits right under its step. */}
            <div className="lp-story__inline" aria-hidden="true">
              <div className="lp-device">
                <Screen id={step.id} />
              </div>
            </div>
          </li>
        ))}
      </ol>

      <div className="lp-story__stage" aria-hidden="true">
        <div className="lp-device lp-device--sticky">
          {STEPS.map((step, index) => (
            <div
              key={step.id}
              className={`lp-device__screen${index === active ? ' is-active' : ''}${index < active ? ' is-past' : ''}${still ? ' is-still' : ''}`}
            >
              <Screen id={step.id} />
            </div>
          ))}
          <span className="lp-device__progress">
            <i style={{ transform: `scaleX(${(active + 1) / STEPS.length})` }} />
          </span>
        </div>
      </div>
    </div>
  );
}
