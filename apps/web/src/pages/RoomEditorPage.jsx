import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { createProfileApi, createRoomsApi, useCore } from '@classroom/core-client';

import PeoplePicker from '../components/Rooms/PeoplePicker.jsx';
import RoomCard from '../components/Rooms/RoomCard.jsx';
import {
  REPEAT_OPTIONS,
  defaultForm,
  durationLabel,
  formToInput,
  recurrenceOf,
  roomToForm,
  validateForm,
} from '../components/Rooms/roomModel.js';
import { formatDate, formatTime } from '../lib/preferences.js';
import '../components/Rooms/rooms.css';

/**
 * Create or edit a room  (Rooms)
 *
 *   /rooms/new                 a new room (or a series of them)
 *   /rooms/new?from=<code>     a copy of an existing room, on a new date
 *   /rooms/<code>/edit         one date of a room, host only
 *
 * The card on the right is exactly what invitees will see, updated while you
 * type, and every change of time is checked against your other rooms before
 * you save — a clash is shown, not discovered.
 */

const browserZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

const zones = () => {
  try {
    return Intl.supportedValuesOf('timeZone');
  } catch {
    return [browserZone()];
  }
};

function Field({ label, hint, error, children, htmlFor }) {
  return (
    <div className="rm-field">
      <label className="rm-label" htmlFor={htmlFor}>
        {label}
      </label>
      {hint ? <p className="rm-hint">{hint}</p> : null}
      {children}
      {error ? <p className="rm-error">{error}</p> : null}
    </div>
  );
}

