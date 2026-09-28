import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import './auth.css';

/**
 * The frame around sign-in and sign-up  (Landing)
 *
 * The homepage's slate board on one side — so going from "Create account" to
 * the form feels like the same place — and the form on a calm surface on the
 * other. On a phone the board shrinks to a header.
 */
export default function AuthShell({ title, lead, children, footer }) {
  useEffect(() => {
    const previous = document.title;
    document.title = `${title} | Classroom`;
    return () => {
      document.title = previous;
    };
  }, [title]);

  return (
    <div className="au">
      <aside className="au-board">
        <Link to="/" className="au-brand" aria-label="Classroom homepage">
          <svg className="au-brand__mark" viewBox="0 0 32 32" aria-hidden="true">
            <rect x="3" y="6" width="26" height="18" rx="4" />
            <path d="M11 29h10M16 24v5" />
            <circle cx="23" cy="11" r="2.4" />
          </svg>
          Classroom
        </Link>
        <div className="au-board__art" aria-hidden="true">
          <p className="au-board__big">Doors open in</p>
          <p className="au-board__count">4:59</p>
          <span className="au-board__track">
            <i />
          </span>
        </div>
        <p className="au-board__line">Live lessons, courses and your community. One sign-in for all of it.</p>
      </aside>

      <main className="au-main">
        <div className="au-card">
          <h1 className="au-title">{title}</h1>
          {lead ? <p className="au-lead">{lead}</p> : null}
          {children}
        </div>
        {footer ? <div className="au-footer">{footer}</div> : null}
      </main>
    </div>
  );
}
