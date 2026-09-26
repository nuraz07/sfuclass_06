import { useCallback, useEffect, useState } from 'react';
import { Choice, Section, Toggle } from './fields.jsx';
import { CATEGORY_ROWS, CHANNEL_COLUMNS, describeMuteEnd, describeQuietHours } from './notificationsModel.js';
import { disablePush, enablePush, currentSubscription, pushPermission, pushSupported } from '../../lib/pushClient.js';
import { formatDate, formatTime } from '../../lib/preferences.js';

/**
 * Notifications  (Settings, Phase B)
 *
 * Which notifications reach you, where and when. The rules that apply these
 * settings live on the server (server/src/settings/notifications.js); every
 * switch here is saved at once and can be undone from the notice.
 *
 *   matrix     type × channel: in the app, push, email
 *   push       this browser: on or off
 *   test       one test notification per channel, with what really happened
 *   quiet      no push in a window of your time zone
 *   focus      in a lesson: chat is held and summarised afterwards
 *   previews   push and email say who wrote, and only if on, what
 *   digest     community digest by email
 *   muted      every muted chat, with when the mute ends
 */

const formatEnd = (date) => `${formatDate(date)} ${formatTime(date)}`;

function Matrix({ settings, saveNotifications }) {
  return (
    <Section
      id="matrix"
      title="What you are notified about"
      hint="In the app means the bell and a notice on screen. Push reaches this computer or phone when the app is closed. Email goes to your account address."
    >
      <div className="st-matrix" role="table" aria-label="Notifications by type and channel">
        <div className="st-matrix__row st-matrix__head" role="row">
          <span role="columnheader">Type</span>
          {CHANNEL_COLUMNS.map((column) => (
            <span key={column.id} role="columnheader" className="st-matrix__cell">
              {column.label}
            </span>
          ))}
        </div>
        {CATEGORY_ROWS.map((row) => (
          <div key={row.id} className="st-matrix__row" role="row">
            <span role="rowheader" className="st-matrix__label">
              <span className="st-label">{row.label}</span>
              <span className="st-hint">{row.hint}</span>
            </span>
            {CHANNEL_COLUMNS.map((column) => {
              const checked = Boolean(settings.categories?.[row.id]?.[column.id]);
              return (
                <span key={column.id} role="cell" className="st-matrix__cell">
                  <input
                    type="checkbox"
                    className="st-check"
                    checked={checked}
                    aria-label={`${row.label}: ${column.label}`}
                    onChange={(event) =>
                      saveNotifications(
                        { categories: { [row.id]: { [column.id]: event.target.checked } } },
                        `${row.label} · ${column.label}`,
                      ).catch(() => undefined)
                    }
                  />
                </span>
              );
            })}
          </div>
        ))}
      </div>
      <p className="st-hint">
        Sign-in links, password resets and other messages about your account always reach you.
      </p>
    </Section>
  );
}

function PushOnThisDevice({ account, push, announce, reload }) {
  const [state, setState] = useState('checking');
  const [busy, setBusy] = useState(false);

  const check = useCallback(async () => {
    if (!pushSupported()) return setState('unsupported');
    if (pushPermission() === 'denied') return setState('blocked');
    const subscription = await currentSubscription().catch(() => null);
    setState(subscription && pushPermission() === 'granted' ? 'on' : 'off');
    return undefined;
  }, []);

  useEffect(() => {
    check();
  }, [check]);

  const turnOn = async () => {
    setBusy(true);
    try {
      const result = await enablePush({ account, publicKey: push.publicKey });
      if (!result.ok) announce(result.reason, null, true);
      else announce('Push is on for this browser.');
    } catch (cause) {
      announce(cause?.detail ?? cause?.message ?? 'Push could not be turned on.', null, true);
    } finally {
      setBusy(false);
      await check();
      reload();
    }
  };

  const turnOff = async () => {
    setBusy(true);
    try {
      await disablePush({ account });
      announce('Push is off for this browser.');
    } finally {
      setBusy(false);
      await check();
      reload();
    }
  };

  let text;
  if (!push.configured) text = 'Push is not set up on the server yet (the web push keys are missing).';
  else if (state === 'unsupported') text = 'This browser cannot receive push notifications.';
  else if (state === 'blocked') text = 'Notifications are blocked for this site. Allow them in the address bar to use push.';
  else if (state === 'on') text = 'This browser receives push notifications.';
  else if (state === 'off') text = 'This browser does not receive push notifications.';
  else text = 'Checking…';

  return (
    <Section
      id="push"
      title="Push on this device"
      hint={`Push is set per browser. ${push.devices === 1 ? 'One browser receives' : `${push.devices} browsers receive`} push on your account.`}
    >
      <div className="st-inline">
        <span>{text}</span>
        {push.configured && state === 'off' ? (
          <button type="button" className="btn" onClick={turnOn} disabled={busy}>
            Turn on push
          </button>
        ) : null}
        {push.configured && state === 'on' ? (
          <button type="button" className="btn btn--tiny" onClick={turnOff} disabled={busy}>
            Turn off for this browser
          </button>
        ) : null}
      </div>
    </Section>
  );
}

