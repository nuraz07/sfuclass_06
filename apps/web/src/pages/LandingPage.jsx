import { useEffect, useRef } from 'react';
import { Link } from 'react-router-dom';
import { useCore } from '@classroom/core-client';

import SiteNav, { Brand } from '../components/Landing/SiteNav.jsx';
import HeroDemo from '../components/Landing/HeroDemo.jsx';
import LessonStory from '../components/Landing/LessonStory.jsx';
import RoomPlanner from '../components/Landing/RoomPlanner.jsx';
import UseCases from '../components/Landing/UseCases.jsx';
import Faq from '../components/Landing/Faq.jsx';
import ContactForm from '../components/Landing/ContactForm.jsx';
import Reveal from '../components/Landing/Reveal.jsx';
import { useScrollFrame } from '../components/Landing/motion.js';
import { enterProgress } from '../components/Landing/landingModel.js';
import '../components/Landing/landing.css';

/**
 * The public homepage  (Landing)
 *
 * What someone sees before they have an account: what Classroom is, why it
 * is different from a meeting link, how a lesson runs from plan to follow-up,
 * a room planner to try, who it is for, how it protects people, answers, and
 * a way to get in touch. Nothing here needs an account; only the contact form
 * talks to the server.
 *
 * Shown at "/" to anyone not signed in (AuthGate), and at /welcome to
 * everyone. Signed-in visitors get "Open Classroom" instead of sign-up.
 */

const FEATURES = [
  {
    id: 'live',
    size: 'wide',
    title: 'Live lessons',
    text: 'Video and sound tuned for teaching: screen sharing, reactions that never interrupt, raised hands, learners who join muted when you want them to.',
  },
  {
    id: 'rooms',
    size: 'tall',
    title: 'Rooms with doors',
    text: 'A start, an end and a lobby. The doors open 3 to 10 minutes early, with a countdown and a camera check.',
  },
  {
    id: 'waitlist',
    title: 'Seats and a waiting list',
    text: 'When a room is full, the next person gets the next free seat, held for them for two minutes.',
  },
  {
    id: 'courses',
    title: 'Courses',
    text: 'Lessons in order, materials in one place, progress you can see.',
  },
  {
    id: 'community',
    title: 'Community spaces',
    text: 'Threads for each class, course or group, for everything between lessons.',
  },
  {
    id: 'messages',
    size: 'wide',
    title: 'Messages that respect people',
    text: 'Private and group chats with read receipts each person controls, mutes that end when you want them to, and blocks that work everywhere.',
  },
  {
    id: 'calm',
    title: 'Quiet hours and focus',
    text: 'Nothing buzzes at night. During a lesson, messages wait and arrive as one summary.',
  },
  {
    id: 'zones',
    title: 'Every time zone',
    text: 'Invitations show each guest their own time, and add the lesson to any calendar.',
  },
];

function FeatureArt({ id }) {
  switch (id) {
    case 'live':
      return (
        <div className="lp-fa lp-fa--live">
          <i className="is-sky is-speaking" />
          <i className="is-mint" />
          <i className="is-sun" />
          <i className="is-rose" />
          <span className="lp-fa__float">👏</span>
        </div>
      );
    case 'rooms':
      return (
        <div className="lp-fa lp-fa--doors">
          <span className="lp-fa__door lp-fa__door--l" />
          <span className="lp-fa__door lp-fa__door--r" />
          <span className="lp-fa__count">4:59</span>
        </div>
      );
    case 'waitlist':
      return (
        <div className="lp-fa lp-fa--queue">
          <span className="is-seat" />
          <span className="is-seat" />
          <span className="is-seat is-free" />
          <span className="is-wait" />
          <span className="is-wait" />
        </div>
      );
    case 'courses':
      return (
        <div className="lp-fa lp-fa--course">
          <span style={{ '--w': '100%' }} />
          <span style={{ '--w': '100%' }} />
          <span style={{ '--w': '45%' }} />
        </div>
      );
    case 'community':
      return (
        <div className="lp-fa lp-fa--thread">
          <span />
          <span className="is-reply" />
          <span className="is-reply" />
        </div>
      );
    case 'messages':
      return (
        <div className="lp-fa lp-fa--chat">
          <span className="lp-fa__bubble">Can we go over question 3?</span>
          <span className="lp-fa__bubble is-mine">Of course, after class 👍</span>
          <span className="lp-fa__seen">Seen</span>
        </div>
      );
    case 'calm':
      return (
        <div className="lp-fa lp-fa--moon">
          <span className="lp-fa__moon" />
          <span className="lp-fa__z">22:00 – 07:00</span>
        </div>
      );
    default:
      return (
        <div className="lp-fa lp-fa--zones">
          <span>16:00 Berlin</span>
          <span>15:00 London</span>
          <span>10:00 New York</span>
        </div>
      );
  }
}

