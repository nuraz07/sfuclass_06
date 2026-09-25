import { useState } from 'react';
import { Section, TextField } from './fields.jsx';

/**
 * Profile: how you appear to others, and a preview of exactly that.
 *
 * "View as" applies the same rules the server applies when someone opens your
 * profile card (profile.routes → Profile.applyVisibility, and
 * ConversationService.canMessage for the Message button), to your current
 * settings — so what it shows is what they get.
 */

const VIEWERS = [
  { id: 'classmate', label: 'A classmate', hint: 'someone who shares a course, space or lesson with you' },
  { id: 'teacher', label: 'A teacher', hint: 'a teacher in your organisation' },
  { id: 'other', label: 'Someone else', hint: 'anyone else in your organisation' },
];

export const previewFor = (viewer, { privacy }) => {
  const shares = viewer === 'classmate' || viewer === 'teacher';
  const visibility = privacy.visibility ?? 'tenant';
  const seesDetails = visibility === 'tenant' || (visibility === 'shared-only' && shares);

  let canMessage;
  if (viewer === 'teacher') canMessage = true;
  else if (privacy.dmPolicy === 'anyone') canMessage = true;
  else if (privacy.dmPolicy === 'nobody') canMessage = false;
  else canMessage = viewer === 'classmate';

  return { seesDetails, canMessage, seesOnline: privacy.showPresence !== false };
};

function ViewAsPreview({ own, privacy }) {
  const [viewer, setViewer] = useState('classmate');
  const view = previewFor(viewer, { privacy });

  return (
    <Section id="view-as" title="View your profile as someone else" hint="Exactly what they see when they click your name.">
      <div className="st-segmented" role="tablist" aria-label="Viewer">
        {VIEWERS.map((v) => (
          <button
            key={v.id}
            type="button"
            role="tab"
            aria-selected={viewer === v.id}
            className={viewer === v.id ? 'st-segmented__item is-active' : 'st-segmented__item'}
            onClick={() => setViewer(v.id)}
            title={v.hint}
          >
            {v.label}
          </button>
        ))}
      </div>

      <div className="st-card" aria-live="polite">
        <div className="st-card__identity">
          <span className="st-avatar" aria-hidden="true">
            {(own.displayName ?? '?').charAt(0).toUpperCase()}
          </span>
          <div>
            <p className="st-card__name">{own.displayName}</p>
            <p className="st-hint">
              {own.handle ? `@${own.handle} · ` : ''}
              {own.role}
              {view.seesOnline ? ' · online status shown' : ' · online status hidden'}
            </p>
          </div>
        </div>

        {view.seesDetails ? (
          <>
            {own.headline ? <p className="st-card__headline">{own.headline}</p> : null}
            {own.bio ? <p className="st-card__bio">{own.bio}</p> : null}
            {own.links?.length ? (
              <ul className="st-card__links">
                {own.links.map((link) => (
                  <li key={link.url}>{link.label}</li>
                ))}
              </ul>
            ) : null}
            {!own.headline && !own.bio && !own.links?.length ? (
              <p className="st-hint">Nothing else to show yet — add a headline or something about you.</p>
            ) : null}
          </>
        ) : (
          <p className="st-hint">Only your name is shown. Headline, about and links are hidden from them.</p>
        )}

        <p className={view.canMessage ? 'st-card__verdict' : 'st-card__verdict st-card__verdict--no'}>
          {view.canMessage ? 'They can send you a private message.' : 'They cannot send you a private message.'}
        </p>
      </div>
    </Section>
  );
}

export default function ProfileSettings({ own, privacy, saveProfile }) {
  const links = own.links ?? [];

  const saveLinks = (next) => saveProfile({ links: next }, 'Links');

  return (
    <>
      <Section title="How others see you" hint="Changes are saved when you leave a field.">
        <TextField
          id="display-name"
          label="Display name"
          value={own.displayName}
          maxLength={80}
          onSave={(value) => {
            if (!value) throw new Error('A name cannot be empty.');
            return saveProfile({ displayName: value }, 'Display name');
          }}
        />
        <TextField
          id="handle"
          label="Handle"
          hint="Used for @mentions. 3–32 lowercase letters, digits or underscores."
          prefix="@"
          value={own.handle}
          maxLength={32}
          onSave={(value) => saveProfile({ handle: value.toLowerCase() }, 'Handle')}
        />
        <TextField
          id="headline"
          label="Headline"
          hint="One line under your name, e.g. “Maths teacher” or “Studying biology”."
          value={own.headline}
          maxLength={140}
          onSave={(value) => saveProfile({ headline: value || null }, 'Headline')}
        />
        <TextField
          id="bio"
          label="About me"
          value={own.bio}
          maxLength={2000}
          multiline
          onSave={(value) => saveProfile({ bio: value || null }, 'About me')}
        />
      </Section>

      <Section id="links" title="Links" hint="Up to five, e.g. a portfolio or a course website.">
        {links.map((link, index) => (
          <div key={`${link.url}-${index}`} className="st-link">
            <span className="st-link__label">{link.label}</span>
            <span className="st-link__url">{link.url}</span>
            <button
              type="button"
              className="btn btn--tiny"
              onClick={() => saveLinks(links.filter((_, i) => i !== index)).catch(() => undefined)}
            >
              Remove
            </button>
          </div>
        ))}
        {links.length < 5 ? <AddLink onAdd={(link) => saveLinks([...links, link])} /> : null}
      </Section>

      <ViewAsPreview own={own} privacy={privacy} />
    </>
  );
}

function AddLink({ onAdd }) {
  const [label, setLabel] = useState('');
  const [url, setUrl] = useState('');
  const [error, setError] = useState(null);

  const add = async (event) => {
    event.preventDefault();
    setError(null);
    let normalised = url.trim();
    if (normalised && !/^https?:\/\//i.test(normalised)) normalised = `https://${normalised}`;
    try {
      // eslint-disable-next-line no-new
      new URL(normalised);
    } catch {
      setError('That does not look like a web address.');
      return;
    }
    try {
      await onAdd({ label: label.trim() || new URL(normalised).hostname, url: normalised });
      setLabel('');
      setUrl('');
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not saved.');
    }
  };

  return (
    <form className="st-link-form" onSubmit={add}>
      <input className="st-input__field" placeholder="Label (optional)" value={label} maxLength={40} onChange={(e) => setLabel(e.target.value)} aria-label="Link label" />
      <input className="st-input__field" placeholder="https://…" value={url} onChange={(e) => setUrl(e.target.value)} aria-label="Link address" />
      <button type="submit" className="btn btn--tiny" disabled={!url.trim()}>
        Add link
      </button>
      {error ? <p className="st-error">{error}</p> : null}
    </form>
  );
}
