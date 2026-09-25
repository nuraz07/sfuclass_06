import { useEffect, useId, useState } from 'react';

/**
 * Small building blocks shared by every settings tab. Each control saves on
 * its own — a switch when flipped, a text field when it loses focus or Enter
 * is pressed — so there is no Save button to forget.
 */

export function Section({ id, title, hint, children }) {
  return (
    <section className="st-section" id={id ? `setting-${id}` : undefined}>
      <h2 className="st-section__title">{title}</h2>
      {hint ? <p className="st-hint">{hint}</p> : null}
      <div className="st-section__body">{children}</div>
    </section>
  );
}

export function Toggle({ id, label, hint, checked, disabled, onChange }) {
  const inputId = useId();
  return (
    <div className="st-row" id={id ? `setting-${id}` : undefined}>
      <label className="st-toggle" htmlFor={inputId}>
        <span className="st-toggle__text">
          <span className="st-label">{label}</span>
          {hint ? <span className="st-hint">{hint}</span> : null}
        </span>
        <input
          id={inputId}
          type="checkbox"
          role="switch"
          className="st-switch"
          checked={Boolean(checked)}
          disabled={disabled}
          // Errors are reported by the page's notice; nothing to handle here.
          onChange={(event) => Promise.resolve(onChange(event.target.checked)).catch(() => undefined)}
        />
      </label>
    </div>
  );
}

export function Choice({ id, label, hint, value, options, disabled, onChange }) {
  const name = useId();
  return (
    <fieldset className="st-row st-choice" id={id ? `setting-${id}` : undefined}>
      <legend className="st-label">{label}</legend>
      {hint ? <p className="st-hint">{hint}</p> : null}
      <div className="st-choice__options">
        {options.map((option) => (
          <label key={option.value} className="st-choice__option" data-selected={value === option.value}>
            <input
              type="radio"
              name={name}
              value={option.value}
              checked={value === option.value}
              disabled={disabled}
              onChange={() => Promise.resolve(onChange(option.value)).catch(() => undefined)}
            />
            <span>
              <span className="st-choice__title">{option.title}</span>
              {option.hint ? <span className="st-hint">{option.hint}</span> : null}
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

/** A text field that saves when it loses focus or Enter is pressed, and only if it changed. */
export function TextField({ id, label, hint, value, placeholder, maxLength, multiline = false, prefix, onSave }) {
  const inputId = useId();
  const [draft, setDraft] = useState(value ?? '');
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => setDraft(value ?? ''), [value]);

  const commit = async () => {
    const next = draft.trim();
    if (next === (value ?? '').trim()) return;
    setBusy(true);
    setError(null);
    try {
      await onSave(next);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not saved.');
    } finally {
      setBusy(false);
    }
  };

  const Input = multiline ? 'textarea' : 'input';

  return (
    <div className="st-row" id={id ? `setting-${id}` : undefined}>
      <label className="st-label" htmlFor={inputId}>
        {label}
      </label>
      {hint ? <p className="st-hint">{hint}</p> : null}
      <div className="st-input">
        {prefix ? <span className="st-input__prefix">{prefix}</span> : null}
        <Input
          id={inputId}
          className="st-input__field"
          value={draft}
          placeholder={placeholder}
          maxLength={maxLength}
          rows={multiline ? 4 : undefined}
          disabled={busy}
          aria-invalid={Boolean(error)}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={commit}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !multiline) event.currentTarget.blur();
            if (event.key === 'Escape') {
              setDraft(value ?? '');
              setError(null);
            }
          }}
        />
      </div>
      {multiline && maxLength ? (
        <p className="st-hint st-count">
          {draft.length} / {maxLength}
        </p>
      ) : null}
      {error ? <p className="st-error">{error}</p> : null}
    </div>
  );
}