const COMPARISON = [
  ['Opens when you decide', 'Doors open 3 to 10 minutes before the start; a lobby with countdown until then', 'Open from the moment the link exists'],
  ['Ends on time', 'Closes at the end, with a five-minute notice and "+10 min" for the host', 'Runs until someone leaves last'],
  ['A full room', 'A waiting list, and the next free seat held for the next person', 'Whoever clicks first'],
  ['Letting people in', 'Invited only, or anyone with the link, plus a knock-and-admit lobby', 'Usually the link is the only key'],
  ['Before and after the lesson', 'Courses, materials, community spaces and messages in the same place', 'Somewhere else, in another tool'],
  ['Quiet evenings', 'Quiet hours and focus during lessons for every notification', 'Every ping, every time'],
];

const SECURITY = [
  ['Two-step sign-in', 'An authenticator app, recovery codes, or a passkey — fingerprint, face or PIN instead of a password.'],
  ['Every device in view', 'See where you are signed in and sign any device out at once; it stops immediately.'],
  ['A history you can read', 'Sign-ins, failed attempts and settings changes, with the device they came from.'],
  ['Who may reach you', 'Anyone, only people you share a class with, or nobody. Blocks work everywhere.'],
  ['What others see', 'Choose who sees your profile, your online status and your read receipts — and preview it.'],
  ['Your data, your copy', 'Download everything as one file. Delete your account, with 14 days to change your mind.'],
];

/** The hero demo settles from a slight tilt as it scrolls toward the middle of the screen. */
function TiltOnScroll({ children }) {
  const ref = useRef(null);
  useScrollFrame(ref, (rect, viewport) => {
    const progress = enterProgress({ top: rect.top + viewport * 0.35, height: rect.height, viewport });
    ref.current.style.setProperty('--lp-tilt', String(1 - progress));
  });
  return (
    <div className="lp-tilt" ref={ref}>
      {children}
    </div>
  );
}