function Switch({ label, hint, checked, onChange }) {
  return (
    <label className="rm-switch-row">
      <span>
        <span className="rm-label">{label}</span>
        {hint ? <span className="rm-hint">{hint}</span> : null}
      </span>
      <input type="checkbox" role="switch" className="rm-switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

export default function RoomEditorPage() {
  const { code } = useParams();
  const [search] = useSearchParams();
  const fromCode = search.get('from');
  const editing = Boolean(code);
  const navigate = useNavigate();
  const { http, session } = useCore();
  const rooms = useMemo(() => createRoomsApi(http), [http]);
  const profiles = useMemo(() => createProfileApi(http), [http]);

  const [config, setConfig] = useState(null);
  const [form, setForm] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [preview, setPreview] = useState(null);
  const [touched, setTouched] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);

  const allZones = useMemo(zones, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [cfg, own, prefs] = await Promise.all([
          rooms.config(),
          profiles.getOwn().catch(() => null),
          profiles.getPreferences().catch(() => null),
        ]);
        let next = defaultForm({ timeZone: own?.timeZone || browserZone(), roomDefaults: prefs?.roomDefaults });
        const source = code ?? fromCode;
        if (source) {
          const room = await rooms.get(source);
          if (editing && !room.viewer.moderator) throw new Error('Only the host can edit this room.');
          next = roomToForm(room);
          if (!editing) {
            next = { ...next, title: `${room.title}`, startsAtLocal: defaultForm({ timeZone: room.timeZone }).startsAtLocal };
          }
        }
        if (!cancelled) {
          setConfig(cfg);
          setForm(next);
        }
      } catch (cause) {
        if (!cancelled) setLoadError(cause?.detail ?? cause?.message ?? 'The room could not be loaded.');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [rooms, profiles, code, fromCode, editing]);

  const set = (patch) => setForm((current) => ({ ...current, ...patch }));

  // Clash check and dates of a series, while the time is being chosen.
  const previewKey = form
    ? JSON.stringify([form.startsAtLocal, form.durationMinutes, form.timeZone, editing ? null : recurrenceOf(form)])
    : '';
  useEffect(() => {
    if (!form || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(form.startsAtLocal)) return undefined;
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      try {
        setPreview(
          await rooms.preview(
            {
              startsAtLocal: form.startsAtLocal,
              durationMinutes: Number(form.durationMinutes),
              timeZone: form.timeZone,
              recurrence: editing ? null : recurrenceOf(form),
              excludeCode: editing ? code : undefined,
            },
            controller.signal,
          ),
        );
      } catch (cause) {
        if (!controller.signal.aborted) setPreview({ error: cause?.detail ?? 'These dates cannot be used.' });
      }
    }, 350);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewKey, rooms, editing, code]);

  if (loadError) {
    return (
      <section className="page rm-page">
        <h1>{editing ? 'Edit room' : 'New room'}</h1>
        <p className="rm-error">{loadError}</p>
        <Link className="btn" to="/">
          Back
        </Link>
      </section>
    );
  }
  if (!form || !config) {
    return (
      <section className="page rm-page">
        <p className="muted">Loading…</p>
      </section>
    );
  }

  const errors = validateForm(form, config);
  const shown = touched ? errors : {};
  const firstOccurrence = preview?.occurrences?.[0];
  const startsAt = firstOccurrence?.startsAt ?? null;
  const endsAt = firstOccurrence?.endsAt ?? null;
  const doorsAt = startsAt ? new Date(new Date(startsAt).getTime() - form.earlyEntryMinutes * 60_000).toISOString() : null;
  const blocking = Boolean(preview?.conflicts?.length) || Boolean(preview?.inPast) || Boolean(preview?.error);

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length > 0 || blocking) return;
    setSaving(true);
    setSaveError(null);
    try {
      if (editing) {
        await rooms.update(code, formToInput(form, { editing: true }));
        navigate(`/rooms/${code}/lobby`, { replace: true, state: { saved: true } });
      } else {
        const result = await rooms.create(formToInput(form));
        navigate(`/rooms/${result.room.code}/lobby`, { state: { created: true, occurrences: result.occurrences } });
      }
    } catch (cause) {
      setSaveError(cause?.detail ?? cause?.message ?? 'The room was not saved.');
    } finally {
      setSaving(false);
    }
  };

  const previewRoom = {
    title: form.title,
    startsAt: startsAt ?? new Date().toISOString(),
    endsAt: endsAt ?? new Date().toISOString(),
    doorsOpenAt: doorsAt ?? new Date().toISOString(),
    phase: 'scheduled',
    capacity: form.capacityMode === 'limit' ? Number(form.capacity) : null,
    access: form.access,
    inviteeCount: form.invitees.length,
    hostName: session?.displayName ?? null,
    relation: 'host',
  };

  return (
    <section className="page rm-page">
      <header className="rm-head">
        <h1>{editing ? 'Edit room' : fromCode ? 'Copy room' : 'New room'}</h1>
        <Link to="/" className="btn btn--tiny">
          Cancel
        </Link>
      </header>

      <form className="rm-editor" onSubmit={submit} noValidate>
        <div className="rm-editor__form">
          <fieldset className="rm-section">
            <legend>What</legend>
            <Field label="Name" error={shown.title} htmlFor="rm-title">
              <input id="rm-title" className="rm-input" value={form.title} maxLength={120} placeholder="e.g. Maths revision" onChange={(e) => set({ title: e.target.value })} autoFocus={!editing} />
            </Field>
            <Field label="Description" hint="Optional. Shown in the invitation and the lobby." htmlFor="rm-desc">
              <textarea id="rm-desc" className="rm-input" rows={2} maxLength={2000} value={form.description} onChange={(e) => set({ description: e.target.value })} />
            </Field>
            <Field label="Agenda" hint="Optional. One point per line; everyone sees it in the lobby." htmlFor="rm-agenda">
              <textarea id="rm-agenda" className="rm-input" rows={3} maxLength={2000} value={form.agenda} onChange={(e) => set({ agenda: e.target.value })} />
            </Field>
          </fieldset>

          <fieldset className="rm-section">
            <legend>When</legend>
            <div className="rm-row">
              <Field label="Starts" error={shown.startsAtLocal} htmlFor="rm-start">
                <input id="rm-start" type="datetime-local" className="rm-input" step={300} value={form.startsAtLocal} onChange={(e) => set({ startsAtLocal: e.target.value })} />
              </Field>
              <Field label="Time zone" htmlFor="rm-zone">
                <select id="rm-zone" className="rm-input" value={form.timeZone} onChange={(e) => set({ timeZone: e.target.value })}>
                  {(allZones.includes(form.timeZone) ? allZones : [form.timeZone, ...allZones]).map((zone) => (
                    <option key={zone} value={zone}>
                      {zone.replace(/_/g, ' ')}
                    </option>
                  ))}
                </select>
              </Field>
            </div>
            <Field label="Length" error={shown.durationMinutes}>
              <div className="rm-chips">
                {config.duration.presets.map((minutes) => (
                  <button key={minutes} type="button" className={Number(form.durationMinutes) === minutes ? 'rm-pill is-on' : 'rm-pill'} onClick={() => set({ durationMinutes: minutes })}>
                    {durationLabel(minutes)}
                  </button>
                ))}
                <input type="number" className="rm-input rm-input--short" min={config.duration.min} max={config.duration.max} step={5} value={form.durationMinutes} onChange={(e) => set({ durationMinutes: e.target.value })} aria-label="Length in minutes" />
                <span className="rm-hint">min</span>
              </div>
            </Field>
            {!editing ? (
              <Field label="Repeat" error={shown.repeat}>
                <div className="rm-row">
                  <select className="rm-input" value={form.repeat} onChange={(e) => set({ repeat: e.target.value })} aria-label="Repeat">
                    {REPEAT_OPTIONS.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                  {form.repeat !== 'none' ? (
                    <>
                      <select className="rm-input" value={form.repeatEnd} onChange={(e) => set({ repeatEnd: e.target.value })} aria-label="Series ends">
                        <option value="count">for a number of dates</option>
                        <option value="until">until a date</option>
                      </select>
                      {form.repeatEnd === 'count' ? (
                        <input type="number" className="rm-input rm-input--short" min={2} max={52} value={form.repeatCount} onChange={(e) => set({ repeatCount: e.target.value })} aria-label="Number of dates" />
                      ) : (
                        <input type="date" className="rm-input" value={form.repeatUntil} onChange={(e) => set({ repeatUntil: e.target.value })} aria-label="Last date" />
                      )}
                    </>
                  ) : null}
                </div>
                <p className="rm-hint">Every date is its own room with its own link; change or cancel dates one by one.</p>
              </Field>
            ) : null}
          </fieldset>

          <fieldset className="rm-section">
            <legend>Doors</legend>
            <Field
              label={`Doors open ${form.earlyEntryMinutes} minutes before the start${doorsAt ? ` (${formatTime(doorsAt)})` : ''}`}
              hint="Before that, the link shows a countdown and a camera check. You and your co-hosts can come in 30 minutes early to prepare."
              error={shown.earlyEntryMinutes}
            >
              <input type="range" className="rm-range" min={config.earlyEntry.min} max={config.earlyEntry.max} step={1} value={form.earlyEntryMinutes} onChange={(e) => set({ earlyEntryMinutes: Number(e.target.value) })} aria-label="Minutes before the start" />
              <div className="rm-range__scale" aria-hidden="true">
                <span>{config.earlyEntry.min} min</span>
                <span>{config.earlyEntry.max} min</span>
              </div>
            </Field>
            <Field label="Late arrivals" hint="People who were already in can always come back, e.g. after a dropped connection.">
              <select className="rm-input" value={form.lateJoinMinutes ?? ''} onChange={(e) => set({ lateJoinMinutes: e.target.value === '' ? null : Number(e.target.value) })}>
                <option value="">Welcome until the end</option>
                <option value="0">Not after the start</option>
                {config.lateJoinOptions
                  .filter((minutes) => minutes)
                  .map((minutes) => (
                    <option key={minutes} value={minutes}>
                      Up to {minutes} minutes after the start
                    </option>
                  ))}
              </select>
            </Field>
          </fieldset>

          <fieldset className="rm-section">
            <legend>Who</legend>
            <div className="rm-choice">
              {[
                { value: 'invited', title: 'Only people I invite', hint: 'The link alone does not let anyone in.' },
                { value: 'link', title: 'Anyone in my organisation with the link', hint: 'Invite people as well, to send them a reminder.' },
              ].map((option) => (
                <label key={option.value} className={form.access === option.value ? 'rm-choice__option is-on' : 'rm-choice__option'}>
                  <input type="radio" name="access" value={option.value} checked={form.access === option.value} onChange={() => set({ access: option.value })} />
                  <span>
                    <span className="rm-label">{option.title}</span>
                    <span className="rm-hint">{option.hint}</span>
                  </span>
                </label>
              ))}
            </div>
            <PeoplePicker
              label="Invite"
              hint="They get an invitation and reminders a day and 10 minutes before."
              value={form.invitees}
              onChange={(invitees) => set({ invitees })}
              exclude={[session?.userId, ...form.cohosts.map((p) => p.userId)].filter(Boolean)}
              max={config.limits.invitees}
            />
            {shown.invitees ? <p className="rm-error">{shown.invitees}</p> : null}
            <PeoplePicker
              label="Co-hosts"
              hint="Can come in early, let people in, extend and end the room."
              value={form.cohosts}
              onChange={(cohosts) => set({ cohosts })}
              exclude={[session?.userId, ...form.invitees.map((p) => p.userId)].filter(Boolean)}
              max={config.limits.cohosts}
            />
            <Switch label="Let people in myself" hint="People knock in the lobby; you or a co-host admit them one by one or all at once." checked={form.approval} onChange={(approval) => set({ approval })} />
            <Field label="Seats" hint="Including you. Hosts and co-hosts always get in. When it is full, people can join a waiting list and get the next free seat." error={shown.capacity}>
              <div className="rm-row">
                <select className="rm-input" value={form.capacityMode} onChange={(e) => set({ capacityMode: e.target.value })} aria-label="Seat limit">
                  <option value="limit">Limit to</option>
                  <option value="plan">As many as allowed ({config.capacity.max})</option>
                </select>
                {form.capacityMode === 'limit' ? (
                  <input type="number" className="rm-input rm-input--short" min={config.capacity.min} max={config.capacity.max} value={form.capacity} onChange={(e) => set({ capacity: e.target.value })} aria-label="Number of seats" />
                ) : null}
              </div>
            </Field>
          </fieldset>

          <fieldset className="rm-section">
            <legend>In the room</legend>
            <Switch label="Participants join muted" hint="They can unmute themselves." checked={form.learnersJoinMuted} onChange={(learnersJoinMuted) => set({ learnersJoinMuted })} />
            <Switch label="Emoji reactions" checked={form.reactionsEnabled} onChange={(reactionsEnabled) => set({ reactionsEnabled })} />
            <Switch label="Participants may share their screen" hint="Off: only you and your co-hosts." checked={form.learnersMayShare} onChange={(learnersMayShare) => set({ learnersMayShare })} />
          </fieldset>
        </div>

        <aside className="rm-editor__side">
          <p className="rm-hint">What invitees will see</p>
          <RoomCard room={previewRoom} preview />

          {preview?.error ? <p className="rm-error">{preview.error}</p> : null}
          {preview?.inPast ? <p className="rm-error">That start time is in the past.</p> : null}
          {preview?.adjusted === 'gap' ? <p className="rm-hint">That time does not exist on that day (clock change); the room starts an hour later.</p> : null}
          {preview?.occurrences?.length > 1 ? (
            <details className="rm-dates">
              <summary>{preview.occurrences.length} dates</summary>
              <ul>
                {preview.occurrences.map((o) => (
                  <li key={o.startsAt}>
                    {formatDate(o.startsAt)} · {formatTime(o.startsAt)}
                  </li>
                ))}
              </ul>
            </details>
          ) : null}
          {preview?.conflicts?.length ? (
            <div className="rm-conflict" role="alert">
              <p className="rm-label">This clashes with your other plans</p>
              <ul>
                {preview.conflicts.slice(0, 5).map((c) => (
                  <li key={`${c.at}-${c.title}`}>
                    {formatDate(c.at)}: “{c.title}” {c.startsAt ? `${formatTime(c.startsAt)}–${formatTime(c.endsAt)}` : ''}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}

          {saveError ? <p className="rm-error" role="alert">{saveError}</p> : null}
          <button type="submit" className="btn btn--primary rm-submit" disabled={saving || (touched && (Object.keys(errors).length > 0 || blocking))}>
            {saving ? 'Saving…' : editing ? 'Save changes' : preview?.occurrences?.length > 1 ? `Create ${preview.occurrences.length} rooms` : 'Create room'}
          </button>
          {editing ? <p className="rm-hint">Invitees are told if the time changes.</p> : null}
        </aside>
      </form>
    </section>
  );
}
