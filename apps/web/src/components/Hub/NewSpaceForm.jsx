import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ACCESS, KINDS, emptySpaceForm, spaceFormToInput, validateSpaceForm } from './hubModel.js';

/** Create a space: what kind, who gets in, and who sees the member list. */
export default function NewSpaceForm({ hub, canCreateClass, onCreated }) {
  const navigate = useNavigate();
  const [form, setForm] = useState(emptySpaceForm);
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const errors = validateSpaceForm(form, { canCreateClass });
  const shown = touched ? errors : {};
  const set = (patch) => setForm((current) => ({ ...current, ...patch }));

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length) return;
    setBusy(true);
    setError(null);
    try {
      const space = await hub.createSpace(spaceFormToInput(form));
      onCreated();
      navigate(`/community/spaces/${space.spaceId}`);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'The space was not created.');
    } finally {
      setBusy(false);
    }
  };

  const kinds = KINDS.filter((kind) => kind.value !== 'class' || canCreateClass);

  return (
    <form className="hb-form" onSubmit={submit} noValidate>
      <header className="hb-head">
        <h1>New space</h1>
        <p className="hb-muted">A place for a class, a subject or a goal. You become its owner and moderator.</p>
      </header>

      <fieldset className="hb-fieldset">
        <legend>What kind</legend>
        <div className="hb-options">
          {kinds.map((kind) => (
            <label key={kind.value} className={form.kind === kind.value ? 'hb-option is-on' : 'hb-option'}>
              <input type="radio" name="kind" value={kind.value} checked={form.kind === kind.value} onChange={() => set({ kind: kind.value })} />
              <span>
                <span className="hb-label">{kind.label}</span>
                <span className="hb-muted">{kind.hint}</span>
              </span>
            </label>
          ))}
        </div>
        {shown.kind ? <p className="hb-error">{shown.kind}</p> : null}
      </fieldset>

      <fieldset className="hb-fieldset">
        <legend>About it</legend>
        <div className="hb-row2">
          <label className="hb-field hb-field--emoji">
            <span className="hb-label">Emoji</span>
            <input className="hb-input" value={form.emoji} maxLength={4} placeholder="📚" onChange={(event) => set({ emoji: event.target.value })} />
          </label>
          <label className="hb-field">
            <span className="hb-label">Name</span>
            <input className="hb-input" value={form.name} maxLength={80} placeholder="e.g. Exam prep maths" onChange={(event) => set({ name: event.target.value })} aria-invalid={Boolean(shown.name)} autoFocus />
            {shown.name ? <span className="hb-error">{shown.name}</span> : null}
          </label>
        </div>
        <label className="hb-field">
          <span className="hb-label">Description</span>
          <textarea className="hb-input" rows={3} maxLength={500} value={form.description} placeholder="What is it for, and who should join?" onChange={(event) => set({ description: event.target.value })} />
        </label>
        <label className="hb-field">
          <span className="hb-label">Tags</span>
          <input className="hb-input" value={form.tags} placeholder="maths, exam prep" onChange={(event) => set({ tags: event.target.value })} />
          <span className="hb-muted">Up to five, separated by commas. People find spaces by them in Discover.</span>
          {shown.tags ? <span className="hb-error">{shown.tags}</span> : null}
        </label>
        {form.kind === 'study' ? (
          <label className="hb-field">
            <span className="hb-label">Ends on</span>
            <input className="hb-input" type="date" value={form.endsOn} onChange={(event) => set({ endsOn: event.target.value })} aria-invalid={Boolean(shown.endsOn)} />
            <span className="hb-muted">After this day the group becomes read-only, so it does not linger forever.</span>
            {shown.endsOn ? <span className="hb-error">{shown.endsOn}</span> : null}
          </label>
        ) : null}
      </fieldset>

      <fieldset className="hb-fieldset">
        <legend>Who gets in</legend>
        <div className="hb-options">
          {ACCESS.map((access) => (
            <label key={access.value} className={form.access === access.value ? 'hb-option is-on' : 'hb-option'}>
              <input type="radio" name="access" value={access.value} checked={form.access === access.value} onChange={() => set({ access: access.value })} />
              <span>
                <span className="hb-label">{access.label}</span>
                <span className="hb-muted">{access.hint}</span>
              </span>
            </label>
          ))}
        </div>
        {form.access === 'request' ? (
          <label className="hb-field">
            <span className="hb-label">A question for people who ask to join (optional)</span>
            <input className="hb-input" maxLength={200} value={form.joinQuestion} placeholder="e.g. Which class are you in?" onChange={(event) => set({ joinQuestion: event.target.value })} />
          </label>
        ) : null}
      </fieldset>

      <fieldset className="hb-fieldset">
        <legend>Privacy</legend>
        <label className="hb-check">
          <input type="checkbox" checked={form.memberList === 'moderators'} onChange={(event) => set({ memberList: event.target.checked ? 'moderators' : 'members' })} />
          <span>
            <span className="hb-label">Only moderators see who is in this space</span>
            <span className="hb-muted">For groups where being a member is itself private. Members still see the moderators.</span>
          </span>
        </label>
        <p className="hb-muted">Nobody ever sees members’ email addresses or phone numbers — only names and roles.</p>
      </fieldset>

      {error ? <p className="hb-error" role="alert">{error}</p> : null}
      <div className="hb-inline">
        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Creating…' : 'Create space'}
        </button>
      </div>
    </form>
  );
}