export default function LandingPage() {
  const { status } = useCore();
  const signedIn = status === 'authenticated';

  useEffect(() => {
    const previous = document.title;
    document.title = 'Classroom: live lessons, courses and community';
    document.documentElement.classList.add('lp-root');
    return () => {
      document.title = previous;
      document.documentElement.classList.remove('lp-root');
    };
  }, []);

  const primary = signedIn ? (
    <Link className="lp-button lp-button--primary" to="/">
      Open Classroom
    </Link>
  ) : (
    <Link className="lp-button lp-button--primary" to="/signup">
      Create account
    </Link>
  );

  return (
    <div className="lp">
      <a className="lp-skip" href="#lp-main">
        Skip to content
      </a>
      <SiteNav signedIn={signedIn} />

      <main id="lp-main">
        {/* ------------------------------------------------ hero */}
        <section className="lp-hero" aria-labelledby="lp-hero-title">
          <div className="lp-hero__text">
            <h1 id="lp-hero-title" className="lp-hero__title">
              {['Live lessons', 'that start', 'the moment', 'you do.'].map((line, index) => (
                <span key={line} className="lp-line" style={{ '--i': index }}>
                  <span>{line}</span>
                </span>
              ))}
            </h1>
            <p className="lp-hero__lead lp-enter" style={{ '--i': 4 }}>
              Plan a room, share one link, and the doors open a few minutes before you begin. Video, chat, courses and
              your community come with it — calm, private and on time.
            </p>
            <div className="lp-hero__actions lp-enter" style={{ '--i': 5 }}>
              {primary}
              {signedIn ? null : (
                <Link className="lp-button lp-button--ghost" to="/login">
                  Sign in
                </Link>
              )}
              <a className="lp-button lp-button--text" href="#how">
                See how a lesson runs
              </a>
            </div>
            <ul className="lp-hero__assurances lp-enter" style={{ '--i': 6 }}>
              <li>Runs in the browser</li>
              <li>Nothing to install for your class</li>
              <li>Two-step sign-in and passkeys</li>
            </ul>
          </div>
          <div className="lp-hero__demo lp-enter" style={{ '--i': 2 }}>
            <TiltOnScroll>
              <HeroDemo />
            </TiltOnScroll>
          </div>
        </section>

        <Reveal as="section" className="lp-for" aria-label="Who uses Classroom">
          <p className="lp-for__lead">Made for</p>
          <ul className="lp-for__list">
            {['Teachers', 'Schools', 'Universities', 'Tutors', 'Coaches', 'Study groups', 'Communities'].map((who) => (
              <li key={who}>{who}</li>
            ))}
          </ul>
        </Reveal>

        {/* ------------------------------------------------ features */}
        <section id="features" className="lp-section" aria-labelledby="lp-features-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-features-title" className="lp-section__title">
              Everything a class needs, in one calm place
            </h2>
            <p className="lp-section__lead">
              Not another meeting tool with a school sticker on it. Classroom is built around how lessons actually work:
              they start at a time, have a room, a group and a follow-up.
            </p>
          </Reveal>
          <div className="lp-bento">
            {FEATURES.map((feature, index) => (
              <Reveal as="article" key={feature.id} delay={(index % 4) * 90} className={`lp-bento__item lp-bento__item--${feature.size ?? 'std'} lp-bento__item--${feature.id}`}>
                <FeatureArt id={feature.id} />
                <h3 className="lp-bento__title">{feature.title}</h3>
                <p className="lp-bento__text">{feature.text}</p>
              </Reveal>
            ))}
          </div>
        </section>

        {/* ------------------------------------------------ why */}
        <section className="lp-section lp-section--tint" aria-labelledby="lp-why-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-why-title" className="lp-section__title">
              Why teach here instead of a meeting link
            </h2>
            <p className="lp-section__lead">A meeting link is a door with no building behind it. Here is what changes.</p>
          </Reveal>
          <Reveal className="lp-compare" role="table" aria-label="Classroom compared with a typical meeting link">
            <div className="lp-compare__row lp-compare__head" role="row">
              <span role="columnheader" />
              <span role="columnheader">Classroom</span>
              <span role="columnheader">A typical meeting link</span>
            </div>
            {COMPARISON.map(([topic, ours, theirs], index) => (
              <div key={topic} className="lp-compare__row" role="row" style={{ '--i': index }}>
                <span role="rowheader" className="lp-compare__topic">
                  {topic}
                </span>
                <span role="cell" className="lp-compare__ours">
                  {ours}
                </span>
                <span role="cell" className="lp-compare__theirs">
                  {theirs}
                </span>
              </div>
            ))}
          </Reveal>
        </section>

        {/* ------------------------------------------------ how */}
        <section id="how" className="lp-section" aria-labelledby="lp-how-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-how-title" className="lp-section__title">
              A lesson, from plan to follow-up
            </h2>
            <p className="lp-section__lead">Scroll through one lesson the way it really happens.</p>
          </Reveal>
          <LessonStory />
        </section>

        {/* ------------------------------------------------ rooms */}
        <section id="rooms" className="lp-section lp-section--tint" aria-labelledby="lp-rooms-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-rooms-title" className="lp-section__title">
              Try planning a room
            </h2>
            <p className="lp-section__lead">
              Move the controls. This is how it works inside, down to the minute the doors open for your guests — in
              their own time zone.
            </p>
          </Reveal>
          <Reveal>
            <RoomPlanner signedIn={signedIn} />
          </Reveal>
        </section>

        {/* ------------------------------------------------ teams */}
        <section id="teams" className="lp-section" aria-labelledby="lp-teams-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-teams-title" className="lp-section__title">
              For schools, and everyone in them
            </h2>
            <p className="lp-section__lead">The same place feels right for the person teaching, the one learning, and the school around them.</p>
          </Reveal>
          <Reveal>
            <UseCases />
          </Reveal>
        </section>

        {/* ------------------------------------------------ security */}
        <section id="security" className="lp-section lp-section--tint" aria-labelledby="lp-security-title">
          <div className="lp-split">
            <Reveal className="lp-section__head lp-split__head">
              <h2 id="lp-security-title" className="lp-section__title">
                A safe space, by design
              </h2>
              <p className="lp-section__lead">
                Privacy settings in plain language, a check-up that tells you where you stand, and protection you can see
                working.
              </p>
              <div className="lp-checkup" aria-hidden="true">
                <p className="lp-checkup__title">Privacy check-up</p>
                <p className="lp-checkup__line is-ok">People you share a class with can message you</p>
                <p className="lp-checkup__line is-ok">Two-step sign-in is on</p>
                <p className="lp-checkup__line is-ok">Signed in on 2 devices</p>
                <p className="lp-checkup__line is-ok">You have blocked nobody</p>
              </div>
            </Reveal>
            <dl className="lp-facts">
              {SECURITY.map(([title, text], index) => (
                <Reveal key={title} delay={(index % 2) * 90}>
                  <dt>{title}</dt>
                  <dd>{text}</dd>
                </Reveal>
              ))}
            </dl>
          </div>
        </section>

        {/* ------------------------------------------------ faq */}
        <section id="faq" className="lp-section" aria-labelledby="lp-faq-title">
          <div className="lp-split">
            <Reveal className="lp-section__head lp-split__head">
              <h2 id="lp-faq-title" className="lp-section__title">
                Questions, answered
              </h2>
              <p className="lp-section__lead">
                Something missing? <a href="#contact">Write to us</a>.
              </p>
            </Reveal>
            <Reveal>
              <Faq />
            </Reveal>
          </div>
        </section>

        {/* ------------------------------------------------ contact */}
        <section id="contact" className="lp-section lp-section--tint" aria-labelledby="lp-contact-title">
          <div className="lp-split">
            <Reveal className="lp-section__head lp-split__head">
              <h2 id="lp-contact-title" className="lp-section__title">
                Talk to us
              </h2>
              <p className="lp-section__lead">
                Bringing Classroom to a school or team, a question before you start, or help with your account — write,
                and a person answers.
              </p>
              <ul className="lp-contact__notes">
                <li>For schools: we help you set up classes and accounts.</li>
                <li>For privacy questions: tell us what you want to know or have removed.</li>
                <li>Already have an account? Sign in first, then write, so we can find it.</li>
              </ul>
            </Reveal>
            <Reveal className="lp-contact">
              <ContactForm />
            </Reveal>
          </div>
        </section>

        {/* ------------------------------------------------ final */}
        <Reveal as="section" className="lp-final" aria-labelledby="lp-final-title">
          <h2 id="lp-final-title" className="lp-final__title">
            Your next lesson could start in ten minutes.
          </h2>
          <p className="lp-final__lead">Create an account, plan a room, send the link.</p>
          <div className="lp-hero__actions">
            {signedIn ? (
              <Link className="lp-button lp-button--primary" to="/rooms/new">
                Plan a room
              </Link>
            ) : (
              <>
                {primary}
                <Link className="lp-button lp-button--ghost" to="/login">
                  Sign in
                </Link>
              </>
            )}
          </div>
        </Reveal>
      </main>

      <footer className="lp-footer">
        <div className="lp-footer__brand">
          <Brand />
          <p>Live lessons, courses and community, in one calm place.</p>
        </div>
        <nav className="lp-footer__cols" aria-label="Footer">
          <div>
            <p className="lp-footer__head">Product</p>
            <a href="#features">Features</a>
            <a href="#how">How it works</a>
            <a href="#rooms">Rooms</a>
          </div>
          <div>
            <p className="lp-footer__head">For</p>
            <a href="#teams">Teachers</a>
            <a href="#teams">Schools</a>
            <a href="#teams">Tutors and coaches</a>
          </div>
          <div>
            <p className="lp-footer__head">Trust</p>
            <a href="#security">Security</a>
            <a href="#security">Privacy</a>
            <a href="#faq">FAQ</a>
          </div>
          <div>
            <p className="lp-footer__head">Get in touch</p>
            <a href="#contact">Contact</a>
            {signedIn ? <Link to="/">Open Classroom</Link> : <Link to="/login">Sign in</Link>}
            {signedIn ? null : <Link to="/signup">Create account</Link>}
          </div>
        </nav>
        <p className="lp-footer__small">© {new Date().getFullYear()} Classroom</p>
      </footer>
    </div>
  );
}