function TestNotifications({ account }) {
  const [results, setResults] = useState({});
  const [busy, setBusy] = useState(null);

  const send = async (channel) => {
    setBusy(channel);
    try {
      const result = await account.sendTestNotification(channel);
      setResults((current) => ({ ...current, [channel]: { ok: result.delivered > 0, text: result.detail } }));
    } catch (cause) {
      setResults((current) => ({
        ...current,
        [channel]: { ok: false, text: cause?.detail ?? cause?.message ?? 'The test could not be sent.' },
      }));
    } finally {
      setBusy(null);
    }
  };

  return (
    <Section id="test" title="Send a test notification" hint="Checks one channel end to end, with your real settings on the server.">
      {CHANNEL_COLUMNS.map((column) => (
        <div key={column.id} className="st-test">
          <button type="button" className="btn btn--tiny" disabled={busy !== null} onClick={() => send(column.id)}>
            {busy === column.id ? 'Sending…' : `Test ${column.label.toLowerCase()}`}
          </button>
          {results[column.id] ? (
            <span className={results[column.id].ok ? 'st-test__ok' : 'st-error'}>{results[column.id].text}</span>
          ) : null}
        </div>
      ))}
    </Section>
  );
}

function TimeInput({ label, value, onSave }) {
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  return (
    <label className="st-label st-time">
      {label}
      <input
        type="time"
        className="st-input__field"
        value={draft}
        step={300}
        onChange={(event) => setDraft(event.target.value)}
        onBlur={() => {
          if (draft && draft !== value) onSave(draft).catch(() => setDraft(value));
        }}
      />
    </label>
  );
}

function QuietHours({ view, saveNotifications }) {
  const quiet = view.settings.quietHours;
  return (
    <Section
      id="quiet"
      title="Quiet hours"
      hint={`No push during these hours, in your time zone (${view.timeZone.replace(/_/g, ' ')}). Everything still arrives in the app.`}
    >
      <Toggle
        label="Use quiet hours"
        hint={quiet.enabled ? `${describeQuietHours(quiet)}${view.quietNow ? ' — quiet right now' : ''}` : null}
        checked={quiet.enabled}
        onChange={(value) => saveNotifications({ quietHours: { enabled: value } }, 'Quiet hours')}
      />
      <div className="st-inline">
        <TimeInput
          label="From"
          value={quiet.start}
          onSave={(value) => saveNotifications({ quietHours: { start: value } }, 'Quiet hours start')}
        />
        <TimeInput
          label="Until"
          value={quiet.end}
          onSave={(value) => saveNotifications({ quietHours: { end: value } }, 'Quiet hours end')}
        />
      </div>
      <Toggle
        label="Let a lesson that is about to start through"
        hint="The reminder 10 minutes before a lesson, and a lesson that starts now."
        checked={quiet.allowLessonReminders}
        onChange={(value) => saveNotifications({ quietHours: { allowLessonReminders: value } }, 'Lesson reminders in quiet hours')}
      />
    </Section>
  );
}

function MutedChats({ account, announce }) {
  const [items, setItems] = useState(null);

  const load = useCallback(async () => {
    try {
      setItems((await account.listMutedChats()).items);
    } catch {
      setItems([]);
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load]);

  const unmute = async (chat) => {
    try {
      await account.unmuteChat(chat);
      setItems((current) => current.filter((item) => !(item.kind === chat.kind && item.id === chat.id)));
      announce(`${chat.title} is no longer muted.`, async () => {
        await account.muteChat({ kind: chat.kind, id: chat.id, until: chat.mutedUntil });
        await load();
        announce(`${chat.title} is muted again.`);
      });
    } catch (cause) {
      announce(cause?.detail ?? 'That chat could not be unmuted.', null, true);
    }
  };

  return (
    <Section id="muted" title="Muted chats" hint="A muted chat still counts as unread, but never notifies you.">
      {items === null ? <p className="st-hint">Loading…</p> : null}
      {items?.length === 0 ? <p className="st-hint">No chat is muted.</p> : null}
      {items?.map((chat) => (
        <div key={`${chat.kind}-${chat.id}`} className="st-link">
          <span className="st-link__label">{chat.title}</span>
          <span className="st-link__url">Muted {describeMuteEnd(chat.mutedUntil, new Date(), formatEnd)}</span>
          <button type="button" className="btn btn--tiny" onClick={() => unmute(chat)}>
            Unmute
          </button>
        </div>
      ))}
    </Section>
  );
}

export default function NotificationSettings({ account, notifications, saveNotifications, announce, reloadNotifications }) {
  const { settings } = notifications;
  return (
    <>
      <Matrix settings={settings} saveNotifications={saveNotifications} />
      <PushOnThisDevice account={account} push={notifications.push} announce={announce} reload={reloadNotifications} />
      <TestNotifications account={account} />
      <QuietHours view={notifications} saveNotifications={saveNotifications} />

      <Section title="During lessons and on the lock screen">
        <Toggle
          id="focus"
          label="Focus during lessons"
          hint="While you are in a live lesson, private messages and mentions do not notify you. When you leave, you get one summary."
          checked={settings.focusDuringLessons}
          onChange={(value) => saveNotifications({ focusDuringLessons: value }, 'Focus during lessons')}
        />
        <Toggle
          id="previews"
          label="Show message text in push and email"
          hint="Off: they say who wrote to you, not what."
          checked={settings.showPreviews}
          onChange={(value) => saveNotifications({ showPreviews: value }, 'Message previews')}
        />
      </Section>

      <Section title="Community digest">
        <Choice
          id="digest"
          label="Unread community activity by email"
          value={settings.digest}
          options={[
            { value: 'daily', title: 'Daily' },
            { value: 'weekly', title: 'Weekly, on Mondays' },
            { value: 'off', title: 'Off' },
          ]}
          onChange={(value) => saveNotifications({ digest: value }, 'Community digest')}
        />
        {notifications.email.suppressed ? (
          <p className="st-error">Email to {notifications.email.address} is paused because an earlier message bounced.</p>
        ) : null}
      </Section>

      <MutedChats account={account} announce={announce} />
    </>
  );
}
