import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';

/**
 * The homepage's navigation  (Landing)
 *
 * Condenses once the page scrolls, and a highlighter mark slides to the
 * section you are reading. On small screens the links move into a sheet that
 * opens from the top. Links are in-page anchors; Sign in and Create account
 * lead into the app.
 */

export const NAV_LINKS = [
  { id: 'features', label: 'Features' },
  { id: 'how', label: 'How it works' },
  { id: 'rooms', label: 'Rooms' },
  { id: 'teams', label: 'For schools' },
  { id: 'security', label: 'Security' },
  { id: 'faq', label: 'FAQ' },
  { id: 'contact', label: 'Contact' },
];

export function Brand({ small = false }) {
  return (
    <span className={small ? 'lp-brand lp-brand--small' : 'lp-brand'}>
      <svg className="lp-brand__mark" viewBox="0 0 32 32" aria-hidden="true">
        <rect x="3" y="6" width="26" height="18" rx="4" />
        <path d="M11 29h10M16 24v5" />
        <circle cx="23" cy="11" r="2.4" />
      </svg>
      Classroom
    </span>
  );
}

export default function SiteNav({ signedIn }) {
  const [condensed, setCondensed] = useState(false);
  const [active, setActive] = useState(null);
  const [open, setOpen] = useState(false);
  const [mark, setMark] = useState(null);
  const linksRef = useRef(null);

  // Condense after the first bit of scrolling.
  useEffect(() => {
    const onScroll = () => setCondensed(window.scrollY > 24);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  // Which section is being read: the last one whose top passed a third of the screen.
  useEffect(() => {
    const sections = NAV_LINKS.map((link) => document.getElementById(link.id)).filter(Boolean);
    if (sections.length === 0) return undefined;
    let frame = 0;
    const measure = () => {
      frame = 0;
      const line = window.innerHeight / 3;
      let current = null;
      for (const section of sections) if (section.getBoundingClientRect().top <= line) current = section.id;
      setActive(current);
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

  // The highlighter mark follows the active link.
  useLayoutEffect(() => {
    const list = linksRef.current;
    const link = active && list?.querySelector(`[data-section="${active}"]`);
    if (!list || !link) {
      setMark(null);
      return;
    }
    const a = list.getBoundingClientRect();
    const b = link.getBoundingClientRect();
    setMark({ left: b.left - a.left, width: b.width });
  }, [active, condensed]);

  // The sheet closes with Escape, and the page behind it does not scroll.
  useEffect(() => {
    if (!open) return undefined;
    const onKey = (event) => event.key === 'Escape' && setOpen(false);
    document.addEventListener('keydown', onKey);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', onKey);
      document.body.style.overflow = overflow;
    };
  }, [open]);

  return (
    <header className={`lp-nav${condensed ? ' is-condensed' : ''}${open ? ' is-open' : ''}`}>
      <div className="lp-nav__inner">
        <Link to={signedIn ? '/' : '/welcome'} className="lp-nav__home" aria-label="Classroom home" onClick={() => setOpen(false)}>
          <Brand />
        </Link>

        <nav className="lp-nav__links" aria-label="Sections" ref={linksRef}>
          {mark ? <span className="lp-nav__mark" style={{ transform: `translateX(${mark.left}px)`, width: mark.width }} aria-hidden="true" /> : null}
          {NAV_LINKS.map((link) => (
            <a key={link.id} href={`#${link.id}`} data-section={link.id} aria-current={active === link.id ? 'true' : undefined}>
              {link.label}
            </a>
          ))}
        </nav>

        <div className="lp-nav__actions">
          {signedIn ? (
            <Link className="lp-button lp-button--dark lp-button--small" to="/">
              Open Classroom
            </Link>
          ) : (
            <>
              <Link className="lp-nav__signin" to="/login">
                Sign in
              </Link>
              <Link className="lp-button lp-button--dark lp-button--small" to="/signup">
                Create account
              </Link>
            </>
          )}
          <button
            type="button"
            className="lp-nav__menu"
            aria-expanded={open}
            aria-controls="lp-sheet"
            aria-label={open ? 'Close menu' : 'Open menu'}
            onClick={() => setOpen((value) => !value)}
          >
            <span />
            <span />
          </button>
        </div>
      </div>

      <div id="lp-sheet" className="lp-sheet" hidden={!open}>
        <nav aria-label="Sections">
          {NAV_LINKS.map((link, index) => (
            <a key={link.id} href={`#${link.id}`} style={{ '--i': index }} onClick={() => setOpen(false)}>
              {link.label}
            </a>
          ))}
        </nav>
        {signedIn ? null : (
          <div className="lp-sheet__actions">
            <Link className="lp-button lp-button--ghost" to="/login">
              Sign in
            </Link>
            <Link className="lp-button lp-button--primary" to="/signup">
              Create account
            </Link>
          </div>
        )}
      </div>
    </header>
  );
}
