import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import HeroDemo from '../components/Landing/HeroDemo.jsx';
import RoomPlanner from '../components/Landing/RoomPlanner.jsx';
import '../components/Landing/landing.css';

/**
 * The public homepage  (Landing)
 *
 * What someone sees before they have an account: what the product is, what
 * is inside, a room planner to try, and the way in. Nothing here needs the
 * API — it renders instantly and works while the server is starting.
 *
 * Shown at "/" to anyone who is not signed in (AuthGate), and at /welcome to
 * everyone. Signed-in visitors get "Open Classroom" instead of the sign-up
 * buttons.
 */

function Brand() {
  return (
    <span className="lp-brand">
      <svg className="lp-brand__mark" viewBox="0 0 32 32" aria-hidden="true">
        <rect x="3" y="6" width="26" height="18" rx="4" />
        <path d="M11 29h10M16 24v5" />
        <circle cx="23" cy="11" r="2.4" />
      </svg>
      Classroom
    </span>
  );
}

function Scene({ id, title, text, points, children, flip = false }) {
  return (
    <section className={flip ? 'lp-scene is-flipped' : 'lp-scene'} aria-labelledby={`lp-${id}`}>
      <div className="lp-scene__text">
        <h3 id={`lp-${id}`} className="lp-scene__title">
          {title}
        </h3>
        <p className="lp-scene__lead">{text}</p>
        <ul className="lp-scene__points">
          {points.map((point) => (
            <li key={point}>{point}</li>
          ))}
        </ul>
      </div>
      <div className="lp-scene__art" aria-hidden="true">
        {children}
      </div>
    </section>
  );
}

