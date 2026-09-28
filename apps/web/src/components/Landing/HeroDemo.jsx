import { useEffect, useRef, useState } from 'react';
import { mmss } from './landingModel.js';

/**
 * The homepage's one moving picture  (Landing)
 *
 * A miniature of a real room, playing through what the product does in
 * twelve seconds: the lobby counts down, the doors open, people come in,
 * someone speaks, a question arrives in the chat, a reaction floats up, and
 * the host gets the "5 minutes left" notice. It is drawn with HTML and CSS
 * (no video, no images) so it is sharp at every size and costs nothing to load.
 *
 * It plays only while it is on screen, stops when the tab is hidden, and
 * shows a still of the full room to anyone who prefers reduced motion.
 */

const PEOPLE = [
  { name: 'Ms Okafor', initial: 'O', hue: 'sky', host: true },
  { name: 'Jonas', initial: 'J', hue: 'mint' },
  { name: 'Amira', initial: 'A', hue: 'sun' },
  { name: 'Lea', initial: 'L', hue: 'rose' },
];

// Scene timings in ms from the start of one loop.
const SCRIPT = [
  { at: 0, scene: 'lobby' },
  { at: 3600, scene: 'doors' },
  { at: 4600, scene: 'room', joined: 1 },
  { at: 5200, scene: 'room', joined: 2 },
  { at: 5800, scene: 'room', joined: 3 },
  { at: 6400, scene: 'room', joined: 4, speaking: 0 },
  { at: 7800, scene: 'room', joined: 4, speaking: 2, chat: true },
  { at: 9000, scene: 'room', joined: 4, speaking: 2, chat: true, reaction: true },
  { at: 10400, scene: 'room', joined: 4, speaking: 0, chat: true, ending: true },
];
const LOOP_MS = 12600;
const LOBBY_COUNTDOWN_MS = 3600;

const STILL = { scene: 'room', joined: 4, speaking: 0, chat: true, ending: false };

const prefersReducedMotion = () =>
  typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

function Tile({ person, speaking, index }) {
  return (
    <div className={`lp-tile lp-tile--${person.hue}${speaking ? ' is-speaking' : ''}`} style={{ '--i': index }}>
      <div className="lp-tile__figure" aria-hidden="true">
        <span className="lp-tile__head" />
        <span className="lp-tile__body" />
      </div>
      <span className="lp-tile__name">
        {person.name}
        {person.host ? <span className="lp-tile__role">host</span> : null}
      </span>
    </div>
  );
}

export default function HeroDemo() {
  const [state, setState] = useState(() => (prefersReducedMotion() ? STILL : SCRIPT[0]));
  const [countdown, setCountdown] = useState(LOBBY_COUNTDOWN_MS);
  const rootRef = useRef(null);
  const reduced = useRef(prefersReducedMotion());

  useEffect(() => {
    if (reduced.current) return undefined;
    let timers = [];
    let tick = 0;
    let visible = true;
    let running = false;

    const clear = () => {
      timers.forEach((timer) => window.clearTimeout(timer));
      timers = [];
      window.clearInterval(tick);
      running = false;
    };

    const play = () => {
      if (running || !visible || document.hidden) return;
      running = true;
      const loopStart = performance.now();
      SCRIPT.forEach((step) => {
        timers.push(window.setTimeout(() => setState(step), step.at));
      });
      tick = window.setInterval(() => {
        setCountdown(Math.max(0, LOBBY_COUNTDOWN_MS - (performance.now() - loopStart)));
      }, 250);
      timers.push(
        window.setTimeout(() => {
          clear();
          setCountdown(LOBBY_COUNTDOWN_MS);
          play();
        }, LOOP_MS),
      );
    };

    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        if (visible) play();
        else clear();
      },
      { threshold: 0.25 },
    );
    if (rootRef.current) observer.observe(rootRef.current);
    const onVisibility = () => (document.hidden ? clear() : play());
    document.addEventListener('visibilitychange', onVisibility);

    return () => {
      clear();
      observer.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, []);

  const inRoom = state.scene === 'room';
  const joined = state.joined ?? 0;

  return (
    <figure className="lp-demo" ref={rootRef} aria-label="A lesson room: the doors open, four people join, a question arrives in the chat.">
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
          ) : null}
        </div>

        <div className={`lp-demo__stage lp-demo__stage--${state.scene}`}>
          {!inRoom ? (
            <div className="lp-lobby">
              <p className="lp-lobby__label">{state.scene === 'doors' ? 'Doors are open' : 'Doors open in'}</p>
              <p className="lp-lobby__count" aria-live="off">
                {state.scene === 'doors' ? 'Come in' : mmss(countdown)}
              </p>
              <div className="lp-lobby__waiting" aria-hidden="true">
                {PEOPLE.slice(1).map((person) => (
                  <span key={person.name} className={`lp-dot lp-dot--${person.hue}`}>
                    {person.initial}
                  </span>
                ))}
                <span className="lp-lobby__hint">3 waiting</span>
              </div>
              <span className={state.scene === 'doors' ? 'lp-lobby__button is-ready' : 'lp-lobby__button'}>Enter room</span>
            </div>
          ) : (
            <div className="lp-grid">
              {PEOPLE.slice(0, joined).map((person, index) => (
                <Tile key={person.name} person={person} index={index} speaking={state.speaking === index} />
              ))}
              {state.reaction ? (
                <span className="lp-reaction" aria-hidden="true">
                  👏
                </span>
              ) : null}
            </div>
          )}
        </div>

        <div className="lp-demo__foot">
          <div className={state.chat ? 'lp-chat is-shown' : 'lp-chat'} aria-hidden={!state.chat}>
            <span className="lp-dot lp-dot--sun">A</span>
            <span className="lp-chat__bubble">Could you go over question 3 again?</span>
          </div>
          <div className="lp-controls" aria-hidden="true">
            <span className="lp-control">Mic</span>
            <span className="lp-control">Camera</span>
            <span className="lp-control">Share</span>
            <span className="lp-control lp-control--end">Leave</span>
          </div>
        </div>
      </div>
      {state.ending ? (
        <p className="lp-demo__toast" role="presentation">
          5 minutes left <span className="lp-demo__toast-action">+10 min</span>
        </p>
      ) : null}
    </figure>
  );
}
