import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { isMutedNow } from '@classroom/core-client';
import { formatDate, formatTime } from '../../lib/preferences.js';
import Avatar from './Avatar.jsx';
import { ProfileSummary, useProfile } from './ProfileCard.jsx';
import { ConfirmDialog, ReportDialog } from './Dialogs.jsx';
import { MUTE_CHOICES, muteState, muteUntil } from './messengerModel.js';

/**
 * Details of a conversation  (Messages)
 *
 * Beside the chat on wide screens, as a sheet on narrow ones:
 *   the person      profile as they allow it to be seen
 *   quick actions   search in the chat, mute, pin
 *   notifications   mute for 1 h / 8 h / 1 day / 1 week / until turned on
 *   in common       the spaces you share (links into Community)
 *   about           since when, how many messages you can see
 *   privacy         block or unblock, report, delete the chat for you
 * For a group: its members, each opening their profile.
 */

function Section({ title, children }) {
  return (
    <section className="mx-panel__section">
      {title ? <h3>{title}</h3> : null}
      {children}
    </section>
  );
}

export default function ContactPanel({ conversation, title, other, self, api, profiles, rooms, onClose, onSearch, onOpenProfile, onDeleted, onBlockedChange }) {
  const [details, setDetails] = useState(null);
  const [profileVersion, setProfileVersion] = useState(0);
  const { profile, error } = useProfile(profiles, other?.userId ?? null, profileVersion);
  const [dialog, setDialog] = useState(null); // 'block' · 'unblock' · 'report' · 'delete'
  const [status, setStatus] = useState(null);
  const [showMute, setShowMute] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    setDetails(null);
    api
      .conversationDetails(conversation.conversationId, controller.signal)
      .then(setDetails)
      .catch(() => !controller.signal.aborted && setDetails({ sharedSpaces: [], messageCount: 0, startedAt: conversation.createdAt, failed: true }));
    return () => controller.abort();
  }, [api, conversation.conversationId, conversation.createdAt]);

  const run = async (fn, done) => {
    setStatus(null);
    try {
      await fn();
      if (done) setStatus({ text: done });
    } catch (cause) {
      setStatus({ error: true, text: cause?.detail ?? cause?.message ?? 'That did not work. Try again.' });
    }
  };

  const mute = muteState(conversation);
  const muted = isMutedNow(conversation);
  const pinned = Boolean(conversation.pinnedAt);
  const blocked = Boolean(profile?.isBlockedByViewer);

  const togglePin = () =>
    run(async () => {
      await api.pinConversation(conversation.conversationId, !pinned);
      await rooms.refresh();
    }, pinned ? 'Unpinned.' : 'Pinned to the top of your chats.');

  return (
    <aside className="mx-panel" aria-label="Chat details">
      <header className="mx-panel__head">
        <strong>{other ? 'Contact info' : 'Group info'}</strong>
        <button type="button" className="mx-iconbtn" onClick={onClose} aria-label="Close details">×</button>
      </header>

      <div className="mx-panel__scroll">
        <Section>
          {other ? (
            <ProfileSummary person={{ userId: other.userId, displayName: other.profile?.displayName ?? title, avatarUrl: other.profile?.avatarUrl }} profile={profile} error={error} large />
          ) : (
            <div className="mx-profile mx-profile--large">
              <Avatar name={title} seed={conversation.conversationId} size={88} />
              <strong className="mx-profile__name">{title}</strong>
              <span className="mx-muted">{conversation.participants.length} members</span>
            </div>
          )}
          <div className="mx-quick">
            <button type="button" onClick={onSearch}>
              <span aria-hidden="true">⌕</span>Search
            </button>
            <button type="button" onClick={() => setShowMute((value) => !value)} aria-expanded={showMute}>
              <span aria-hidden="true">{muted ? '🔕' : '🔔'}</span>
              {muted ? 'Muted' : 'Mute'}
            </button>
            <button type="button" onClick={togglePin} aria-pressed={pinned}>
              <span aria-hidden="true">📌</span>
              {pinned ? 'Unpin' : 'Pin'}
            </button>
          </div>
          {status ? <p className={status.error ? 'mx-error' : 'mx-ok'} role="status">{status.text}</p> : null}
        </Section>

        <Section title="Notifications">
          <p className="mx-muted">
            {mute
              ? mute.forever
                ? 'Muted until you turn notifications back on.'
                : `Muted until ${formatDate(mute.until)}, ${formatTime(mute.until)}.`
              : 'You are notified about new messages.'}
          </p>
          {muted ? (
            <button type="button" className="btn" onClick={() => run(() => rooms.unmute(conversation.conversationId), 'Notifications are on again.')}>
              Turn notifications back on
            </button>
          ) : null}
          {showMute || !muted ? (
            <div className="mx-options" role="group" aria-label="Mute">
              {MUTE_CHOICES.map((choice) => (
                <button
                  key={choice.id}
                  type="button"
                  onClick={() =>
                    run(async () => {
                      await rooms.mute(conversation.conversationId, muteUntil(choice));
                      setShowMute(false);
                    }, 'Muted.')
                  }
                >
                  {`Mute ${choice.label.charAt(0).toLowerCase()}${choice.label.slice(1)}`}
                </button>
              ))}
            </div>
          ) : null}
        </Section>

        {other ? (
          <Section title="In common">
            {details === null ? <p className="mx-muted">Loading…</p> : null}
            {details?.sharedSpaces?.length ? (
              <ul className="mx-spaces">
                {details.sharedSpaces.map((space) => (
                  <li key={space.spaceId}>
                    <Link to={`/community/spaces/${space.spaceId}`}>
                      <span aria-hidden="true">{space.emoji ?? '◎'}</span>
                      {space.name}
                    </Link>
                  </li>
                ))}
              </ul>
            ) : null}
            {details && !details.sharedSpaces?.length ? <p className="mx-muted">No spaces in common.</p> : null}
          </Section>
        ) : (
          <Section title="Members">
            <ul className="mx-members">
              {conversation.participants.map((participant) => (
                <li key={participant.userId}>
                  <button type="button" onClick={() => onOpenProfile({ userId: participant.userId, displayName: participant.profile?.displayName ?? 'Unknown', avatarUrl: participant.profile?.avatarUrl ?? null })}>
                    <Avatar name={participant.profile?.displayName} url={participant.profile?.avatarUrl} seed={participant.userId} size={34} />
                    <span>{participant.userId === self.userId ? 'You' : participant.profile?.displayName}</span>
                  </button>
                </li>
              ))}
            </ul>
          </Section>
        )}

        <Section title="About this chat">
          <dl className="mx-facts">
            <dt>Started</dt>
            <dd>{(details?.startedAt ?? conversation.createdAt) ? formatDate(details?.startedAt ?? conversation.createdAt) : '—'}</dd>
            <dt>Messages</dt>
            <dd>{details ? details.messageCount : '…'}</dd>
            {details?.editWindowMin ? (
              <>
                <dt>Editing</dt>
                <dd>Your messages can be edited for {details.editWindowMin} minutes</dd>
              </>
            ) : null}
          </dl>
        </Section>

        <Section title="Privacy and support">
          <div className="mx-danger-list">
            {other ? (
              blocked ? (
                <button type="button" onClick={() => setDialog('unblock')}>
                  Unblock {title}
                </button>
              ) : (
                <button type="button" className="is-danger" onClick={() => setDialog('block')}>
                  Block {title}
                </button>
              )
            ) : null}
            {other ? (
              <button type="button" className="is-danger" onClick={() => setDialog('report')}>
                Report {title}
              </button>
            ) : null}
            <button type="button" className="is-danger" onClick={() => setDialog('delete')}>
              Delete chat for me
            </button>
          </div>
        </Section>
      </div>

      {dialog === 'block' ? (
        <ConfirmDialog
          title={`Block ${title}?`}
          body={`${title} can no longer send you messages, and you cannot write to them. They are not told. You can unblock them here or in Settings → Privacy.`}
          confirmLabel="Block"
          danger
          onConfirm={async () => {
            await profiles.block({ userId: other.userId });
            setProfileVersion((v) => v + 1);
            onBlockedChange?.(true);
            setStatus({ text: `${title} is blocked.` });
          }}
          onClose={() => setDialog(null)}
        />
      ) : null}
      {dialog === 'unblock' ? (
        <ConfirmDialog
          title={`Unblock ${title}?`}
          body={`You can write to each other again, as their privacy settings allow.`}
          confirmLabel="Unblock"
          onConfirm={async () => {
            await profiles.unblock(other.userId);
            setProfileVersion((v) => v + 1);
            onBlockedChange?.(false);
            setStatus({ text: `${title} is no longer blocked.` });
          }}
          onClose={() => setDialog(null)}
        />
      ) : null}
      {dialog === 'report' ? (
        <ReportDialog person={{ userId: other.userId, displayName: title }} profiles={profiles} onDone={() => setStatus({ text: 'Thank you. The report was sent to the moderators.' })} onClose={() => setDialog(null)} />
      ) : null}
      {dialog === 'delete' ? (
        <ConfirmDialog
          title="Delete this chat for you?"
          body={`It disappears from your list only — ${title} keeps it. If a new message arrives, the chat comes back without the old messages.`}
          confirmLabel="Delete for me"
          danger
          onConfirm={async () => {
            await rooms.remove(conversation.conversationId);
            onDeleted();
          }}
          onClose={() => setDialog(null)}
        />
      ) : null}
    </aside>
  );
}
