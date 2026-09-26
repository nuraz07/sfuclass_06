import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createAccountApi, createProfileApi, useCore } from '@classroom/core-client';

import ProfileSettings from '../components/Settings/ProfileSettings.jsx';
import PrivacySettings from '../components/Settings/PrivacySettings.jsx';
import RegionSettings from '../components/Settings/RegionSettings.jsx';
import LessonSettings from '../components/Settings/LessonSettings.jsx';
import AppearanceSettings from '../components/Settings/AppearanceSettings.jsx';
import TeachingSettings from '../components/Settings/TeachingSettings.jsx';
import NotificationSettings from '../components/Settings/NotificationSettings.jsx';
import SecuritySettings from '../components/Settings/SecuritySettings.jsx';
import ActivitySettings from '../components/Settings/ActivitySettings.jsx';
import { searchSettings } from '../components/Settings/settingsIndex.js';
import { mergeDeep, pickDeep } from '../components/Settings/notificationsModel.js';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';
import { liveEventsAvailable, onUserEvent } from '../lib/userEvents.js';
import '../components/Settings/settings.css';

/**
 * Settings  (Phase A + B)
 *
 * One tab per topic, each with its own address (/settings/<tab>), a search
 * across every setting, and no Save button: every change is saved the moment
 * it is made and can be undone from the notice that confirms it.
 *
 *   profile        how others see you, and a preview of exactly that
 *   privacy        check-up, private messages, visibility, blocked people
 *   notifications  type × channel, push, tests, quiet hours, focus, muted chats
 *   security       signed-in devices, sign out elsewhere, sign-in history
 *   activity       recent changes to your settings
 *   region         language, time zone, date and time format
 *   lessons        how you join, sound processing, device test
 *   appearance     text size, motion
 *   teaching       how your lessons start (teachers and owners only)
 *
 * A change made on another device arrives live (settings:changed) and the
 * page reloads what it shows; without a live connection it reloads when the
 * window regains focus.
 */

const ALL_TABS = [
  { id: 'profile', label: 'Profile' },
  { id: 'privacy', label: 'Privacy' },
  { id: 'notifications', label: 'Notifications' },
  { id: 'security', label: 'Sign-in & devices' },
  { id: 'activity', label: 'Recent changes' },
  { id: 'region', label: 'Language & region' },
  { id: 'lessons', label: 'Lessons' },
  { id: 'appearance', label: 'Appearance' },
  { id: 'teaching', label: 'Teaching', roles: ['teacher', 'owner'] },
];

/** An own save echoes back as settings:changed; ignore echoes this soon after one. */
const OWN_ECHO_MS = 2_000;

const pick = (source, keys) => Object.fromEntries(keys.map((key) => [key, source?.[key] ?? null]));