export default function LandingPage() {
  const { status } = useCore();
  const signedIn = status === 'authenticated';

  useEffect(() => {
    const previous = document.title;
    document.title = 'Classroom: live lessons, courses and community';
    return () => {
      document.title = previous;
    };
  }, []);

  return (
    <div className="lp">
      <a className="lp-skip" href="#lp-main">
        Skip to content
      </a>
      <header className="lp-nav">
        <Link to={signedIn ? '/' : '/welcome'} className="lp-nav__home" aria-label="Classroom home">
          <Brand />
        </Link>
        <nav className="lp-nav__links" aria-label="On this page">
          <a href="#inside">What’s inside</a>
          <a href="#plan">Plan a room</a>
          <a href="#privacy">Privacy</a>
        </nav>
        <div className="lp-nav__actions">
          {signedIn ? (
            <Link className="lp-button lp-button--primary lp-button--small" to="/">
              Open Classroom
            </Link>
          ) : (
            <>
              <Link className="lp-link" to="/login">
                Sign in
              </Link>
              <Link className="lp-button lp-button--primary lp-button--small" to="/signup">
                Create account
              </Link>
            </>
          )}
        </div>
      </header>

      <main id="lp-main">
        <section className="lp-hero" aria-labelledby="lp-hero-title">
          <div className="lp-hero__text">
            <h1 id="lp-hero-title" className="lp-hero__title">
              Live lessons that start the moment you do.
            </h1>
            <p className="lp-hero__lead">
              Plan a room, share one link, and the doors open a few minutes before you begin. Video, chat, courses and
              your community come with it.
            </p>
            <div className="lp-hero__actions">
              {signedIn ? (
                <Link className="lp-button lp-button--primary" to="/">
                  Open Classroom
                </Link>
              ) : (
                <>
                  <Link className="lp-button lp-button--primary" to="/signup">
                    Create account
                  </Link>
                  <Link className="lp-button lp-button--ghost" to="/login">
                    Sign in
                  </Link>
                </>
              )}
            </div>
            <p className="lp-hero__note">Runs in the browser. Nothing to install for you or your class.</p>
          </div>
          <HeroDemo />
        </section>

        <section id="inside" className="lp-section" aria-labelledby="lp-inside-title">
          <h2 id="lp-inside-title" className="lp-section__title">
            Everything a class needs, in one place
          </h2>

          <Scene
            id="live"
            title="A room that feels like a room"
            text="Video and sound tuned for teaching, with the controls a teacher actually reaches for."
            points={[
              'Share your screen, mute the room, let people react without interrupting',
              'Your microphone, camera and noise settings follow you to every lesson',
              'A lesson chat on the side, with private messages when someone needs one',
            ]}
          >
            <div className="lp-art lp-art--live">
              <span className="lp-art__tile lp-art__tile--sky is-speaking" />
              <span className="lp-art__tile lp-art__tile--mint" />
              <span className="lp-art__tile lp-art__tile--sun" />
              <span className="lp-art__tile lp-art__tile--rose" />
              <span className="lp-art__bar">
                <i />
                <i />
                <i />
                <i className="is-red" />
              </span>
            </div>
          </Scene>

          <Scene
            flip
            id="rooms"
            title="Doors that open on time"
            text="Rooms have a start, an end and doors. People wait in a lobby with a countdown and a camera check, not in an empty call."
            points={[
              'Doors open 3 to 10 minutes early; you can prepare 30 minutes before',
              'Seats with a waiting list: a freed seat is held for the next person',
              'Let people in yourself, one by one or all at once',
            ]}
          >
            <div className="lp-art lp-art--lobby">
              <p className="lp-art__big">4:59</p>
              <p className="lp-art__small">Doors open in</p>
              <p className="lp-art__knock">
                <span>Jonas wants to join</span>
                <b>Admit</b>
              </p>
            </div>
          </Scene>

          <Scene
            id="courses"
            title="Courses between the lessons"
            text="Lessons, materials and progress in one course, so the live hour builds on what came before."
            points={['Lessons in order, with progress you can see', 'Media library for slides, videos and documents', 'Reminders a day and ten minutes before']}
          >
            <div className="lp-art lp-art--course">
              {['Fractions', 'Decimals', 'Percentages', 'Revision'].map((name, index) => (
                <p key={name} className={index < 2 ? 'lp-art__lesson is-done' : index === 2 ? 'lp-art__lesson is-now' : 'lp-art__lesson'}>
                  <span>{name}</span>
                </p>
              ))}
              <span className="lp-art__progress">
                <i style={{ width: '55%' }} />
              </span>
            </div>
          </Scene>

          <Scene
            flip
            id="community"
            title="A community that keeps going"
            text="Spaces and threads for everything that does not fit into a lesson, and messages for the rest."
            points={['Spaces for each class, course or group', 'Private and group messages with read receipts you can switch off', 'Quiet hours and focus during lessons: nothing pings mid-sentence']}
          >
            <div className="lp-art lp-art--chat">
              <p className="lp-art__msg">Does anyone have the notes from Tuesday?</p>
              <p className="lp-art__msg is-mine">Uploaded them to the space 📎</p>
              <p className="lp-art__seen">Seen</p>
            </div>
          </Scene>
        </section>

        <section id="plan" className="lp-section lp-section--board" aria-labelledby="lp-plan-title">
          <div className="lp-section__head">
            <h2 id="lp-plan-title" className="lp-section__title">
              Try planning a room
            </h2>
            <p className="lp-section__lead">
              Move the controls. This is how it works inside, down to the minute the doors open for your guests.
            </p>
          </div>
          <RoomPlanner signedIn={signedIn} />
        </section>

        <section id="privacy" className="lp-section" aria-labelledby="lp-privacy-title">
          <div className="lp-section__head">
            <h2 id="lp-privacy-title" className="lp-section__title">
              You decide who reaches you
            </h2>
            <p className="lp-section__lead">Settings in plain language, with a check-up that tells you where you stand.</p>
          </div>
          <dl className="lp-facts">
            <div>
              <dt>Private messages</dt>
              <dd>Choose who may write to you. A block works everywhere, for everyone.</dd>
            </div>
            <div>
              <dt>Two-step sign-in</dt>
              <dd>An authenticator app or a passkey on your phone or laptop.</dd>
            </div>
            <div>
              <dt>Every device in view</dt>
              <dd>See where you are signed in and sign any device out at once.</dd>
            </div>
            <div>
              <dt>Your data, your copy</dt>
              <dd>Download everything as one file, or delete your account with 14 days to change your mind.</dd>
            </div>
          </dl>
        </section>

        <section className="lp-final" aria-labelledby="lp-final-title">
          <h2 id="lp-final-title" className="lp-final__title">
            Your next lesson could start in ten minutes.
          </h2>
          {signedIn ? (
            <Link className="lp-button lp-button--primary" to="/rooms/new">
              Plan a room
            </Link>
          ) : (
            <div className="lp-hero__actions">
              <Link className="lp-button lp-button--primary" to="/signup">
                Create account
              </Link>
              <Link className="lp-button lp-button--ghost" to="/login">
                Sign in
              </Link>
            </div>
          )}
        </section>
      </main>

      <footer className="lp-footer">
        <Brand />
        <nav aria-label="Footer">
          <a href="#inside">What’s inside</a>
          <a href="#plan">Plan a room</a>
          <a href="#privacy">Privacy</a>
          {signedIn ? <Link to="/">Open Classroom</Link> : <Link to="/login">Sign in</Link>}
        </nav>
        <p className="lp-footer__small">© {new Date().getFullYear()} Classroom</p>
      </footer>
    </div>
  );
}
