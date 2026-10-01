import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, NavLink } from 'react-router-dom';
import { createUsernameApi, useCore } from '@classroom/core-client';
import { markSignOutIntent } from '../../lib/signOutIntent.js';
import UsernameDialog from './UsernameDialog.jsx';

/**
 * The app's top bar  (Design)
 *
 * Dashboard, Community, Messages and Media in the middle. Your picture (or
 * initial) on the right opens a menu with your name, Profile, Settings,
 * Privacy, the homepage and Sign out — Settings is where people look for it
 * in most apps, under their own picture, not as a fifth place to go. It also
 * shows your username and lets you choose or change it (you can sign in with
 * it instead of your email).
 *
 * The menu closes on a click outside, on Escape (focus returns to the
 * button), and after choosing; arrow keys move between items.
 */

const ICONS = {
  home: 'M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z',
  community: 'M8 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm8 0a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM2 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5M14.5 15c.5-.3 1-.5 1.5-.5 3.3 0 6 2.2 6 5.5',
  messages: 'M4 5h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9l-5 4V6a1 1 0 0 1 1-1z',
  media: 'M4 5h16v14H4zM4 15l5-5 4 4 3-3 4 4',
  user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 13a7.6 7.6 0 0 0 0-2l2-1.6-2-3.4-2.4 1a7.7 7.7 0 0 0-1.7-1L15 3h-4l-.4 2.6a7.7 7.7 0 0 0-1.7 1l-2.4-1-2 3.4 2 1.6a7.6 7.6 0 0 0 0 2l-2 1.6 2 3.4 2.4-1a7.7 7.7 0 0 0 1.7 1L11 21h4l.4-2.6a7.7 7.7 0 0 0 1.7-1l2.4 1 2-3.4z',
  shield: 'M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6z',
  globe: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z',
  out: 'M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 16l4-4-4-4M14 12H4',
  at: 'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.5 7.1',
  caret: 'M6 9l6 6 6-6',
};

const LINKS = [
  { to: '/', label: 'Dashboard', icon: 'home', end: true },
  { to: '/community', label: 'Community', icon: 'community' },
  { to: '/messages', label: 'Messages', icon: 'messages' },
  { to: '/media', label: 'Media', icon: 'media' },
];

function Icon({ name, className = 'app__icon' }) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      <path d={ICONS[name]} />
    </svg>
  );
}

function Avatar({ session }) {
  const name = session?.displayName ?? '';
  return (
    <span className="app__avatar" aria-hidden="true">
      {session?.avatarUrl ? <img src={session.avatarUrl} alt="" /> : name.trim().charAt(0).toUpperCase() || '·'}
    </span>
  );
}

function ProfileMenu({ session, onSignOut }) {
  const { http } = useCore();
  const usernames = useMemo(() => createUsernameApi(http), [http]);
  const [open, setOpen] = useState(false);
  const [username, setUsername] = useState(undefined);
  const [choosing, setChoosing] = useState(false);

  // Asked once, the first time the menu opens.
  useEffect(() => {
    if (!open || username !== undefined) return;
    usernames
      .mine()
      .then((result) => setUsername(result.username))
      .catch(() => setUsername(null));
  }, [open, username, usernames]);
  const wrapRef = useRef(null);
  const buttonRef = useRef(null);
  const menuRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const onPointer = (event) => {
      if (!wrapRef.current?.contains(event.target)) setOpen(false);
    };
    const onKey = (event) => {
      if (event.key === 'Escape') {
        setOpen(false);
        buttonRef.current?.focus();
      }
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        const items = [...(menuRef.current?.querySelectorAll('[role="menuitem"]') ?? [])];
        const index = items.indexOf(document.activeElement);
        const next = event.key === 'ArrowDown' ? (index + 1) % items.length : (index - 1 + items.length) % items.length;
        items[next]?.focus();
      }
    };
    document.addEventListener('pointerdown', onPointer);
    document.addEventListener('keydown', onKey);
    menuRef.current?.querySelector('[role="menuitem"]')?.focus();
    return () => {
      document.removeEventListener('pointerdown', onPointer);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const close = () => setOpen(false);
  const name = session?.displayName ?? '';

  return (
    <div className="app__me-wrap" ref={wrapRef}>
      <button
        ref={buttonRef}
        type="button"
        className="app__me"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Your account"
        onClick={() => setOpen((value) => !value)}
      >
        <Avatar session={session} />
        <span className="app__me-name">{name}</span>
        <Icon name="caret" className="app__caret" />
      </button>
      {open ? (
        <div className="app__menu" role="menu" ref={menuRef} aria-label="Your account">
          <div className="app__menu-head">
            <Avatar session={session} />
            <div>
              <strong>{name || 'You'}</strong>
              {username ? <span>@{username}</span> : null}
              {session?.email ? <span>{session.email}</span> : null}
            </div>
          </div>
          <Link role="menuitem" to="/settings/profile" onClick={close}>
            <Icon name="user" /> Profile
          </Link>
          <button
            type="button"
            role="menuitem"
            className="app__menu-item"
            onClick={() => {
              close();
              setChoosing(true);
            }}
          >
            <Icon name="at" /> {username ? 'Change username' : 'Choose a username'}
          </button>
          <Link role="menuitem" to="/settings" onClick={close}>
            <Icon name="settings" /> Settings
          </Link>
          <Link role="menuitem" to="/settings/privacy" onClick={close}>
            <Icon name="shield" /> Privacy
          </Link>
          <Link role="menuitem" to="/welcome" onClick={close}>
            <Icon name="globe" /> Homepage
          </Link>
          <hr />
          <button
            type="button"
            role="menuitem"
            className="app__menu-item app__menu-item--danger"
            onClick={() => {
              close();
              onSignOut();
            }}
          >
            <Icon name="out" /> Sign out
          </button>
        </div>
      ) : null}
      {choosing ? (
        <UsernameDialog
          current={username ?? null}
          onClose={() => setChoosing(false)}
          onSaved={(saved) => {
            setUsername(saved);
            setChoosing(false);
          }}
        />
      ) : null}
    </div>
  );
}

export default function AppHeader() {
  const { session, signOut } = useCore();

  // SessionWatch (AppLayout) takes it from here: on purpose → the homepage.
  const handleSignOut = () => {
    markSignOutIntent();
    signOut().catch(() => undefined);
  };

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

      <ProfileMenu session={session} onSignOut={handleSignOut} />
    </header>
  );
}
