import { useEffect, useState } from 'react';
import Avatar from './Avatar.jsx';
import { useModal } from './Dialogs.jsx';

/**
 * A person's profile  (Messages)
 *
 * What GET /profiles/:id answers for this viewer — the server already applies
 * the person's "who can see my profile" setting, so hidden parts simply do not
 * arrive. Used at the top of the details panel and in the dialog that opens
 * when you click someone's name or picture in a chat.
 */

const ROLE = { owner: 'Administrator', teacher: 'Teacher', learner: 'Learner' };

export function useProfile(profiles, userId, version = 0) {
  const [state, setState] = useState({ profile: null, error: null });
  useEffect(() => {
    if (!userId) return undefined;
    const controller = new AbortController();
    setState({ profile: null, error: null });
    profiles
      .get(userId, { signal: controller.signal })
      .then((profile) => setState({ profile, error: null }))
      .catch(() => !controller.signal.aborted && setState({ profile: null, error: 'This profile could not be loaded.' }));
    return () => controller.abort();
  }, [profiles, userId, version]);
  return state;
}

export function ProfileSummary({ person, profile, error, large = false }) {
  const name = profile?.displayName ?? person?.displayName ?? 'Unknown';
  return (
    <div className={large ? 'mx-profile mx-profile--large' : 'mx-profile'}>
      <Avatar name={name} url={profile?.avatarUrl ?? person?.avatarUrl ?? null} seed={person?.userId} size={large ? 88 : 64} />
      <div className="mx-profile__names">
        <strong className="mx-profile__name">{name}</strong>
        <span className="mx-muted">
          {[profile?.handle ? `@${profile.handle}` : null, ROLE[profile?.role] ?? null].filter(Boolean).join(' · ')}
        </span>
      </div>
      {profile?.headline ? <p className="mx-profile__headline">{profile.headline}</p> : null}
      {profile?.bio ? <p className="mx-profile__bio">{profile.bio}</p> : null}
      {profile?.links?.length ? (
        <ul className="mx-profile__links">
          {profile.links.map((link) => (
            <li key={link.url}>
              <a href={link.url} target="_blank" rel="noopener noreferrer">
                {link.label || link.url}
              </a>
            </li>
          ))}
        </ul>
      ) : null}
      {error ? <p className="mx-muted">{error}</p> : null}
      {!profile && !error ? <p className="mx-muted">Loading…</p> : null}
    </div>
  );
}

/** The dialog for anyone you click in a chat. "Message" opens (or creates) the chat with them. */
export function ProfileDialog({ person, profiles, selfUserId, onMessage, onClose }) {
  const ref = useModal(onClose);
  const { profile, error } = useProfile(profiles, person.userId);
  const isSelf = person.userId === selfUserId;
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState(null);
  const message = async () => {
    setBusy(true);
    setProblem(null);
    try {
      await onMessage(person);
      onClose();
    } catch (cause) {
      setProblem(cause?.detail ?? `You cannot write to ${person.displayName} right now.`);
      setBusy(false);
    }
  };
  return (
    <dialog ref={ref} className="app-dialog mx-dialog" aria-label={`Profile of ${person.displayName}`}>
      <div className="app-dialog__body">
        <ProfileSummary person={person} profile={profile} error={error} large />
        {profile && !isSelf && !profile.canMessage && profile.cannotMessageReason ? <p className="mx-muted">{profile.cannotMessageReason}</p> : null}
        {problem ? <p className="app-dialog__error" role="alert">{problem}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose}>
            Close
          </button>
          {!isSelf && onMessage ? (
            <button type="button" className="btn btn--primary" onClick={message} disabled={busy || (profile && !profile.canMessage)}>
              {busy ? 'Opening…' : 'Message'}
            </button>
          ) : null}
        </div>
      </div>
    </dialog>
  );
}
