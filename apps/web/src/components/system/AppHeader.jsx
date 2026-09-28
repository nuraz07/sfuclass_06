import { Link, NavLink } from 'react-router-dom';
import { useCore } from '@classroom/core-client';

/**
 * The app's top bar  (Design)
 *
 * The same five places as before — Dashboard, Community, Messages, Media,
 * Settings — with an icon each, a soft pill for the page you are on, and your
 * name on the right as the way to your settings. Purely presentation: every
 * link goes where it always went.
 */

const ICONS = {
  home: 'M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z',
  community: 'M8 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm8 0a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM2 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5M14.5 15c.5-.3 1-.5 1.5-.5 3.3 0 6 2.2 6 5.5',
  messages: 'M4 5h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9l-5 4V6a1 1 0 0 1 1-1z',
  media: 'M4 5h16v14H4zM4 15l5-5 4 4 3-3 4 4',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 13a7.6 7.6 0 0 0 0-2l2-1.6-2-3.4-2.4 1a7.7 7.7 0 0 0-1.7-1L15 3h-4l-.4 2.6a7.7 7.7 0 0 0-1.7 1l-2.4-1-2 3.4 2 1.6a7.6 7.6 0 0 0 0 2l-2 1.6 2 3.4 2.4-1a7.7 7.7 0 0 0 1.7 1L11 21h4l.4-2.6a7.7 7.7 0 0 0 1.7-1l2.4 1 2-3.4z',
};

const LINKS = [
  { to: '/', label: 'Dashboard', icon: 'home', end: true },
  { to: '/community', label: 'Community', icon: 'community' },
  { to: '/messages', label: 'Messages', icon: 'messages' },
  { to: '/media', label: 'Media', icon: 'media' },
  { to: '/settings', label: 'Settings', icon: 'settings' },
];

function Icon({ name }) {
  return (
    <svg className="app__icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={ICONS[name]} />
    </svg>
  );
}

export default function AppHeader() {
  const { session } = useCore();
  const name = session?.displayName ?? '';
  const initial = name.trim().charAt(0).toUpperCase() || '·';

  return (
    <header className="app__bar">
      <Link to="/" className="app__brand" aria-label="Classroom, dashboard">
        <svg className="app__mark" viewBox="0 0 32 32" aria-hidden="true">
          <rect x="3" y="6" width="26" height="18" rx="4" />
          <path d="M11 29h10M16 24v5" />
          <circle cx="23" cy="11" r="2.4" />
        </svg>
        <span className="app__brand-text">Classroom</span>
      </Link>

      <nav className="app__nav" aria-label="Main">
        {LINKS.map((link) => (
          <NavLink key={link.to} to={link.to} end={link.end}>
            <Icon name={link.icon} />
            <span className="app__nav-label">{link.label}</span>
          </NavLink>
        ))}
      </nav>

      <Link to="/settings/profile" className="app__me" title="Your profile and settings">
        <span className="app__avatar" aria-hidden="true">
          {initial}
        </span>
        <span className="app__me-name">{name}</span>
      </Link>
    </header>
  );
}
