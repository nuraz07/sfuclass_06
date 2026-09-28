import { useEffect, useRef, useState } from 'react';
import { mmss } from './landingModel.js';
import { prefersReducedMotion } from './motion.js';

/**
 * The homepage's moving picture  (Landing)
 *
 * A miniature of a real lesson, about 22 seconds long:
 *
 *   lobby      the doors count down while three people wait
 *   doors      the doors open
 *   arrivals   four people come in, one after another
 *   teaching   the host speaks
 *   sharing    the host shares slides; the others move to a strip
 *   hand       a learner raises a hand, a question arrives in the chat
 *   reaction   applause floats up
 *   closing    "5 minutes left" with the host's "+10 min"
 *
 * Drawn with HTML and CSS — sharp at every size, nothing to download. Plays
 * only while on screen and while the tab is visible; anyone who prefers
 * reduced motion sees the finished lesson as a still.
 */

const PEOPLE = [
  { name: 'Ms Okafor', initial: 'O', hue: 'sky', host: true },
  { name: 'Jonas', initial: 'J', hue: 'mint' },
  { name: 'Amira', initial: 'A', hue: 'sun' },
  { name: 'Lea', initial: 'L', hue: 'rose' },
];

const SCRIPT = [
  { at: 0, scene: 'lobby' },
  { at: 3800, scene: 'doors' },
  { at: 4800, scene: 'room', joined: 1 },
  { at: 5300, scene: 'room', joined: 2 },
  { at: 5800, scene: 'room', joined: 3 },
  { at: 6300, scene: 'room', joined: 4, speaking: 0 },
  { at: 8200, scene: 'share', joined: 4, speaking: 0, slide: 1 },
  { at: 10400, scene: 'share', joined: 4, speaking: 0, slide: 2 },
  { at: 12400, scene: 'share', joined: 4, speaking: 0, slide: 2, hand: 2 },
  { at: 13600, scene: 'share', joined: 4, speaking: 2, slide: 2, hand: 2, chat: true },
  { at: 15600, scene: 'room', joined: 4, speaking: 2, chat: true, reaction: true },
  { at: 17800, scene: 'room', joined: 4, speaking: 0, chat: true, ending: true },
];
const LOOP_MS = 22000;
const LOBBY_MS = 3800;
const STILL = { scene: 'share', joined: 4, speaking: 0, slide: 2, hand: 2, chat: true };

function Figure() {
  return (
    <div className="lp-tile__figure" aria-hidden="true">
      <span className="lp-tile__head" />
      <span className="lp-tile__body" />
    </div>
  );
}

function Tile({ person, index, speaking, hand, small = false }) {
  return (
    <div
      className={`lp-tile lp-tile--${person.hue}${speaking ? ' is-speaking' : ''}${small ? ' is-small' : ''}`}
      style={{ '--i': index }}
    >
      <Figure />
      {hand ? (
        <span className="lp-tile__hand" aria-hidden="true">
          ✋
        </span>
      ) : null}
      <span className="lp-tile__name">
        {small ? person.name.split(' ').pop() : person.name}
        {person.host && !small ? <span className="lp-tile__role">host</span> : null}
      </span>
    </div>
  );
}

function Slide({ slide }) {
  return (
    <div className="lp-slide" key={slide}>
      {slide === 1 ? (
        <>
          <p className="lp-slide__kicker">Fractions</p>
          <p className="lp-slide__big">½ + ¼ = ?</p>
          <div className="lp-slide__bars" aria-hidden="true">
            <span style={{ width: '50%' }} />
            <span style={{ width: '25%' }} />
          </div>
        </>
      ) : (
        <>
          <p className="lp-slide__kicker">Fractions</p>
          <p className="lp-slide__big">½ + ¼ = ¾</p>
          <div className="lp-slide__bars is-done" aria-hidden="true">
            <span style={{ width: '75%' }} />
          </div>
        </>
      )}
    </div>
  );
}