export default function SettingsPage() {
  const core = useCore();
  const { http } = core;
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const account = useMemo(() => createAccountApi(http), [http]);
  const { tab: tabParam } = useParams();
  const navigate = useNavigate();

  const [own, setOwn] = useState(null);
  const [privacy, setPrivacy] = useState(null);
  const [preferences, setPreferences] = useState(null);
  const [blocks, setBlocks] = useState([]);
  const [notifications, setNotifications] = useState(null);
  const [notificationsError, setNotificationsError] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [notice, setNotice] = useState(null);
  const [query, setQuery] = useState('');
  const [highlight, setHighlight] = useState(null);
  const [reloadKey, setReloadKey] = useState(0);
  const noticeTimer = useRef(null);
  const lastOwnSave = useRef(0);

  const loadNotifications = useCallback(async () => {
    try {
      setNotifications(await account.getNotifications());
      setNotificationsError(false);
    } catch {
      setNotificationsError(true);
    }
  }, [account]);

  const load = useCallback(async () => {
    setLoadError(false);
    try {
      const [ownProfile, ownPrivacy, ownPreferences, ownBlocks] = await Promise.all([
        profiles.getOwn(),
        profiles.getPrivacy(),
        profiles.getPreferences(),
        profiles.listBlocks({ limit: 100 }),
      ]);
      setOwn(ownProfile);
      setPrivacy(ownPrivacy);
      setPreferences(cachePreferences(ownPreferences));
      setBlocks(ownBlocks.items);
      cacheLocale(ownProfile.locale);
    } catch {
      setLoadError(true);
    }
    // Separate: a problem with notifications must not hide the other tabs.
    await loadNotifications();
  }, [profiles, loadNotifications]);

  useEffect(() => {
    load();
    return () => window.clearTimeout(noticeTimer.current);
  }, [load]);

  /* ---- changes made elsewhere ---- */

  useEffect(() => {
    const refresh = () => {
      if (Date.now() - lastOwnSave.current < OWN_ECHO_MS) return;
      load();
      setReloadKey((key) => key + 1);
    };

    if (liveEventsAvailable(core)) {
      let timer = null;
      const off = onUserEvent(core, 'settings:changed', () => {
        // The event may arrive on more than one socket: one reload is enough.
        window.clearTimeout(timer);
        timer = window.setTimeout(refresh, 150);
      });
      return () => {
        window.clearTimeout(timer);
        off();
      };
    }

    const onFocus = () => refresh();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [core, load]);

  const tabs = useMemo(
    () => ALL_TABS.filter((tab) => !tab.roles || tab.roles.includes(own?.role)),
    [own?.role],
  );
  const tab = tabs.some((t) => t.id === tabParam) ? tabParam : 'profile';

  /* ---- saving, with undo ---- */

  const announce = useCallback((text, undo = null, error = false) => {
    window.clearTimeout(noticeTimer.current);
    setNotice({ text, undo, error });
    noticeTimer.current = window.setTimeout(() => setNotice(null), undo ? 8_000 : 4_000);
  }, []);

  const failed = useCallback(
    (cause) => {
      announce(cause?.detail ?? cause?.message ?? 'That change was not saved. Try again.', null, true);
      throw cause;
    },
    [announce],
  );

  const markOwnSave = () => {
    lastOwnSave.current = Date.now();
  };

  const saveProfile = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(own, Object.keys(patch));
      markOwnSave();
      try {
        const next = await profiles.update(patch);
        setOwn(next);
        if (patch.locale) cacheLocale(next.locale);
        announce(
          `${label} saved.`,
          undoable ? () => saveProfile(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        failed(cause);
      }
    },
    [own, profiles, announce, failed],
  );

  const savePrivacy = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(privacy, Object.keys(patch));
      setPrivacy((current) => ({ ...current, ...patch }));
      markOwnSave();
      try {
        setPrivacy(await profiles.updatePrivacy(patch));
        announce(
          `${label} saved.`,
          undoable ? () => savePrivacy(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        setPrivacy((current) => ({ ...current, ...before }));
        failed(cause);
      }
    },
    [privacy, profiles, announce, failed],
  );

  const savePreferences = useCallback(
    async (section, patch, label, { undoable = true } = {}) => {
      const before = pick(preferences?.[section], Object.keys(patch));
      setPreferences((current) => ({ ...current, [section]: { ...current[section], ...patch } }));
      markOwnSave();
      try {
        const next = await profiles.updatePreferences({ [section]: patch });
        setPreferences(cachePreferences(next));
        announce(
          `${label} saved.`,
          undoable
            ? () => savePreferences(section, before, label, { undoable: false }).then(() => announce(`${label} restored.`))
            : null,
        );
      } catch (cause) {
        setPreferences((current) => ({ ...current, [section]: { ...current[section], ...before } }));
        failed(cause);
      }
    },
    [preferences, profiles, announce, failed],
  );

  const saveNotifications = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pickDeep(notifications?.settings, patch);
      setNotifications((current) => ({ ...current, settings: mergeDeep(current.settings, patch) }));
      markOwnSave();
      try {
        setNotifications(await account.updateNotifications(patch));
        announce(
          `${label} saved.`,
          undoable
            ? () => saveNotifications(before, label, { undoable: false }).then(() => announce(`${label} restored.`))
            : null,
        );
      } catch (cause) {
        setNotifications((current) => ({ ...current, settings: mergeDeep(current.settings, before) }));
        failed(cause);
      }
    },
    [notifications, account, announce, failed],
  );

  const unblock = useCallback(
    async (block) => {
      try {
        await profiles.unblock(block.blockedUserId);
        setBlocks((current) => current.filter((b) => b.blockedUserId !== block.blockedUserId));
        announce(`${block.profile.displayName} is no longer blocked.`, async () => {
          await profiles.block({ userId: block.blockedUserId });
          setBlocks((current) => [block, ...current]);
          announce(`${block.profile.displayName} is blocked again.`);
        });
      } catch (cause) {
        announce(cause?.detail ?? 'That person could not be unblocked.', null, true);
      }
    },
    [profiles, announce],
  );

  /* ---- navigation and search ---- */

  const jumpTo = useCallback(
    (tabId, anchor) => {
      setQuery('');
      navigate(`/settings/${tabId}`);
      setHighlight(anchor);
    },
    [navigate],
  );

  useEffect(() => {
    if (!highlight) return undefined;
    const frame = requestAnimationFrame(() => {
      const el = document.getElementById(`setting-${highlight}`);
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      el?.classList.add('st-flash');
    });
    const timer = window.setTimeout(() => {
      document.getElementById(`setting-${highlight}`)?.classList.remove('st-flash');
      setHighlight(null);
    }, 1_600);
    return () => {
      cancelAnimationFrame(frame);
      window.clearTimeout(timer);
    };
  }, [highlight, tab]);

  const results = useMemo(() => searchSettings(query, tabs), [query, tabs]);

  /* ---- render ---- */

  if (loadError) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-error">Your settings could not be loaded.</p>
        <button type="button" className="btn" onClick={load}>
          Try again
        </button>
      </section>
    );
  }

  if (!own || !privacy || !preferences) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-hint">Loading your settings…</p>
      </section>
    );
  }

  const tabProps = { own, privacy, preferences, blocks, saveProfile, savePrivacy, savePreferences, unblock };

  const notificationsTab = notifications ? (
    <NotificationSettings
      account={account}
      notifications={notifications}
      saveNotifications={saveNotifications}
      announce={announce}
      reloadNotifications={loadNotifications}
    />
  ) : notificationsError ? (
    <>
      <p className="st-error">Your notification settings could not be loaded.</p>
      <button type="button" className="btn" onClick={loadNotifications}>
        Try again
      </button>
    </>
  ) : (
    <p className="st-hint">Loading…</p>
  );

  return (
    <section className="page st-page">
      <header className="st-header">
        <h1>Settings</h1>
        <input
          className="st-search"
          type="search"
          placeholder="Search settings, e.g. microphone, push or devices"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          aria-label="Search settings"
        />
      </header>

      <div className="st-layout">
        <nav className="st-nav" aria-label="Settings sections">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              className={t.id === tab && !query ? 'st-nav__item is-active' : 'st-nav__item'}
              aria-current={t.id === tab && !query ? 'page' : undefined}
              onClick={() => {
                setQuery('');
                navigate(`/settings/${t.id}`);
              }}
            >
              {t.label}
            </button>
          ))}
        </nav>

        <div className="st-content">
          {query.trim() ? (
            <div className="st-results" aria-live="polite">
              {results.length === 0 ? <p className="st-hint">No setting matches “{query}”.</p> : null}
              {results.map((entry) => (
                <button key={`${entry.tab}-${entry.anchor}`} type="button" className="st-result" onClick={() => jumpTo(entry.tab, entry.anchor)}>
                  <span className="st-result__label">{entry.label}</span>
                  <span className="st-hint">{tabs.find((t) => t.id === entry.tab)?.label}</span>
                </button>
              ))}
            </div>
          ) : (
            <>
              {tab === 'profile' && <ProfileSettings {...tabProps} />}
              {tab === 'privacy' && <PrivacySettings {...tabProps} onJump={(anchor) => jumpTo('privacy', anchor)} />}
              {tab === 'notifications' && notificationsTab}
              {tab === 'security' && <SecuritySettings account={account} announce={announce} reloadKey={reloadKey} />}
              {tab === 'activity' && <ActivitySettings account={account} onJump={jumpTo} reloadKey={reloadKey} />}
              {tab === 'region' && <RegionSettings {...tabProps} />}
              {tab === 'lessons' && <LessonSettings {...tabProps} />}
              {tab === 'appearance' && <AppearanceSettings {...tabProps} />}
              {tab === 'teaching' && <TeachingSettings {...tabProps} />}
            </>
          )}
        </div>
      </div>

      {notice ? (
        <div className={notice.error ? 'st-notice st-notice--error' : 'st-notice'} role="status" aria-live="polite">
          <span>{notice.text}</span>
          {notice.undo ? (
            <button
              type="button"
              className="st-notice__undo"
              onClick={() => {
                const undo = notice.undo;
                setNotice(null);
                undo().catch(() => undefined);
              }}
            >
              Undo
            </button>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
