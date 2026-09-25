import { useMemo, useState } from 'react';
import { Choice, Section } from './fields.jsx';
import { formatDate, formatTime } from '../../lib/preferences.js';

/**
 * Language & region. Language and time zone are stored on the account; date
 * and time format with the other preferences. Every option shows today's date
 * or the current time in that format, so nobody has to guess what "YYYY-MM-DD"
 * means.
 */

const LANGUAGES = [
  ['en', 'English'],
  ['de', 'Deutsch'],
  ['fr', 'Français'],
  ['es', 'Español'],
  ['it', 'Italiano'],
  ['nl', 'Nederlands'],
  ['pl', 'Polski'],
  ['pt', 'Português'],
  ['tr', 'Türkçe'],
];

const zones = () => {
  try {
    return Intl.supportedValuesOf('timeZone');
  } catch {
    return ['UTC'];
  }
};

export default function RegionSettings({ own, preferences, saveProfile, savePreferences }) {
  const now = new Date();
  const deviceZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const allZones = useMemo(zones, []);
  const [filter, setFilter] = useState('');
  const shownZones = useMemo(() => {
    const needle = filter.trim().toLowerCase().replace(/\s+/g, '_');
    const list = needle ? allZones.filter((z) => z.toLowerCase().includes(needle)) : allZones;
    return list.includes(own.timeZone) || !own.timeZone ? list : [own.timeZone, ...list];
  }, [allZones, filter, own.timeZone]);

  const region = preferences.region;

  return (
    <>
      <Section id="language" title="Language" hint="Sets how dates, times and numbers are written. The app's own texts are in English for now.">
        <select
          className="st-select"
          value={(own.locale ?? 'en').slice(0, 2)}
          onChange={(event) => saveProfile({ locale: event.target.value }, 'Language').catch(() => undefined)}
          aria-label="Language"
        >
          {LANGUAGES.map(([code, name]) => (
            <option key={code} value={code}>
              {name}
            </option>
          ))}
        </select>
      </Section>

      <Section id="timezone" title="Time zone" hint="Lesson times and reminders are shown in this time zone.">
        <div className="st-inline">
          <input
            className="st-input__field"
            type="search"
            placeholder="Filter, e.g. Berlin"
            value={filter}
            onChange={(event) => setFilter(event.target.value)}
            aria-label="Filter time zones"
          />
          <select
            className="st-select"
            value={own.timeZone ?? ''}
            onChange={(event) => saveProfile({ timeZone: event.target.value }, 'Time zone').catch(() => undefined)}
            aria-label="Time zone"
          >
            {shownZones.map((zone) => (
              <option key={zone} value={zone}>
                {zone.replace(/_/g, ' ')}
              </option>
            ))}
          </select>
        </div>
        {deviceZone && deviceZone !== own.timeZone ? (
          <button type="button" className="btn btn--tiny" onClick={() => saveProfile({ timeZone: deviceZone }, 'Time zone').catch(() => undefined)}>
            Use this device’s time zone ({deviceZone.replace(/_/g, ' ')})
          </button>
        ) : null}
      </Section>

      <Section title="Formats">
        <Choice
          id="date-format"
          label="Date format"
          value={region.dateFormat}
          options={[
            { value: 'auto', title: `From your language — ${formatDate(now, { ...region, dateFormat: 'auto' })}` },
            { value: 'day-month-year', title: `Day.Month.Year — ${formatDate(now, { ...region, dateFormat: 'day-month-year' })}` },
            { value: 'month-day-year', title: `Month/Day/Year — ${formatDate(now, { ...region, dateFormat: 'month-day-year' })}` },
            { value: 'year-month-day', title: `Year-Month-Day — ${formatDate(now, { ...region, dateFormat: 'year-month-day' })}` },
          ]}
          onChange={(value) => savePreferences('region', { dateFormat: value }, 'Date format')}
        />
        <Choice
          id="time-format"
          label="Time format"
          value={region.timeFormat}
          options={[
            { value: 'auto', title: `From your language — ${formatTime(now, { ...region, timeFormat: 'auto' })}` },
            { value: '24h', title: `24-hour — ${formatTime(now, { ...region, timeFormat: '24h' })}` },
            { value: '12h', title: `12-hour — ${formatTime(now, { ...region, timeFormat: '12h' })}` },
          ]}
          onChange={(value) => savePreferences('region', { timeFormat: value }, 'Time format')}
        />
      </Section>
    </>
  );
}