export default function HeroDemo() {
  const reduced = useRef(prefersReducedMotion());
  const [state, setState] = useState(() => (reduced.current ? STILL : SCRIPT[0]));
  const [countdown, setCountdown] = useState(LOBBY_MS);
  const rootRef = useRef(null);

  useEffect(() => {
    if (reduced.current) return undefined;
    let timers = [];
    let tick = 0;
    let visible = true;
    let running = false;

    const stop = () => {
      timers.forEach((timer) => window.clearTimeout(timer));
      timers = [];
      window.clearInterval(tick);
      running = false;
    };

    const play = () => {
      if (running || !visible || document.hidden) return;
      running = true;
      const began = performance.now();
      setState(SCRIPT[0]);
      SCRIPT.forEach((step) => timers.push(window.setTimeout(() => setState(step), step.at)));
      tick = window.setInterval(() => setCountdown(Math.max(0, LOBBY_MS - (performance.now() - began))), 200);
      timers.push(
        window.setTimeout(() => {
          stop();
          setCountdown(LOBBY_MS);
          play();
        }, LOOP_MS),
      );
    };

    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        if (visible) play();
        else stop();
      },
      { threshold: 0.2 },
    );
    if (rootRef.current) observer.observe(rootRef.current);
    const onVisibility = () => (document.hidden ? stop() : play());
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      stop();
      observer.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, []);

  const inRoom = state.scene === 'room' || state.scene === 'share';
  const joined = state.joined ?? 0;
  const people = PEOPLE.slice(0, joined);

  return (
    <figure
      className="lp-demo"
      ref={rootRef}
      aria-label="A lesson: the doors open, four people join, the teacher shares slides, a learner asks a question."
    >
      <div className="lp-demo__window">
        <div className="lp-demo__bar">
          <span className="lp-demo__dots" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <span className="lp-demo__title">Maths revision</span>
          {inRoom ? (
            <span className={state.ending ? 'lp-demo__clock is-warn' : 'lp-demo__clock'}>
              {state.ending ? 'Closes in 5 min' : 'Live'}
            </span>
          ) : (
            <span className="lp-demo__clock is-quiet">Lobby</span>
          )}
        </div>

        <div className={`lp-demo__stage lp-demo__stage--${state.scene}`}>
          {!inRoom ? (
            <div className="lp-lobby" key="lobby">
              <p className="lp-lobby__label">{state.scene === 'doors' ? 'The doors are open' : 'Doors open in'}</p>
              <p className="lp-lobby__count">{state.scene === 'doors' ? 'Come in' : mmss(countdown)}</p>
              <div className="lp-lobby__waiting" aria-hidden="true">
                {PEOPLE.slice(1).map((person) => (
                  <span key={person.name} className={`lp-dot lp-dot--${person.hue}`}>
                    {person.initial}
                  </span>
                ))}
                <span className="lp-lobby__hint">3 waiting, cameras checked</span>
              </div>
              <span className={state.scene === 'doors' ? 'lp-lobby__button is-ready' : 'lp-lobby__button'}>Enter room</span>
            </div>
          ) : state.scene === 'share' ? (
            <div className="lp-share" key="share">
              <div className="lp-share__main">
                <Slide slide={state.slide} />
                <span className="lp-share__label">Ms Okafor is sharing</span>
              </div>
              <div className="lp-share__strip">
                {people.map((person, index) => (
                  <Tile key={person.name} person={person} index={index} speaking={state.speaking === index} hand={state.hand === index} small />
                ))}
              </div>
            </div>
          ) : (
            <div className="lp-grid" key="grid">
              {people.map((person, index) => (
                <Tile key={person.name} person={person} index={index} speaking={state.speaking === index} hand={state.hand === index} />
              ))}
              {state.reaction ? (
                <span className="lp-reaction" aria-hidden="true">
                  <i>👏</i>
                  <i>👏</i>
                  <i>🎉</i>
                </span>
              ) : null}
            </div>
          )}
        </div>

        <div className="lp-demo__foot">
          <div className={state.chat ? 'lp-chat is-shown' : 'lp-chat'} aria-hidden={!state.chat}>
            <span className="lp-dot lp-dot--sun">A</span>
            <span className="lp-chat__bubble">Why is it ¾ and not ⅔?</span>
          </div>
          <div className="lp-controls" aria-hidden="true">
            <span className="lp-control">Mic</span>
            <span className="lp-control">Camera</span>
            <span className={state.scene === 'share' ? 'lp-control is-on' : 'lp-control'}>Share</span>
            <span className="lp-control lp-control--end">Leave</span>
          </div>
        </div>
      </div>
      {state.ending ? (
        <p className="lp-demo__toast">
          5 minutes left <span className="lp-demo__toast-action">+10 min</span>
        </p>
      ) : null}
      {state.hand !== undefined && state.scene === 'share' ? (
        <p className="lp-demo__note" aria-hidden="true">
          Amira raised her hand
        </p>
      ) : null}
    </figure>
  );
}
