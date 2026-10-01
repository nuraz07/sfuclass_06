import { NavLink, useLocation } from 'react-router-dom';
import { spaceMark } from './hubModel.js';

/**
 * The community's left rail: the four places, and your spaces with what is
 * new in each. On narrow screens it becomes a row of tabs above the content.
 */
export default function SpaceRail({ spaces, openQuestions }) {
  const location = useLocation();
  const tab = new URLSearchParams(location.search).get('tab');
  const onOverview = location.pathname === '/community';
  const is = (name) => onOverview && (tab ?? 'home') === name;

  return (
    <nav className="hb-rail" aria-label="Community">
      <div className="hb-rail__places">
        <NavLink to="/community" end className={() => (is('home') ? 'hb-place is-on' : 'hb-place')}>
          Home
        </NavLink>
        <NavLink to="/community?tab=questions" className={() => (is('questions') ? 'hb-place is-on' : 'hb-place')}>
          Questions
          {openQuestions > 0 ? <span className="hb-count">{openQuestions}</span> : null}
        </NavLink>
        <NavLink to="/community?tab=discover" className={() => (is('discover') ? 'hb-place is-on' : 'hb-place')}>
          Discover
        </NavLink>
        <NavLink to="/community?tab=new" className={() => (is('new') ? 'hb-place hb-place--new is-on' : 'hb-place hb-place--new')}>
          + New space
        </NavLink>
      </div>

      <p className="hb-rail__head">Your spaces</p>
      {spaces === null ? <p className="hb-muted hb-rail__empty">Loading…</p> : null}
      {spaces?.length === 0 ? <p className="hb-muted hb-rail__empty">None yet. Discover one, or create your own.</p> : null}
      <ul className="hb-rail__spaces">
        {(spaces ?? []).map((space) => (
          <li key={space.spaceId}>
            <NavLink to={`/community/spaces/${space.spaceId}`} className={({ isActive }) => (isActive ? 'hb-spacelink is-on' : 'hb-spacelink')}>
              <span className={`hb-mark hb-mark--${space.kind}`} aria-hidden="true">
                {spaceMark(space)}
              </span>
              <span className="hb-spacelink__name">{space.name}</span>
              {space.newActivity > 0 ? <span className="hb-dot" aria-label={`${space.newActivity} new`} /> : null}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
}
