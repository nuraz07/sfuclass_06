import { Choice, Section, Toggle } from './fields.jsx';
import { formatDate } from '../../lib/preferences.js';

/**
 * Privacy: a plain-language summary first, then every setting it summarises.
 * Every line of the check-up is a consequence of one setting below and links
 * to it.
 */

const DM_OPTIONS = [
  { value: 'anyone', title: 'Anyone in your organisation' },
  {
    value: 'shared-context',
    title: 'People you share a course, space or lesson with',
    hint: 'Recommended. Classmates and the people in a running lesson with you.',
  },
  { value: 'nobody', title: 'Nobody', hint: 'Chats you already have keep working.' },
];

const VISIBILITY_OPTIONS = [
  { value: 'tenant', title: 'Everyone in your organisation', hint: 'Headline, about and links are on your profile card.' },
  { value: 'shared-only', title: 'People you share a course, space or lesson with', hint: 'Everyone else sees your name only.' },
  { value: 'private', title: 'Only your name', hint: 'Nobody sees your headline, about or links.' },
];

export const checkupLines = (privacy, blockCount) => [
  {
    anchor: 'dm',
    text:
      privacy.dmPolicy === 'anyone'
        ? 'Anyone in your organisation can start a private chat with you.'
        : privacy.dmPolicy === 'nobody'
          ? 'Nobody can start a new private chat with you — except teachers.'
          : 'People you share a course, space or lesson with can start a private chat with you.',
  },
  {
    anchor: 'visibility',
    text:
      privacy.visibility === 'private'
        ? 'Others see only your name.'
        : privacy.visibility === 'shared-only'
          ? 'Only people you share something with see your headline, about and links.'
          : 'Everyone in your organisation sees your headline, about and links.',
  },
  {
    anchor: 'presence',
    text: privacy.showPresence !== false ? 'Others can see when you are online.' : 'Your online status is hidden.',
  },
  {
    anchor: 'receipts',
    text:
      privacy.sendReadReceipts !== false
        ? 'People see when you have read their messages.'
        : 'Read receipts are off — both ways.',
  },
  {
    anchor: 'blocked',
    text: blockCount === 0 ? 'You have not blocked anyone.' : `You have blocked ${blockCount} ${blockCount === 1 ? 'person' : 'people'}.`,
  },
];

export default function PrivacySettings({ privacy, blocks, savePrivacy, unblock, onJump }) {
  return (
    <>
      <Section id="checkup" title="Privacy check-up" hint="Where you stand right now. Click a line to change it.">
        <ul className="st-checkup">
          {checkupLines(privacy, blocks.length).map((line) => (
            <li key={line.anchor}>
              <button type="button" className="st-checkup__line" onClick={() => onJump(line.anchor)}>
                {line.text}
              </button>
            </li>
          ))}
        </ul>
      </Section>

      <Section title="Private messages">
        <Choice
          id="dm"
          label="Who can send you private messages"
          hint="Teachers can always reach you, so a course can contact its participants. A block — for your account or for one lesson — stops everyone, teachers included."
          value={privacy.dmPolicy}
          options={DM_OPTIONS}
          onChange={(value) => savePrivacy({ dmPolicy: value }, 'Private messages')}
        />
      </Section>

      <Section title="Your profile">
        <Choice
          id="visibility"
          label="Who can see your profile"
          hint="Your name and role are always shown, so people know who they are talking to."
          value={privacy.visibility ?? 'tenant'}
          options={VISIBILITY_OPTIONS}
          onChange={(value) => savePrivacy({ visibility: value }, 'Profile visibility')}
        />
        <Toggle
          id="presence"
          label="Show when I am online"
          hint="Off: you appear offline to others wherever online status is shown."
          checked={privacy.showPresence !== false}
          onChange={(value) => savePrivacy({ showPresence: value }, 'Online status')}
        />
        <Toggle
          id="receipts"
          label="Send read receipts"
          hint="Off means you also stop seeing whether others have read your messages."
          checked={privacy.sendReadReceipts !== false}
          onChange={(value) => savePrivacy({ sendReadReceipts: value }, 'Read receipts')}
        />
      </Section>

      <Section
        id="blocked"
        title="Blocked people"
        hint="Blocked people cannot write to you and you cannot write to them. Blocks made only for one lesson end with that lesson and are not listed here."
      >
        {blocks.length === 0 ? <p className="st-hint">You have not blocked anyone.</p> : null}
        {blocks.map((block) => (
          <div key={block.blockedUserId} className="st-link">
            <span className="st-link__label">{block.profile.displayName}</span>
            <span className="st-link__url">{block.blockedAt ? `since ${formatDate(block.blockedAt)}` : ''}</span>
            <button type="button" className="btn btn--tiny" onClick={() => unblock(block)}>
              Unblock
            </button>
          </div>
        ))}
      </Section>
    </>
  );
}
