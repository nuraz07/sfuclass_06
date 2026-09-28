import { useEffect, useRef, useState } from 'react';

/**
 * Motion helpers for the homepage  (Landing)
 *
 * One easing and one idea throughout: things arrive from slightly below and
 * slightly out of focus, and settle. Nothing moves for anyone who asked their
 * system for reduced motion — they get the finished state at once.
 */

export const prefersReducedMotion = () =>
  typeof window !== 'undefined' && Boolean(window.matchMedia?.('(prefers-reduced-motion: reduce)').matches);

/** true once the element has come into view (and stays true). */
export function useInView({ threshold = 0.18, rootMargin = '0px 0px -8% 0px' } = {}) {
  const ref = useRef(null);
  const [inView, setInView] = useState(() => prefersReducedMotion());

  useEffect(() => {
    if (inView || !ref.current || typeof IntersectionObserver === 'undefined') {
      if (typeof IntersectionObserver === 'undefined') setInView(true);
      return undefined;
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setInView(true);
          observer.disconnect();
        }
      },
      { threshold, rootMargin },
    );
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, [inView, threshold, rootMargin]);

  return [ref, inView];
}

/**
 * Calls `onFrame(rect, viewportHeight)` once per animation frame while the
 * page scrolls — for effects tied to scroll position. Stops when unmounted.
 */
export function useScrollFrame(ref, onFrame) {
  const callback = useRef(onFrame);
  callback.current = onFrame;

  useEffect(() => {
    if (prefersReducedMotion()) return undefined;
    let frame = 0;
    const run = () => {
      frame = 0;
      if (ref.current) callback.current(ref.current.getBoundingClientRect(), window.innerHeight);
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(run);
    };
    run();
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', schedule);
    };
  }, [ref]);
}
