import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { createProfileApi, useCore } from '@classroom/core-client';

/**
 * Pick people by name or @handle  (Rooms)
 *
 * Searches the organisation (GET /profiles/search — blocked people never
 * appear) and shows the chosen ones as removable chips. Keyboard: arrows to
 * move, Enter to add, Backspace on an empty field removes the last chip.
 */
export default function PeoplePicker({ label, hint, value, onChange, exclude = [], max = 300, placeholder = 'Name or @handle' }) {
  const { http } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const inputId = useId();
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [active, setActive] = useState(0);
  const [open, setOpen] = useState(false);
  const request = useRef(null);

  const taken = useMemo(() => new Set([...value.map((p) => p.userId), ...exclude]), [value, exclude]);

  useEffect(() => {
    const q = query.trim().replace(/^@/, '');
    if (q.length < 2) {
      setResults([]);
      return undefined;
    }
    const timer = window.setTimeout(async () => {
      request.current?.abort();
      const controller = new AbortController();
      request.current = controller;
      try {
        const { items } = await profiles.search({ q, limit: 8 }, controller.signal);
        setResults(items.filter((person) => !taken.has(person.userId)));
        setActive(0);
        setOpen(true);
      } catch {
        // A failed search just shows nothing; typing again retries.
      }
    }, 200);
    return () => window.clearTimeout(timer);
  }, [query, profiles, taken]);

  const add = (person) => {
    if (value.length >= max) return;
    onChange([...value, { userId: person.userId, displayName: person.displayName, handle: person.handle ?? null }]);
    setQuery('');
    setResults([]);
    setOpen(false);
  };

  const remove = (userId) => onChange(value.filter((person) => person.userId !== userId));

  const onKeyDown = (event) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setActive((index) => Math.min(index + 1, results.length - 1));
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setActive((index) => Math.max(index - 1, 0));
    } else if (event.key === 'Enter' && open && results[active]) {
      event.preventDefault();
      add(results[active]);
    } else if (event.key === 'Backspace' && !query && value.length) {
      remove(value[value.length - 1].userId);
    } else if (event.key === 'Escape') {
      setOpen(false);
    }
  };

  return (
    <div className="rm-field">
      <label className="rm-label" htmlFor={inputId}>
        {label}
      </label>
      {hint ? <p className="rm-hint">{hint}</p> : null}
      <div className="rm-people">
        {value.map((person) => (
          <span key={person.userId} className="rm-chip">
            {person.displayName}
            <button type="button" aria-label={`Remove ${person.displayName}`} onClick={() => remove(person.userId)}>
              ×
            </button>
          </span>
        ))}
        <input
          id={inputId}
          className="rm-people__input"
          value={query}
          placeholder={value.length ? '' : placeholder}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={onKeyDown}
          onFocus={() => results.length && setOpen(true)}
          onBlur={() => window.setTimeout(() => setOpen(false), 150)}
          role="combobox"
          aria-expanded={open}
          aria-autocomplete="list"
          disabled={value.length >= max}
        />
      </div>
      {open && results.length > 0 ? (
        <ul className="rm-suggest" role="listbox">
          {results.map((person, index) => (
            <li key={person.userId} role="option" aria-selected={index === active}>
              <button type="button" className={index === active ? 'is-active' : ''} onMouseDown={() => add(person)}>
                <span>{person.displayName}</span>
                {person.handle ? <span className="rm-hint">@{person.handle}</span> : null}
              </button>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
