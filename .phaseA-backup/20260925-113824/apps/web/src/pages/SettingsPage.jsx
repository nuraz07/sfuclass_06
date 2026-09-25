import { useEffect, useMemo, useState } from 'react';
import { createProfileApi, useCore } from '@classroom/core-client';
import '../components/Chat/chatRooms.css';

/**
 * Settings  (F6)
 *
 * Private messages
 *   One switch. Off means nobody can start a private chat with you — with one
 *   exception, by design: teachers can still reach you, so a course can always
 *   contact its participants. Chats you already have keep working.
 *   On restores the default: people you share a course, a space or a running
 *   lesson with may write to you.
 *
 * Blocked people
 *   Account-wide blocks, with a way to undo each one. Blocking someone only for
 *   a lesson happens inside that lesson and ends with it; it is not listed here.
 *
 * Every change is saved immediately and confirmed; a change the server refused
 * is put back, so the switch never shows something that is not true.
 */
export default function SettingsPage() {
  const { http } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);

  const [privacy, setPrivacy] = useState(null);
  const [blocks, setBlocks] = useState([]);
  const [status, setStatus] = useState(null);
  const [pending, setPending] = useState(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([profiles.getPrivacy(), profiles.listBlocks({ limit: 100 })])
      .then(([p, b]) => {
        if (cancelled) return;
        setPrivacy(p);
        setBlocks(b.items);
      })
      .catch(() => !cancelled && setStatus({ error: true, text: 'Your settings could not be loaded.' }));
    return () => {
      cancelled = true;
    };
  }, [profiles]);

  const receivesMessages = privacy ? privacy.dmPolicy !== 'nobody' : true;

  const setReceivesMessages = async (on) => {
    const previous = privacy;
    setPrivacy({ ...privacy, dmPolicy: on ? 'shared-context' : 'nobody' });
    setPending('dm');
    setStatus(null);
    try {
      setPrivacy(await profiles.updatePrivacy({ dmPolicy: on ? 'shared-context' : 'nobody' }));
      setStatus({ text: on ? 'Private messages are on.' : 'Private messages are off.' });
    } catch {
      setPrivacy(previous);
      setStatus({ error: true, text: 'That change was not saved. Try again.' });
    } finally {
      setPending(null);
    }
  };

  const unblock = async (block) => {
    setPending(block.blockedUserId);
    setStatus(null);
    try {
      await profiles.unblock(block.blockedUserId);
      setBlocks((current) => current.filter((b) => b.blockedUserId !== block.blockedUserId));
      setStatus({ text: `${block.profile.displayName} is no longer blocked.` });
    } catch {
      setStatus({ error: true, text: 'That person could not be unblocked. Try again.' });
    } finally {
      setPending(null);
    }
  };

  return (
    <section className="page settings">
      <h1>Settings</h1>

      {!privacy && !status ? <p className="muted">Loading your settings…</p> : null}

      {privacy ? (
        <div className="settings__section">
          <h2>Private messages</h2>
          <label className="settings__switch">
            <input
              type="checkbox"
              checked={receivesMessages}
              disabled={pending === 'dm'}
              onChange={(event) => setReceivesMessages(event.target.checked)}
            />
            <span>
              <strong>Receive private messages</strong>
              <p className="settings__hint">
                {receivesMessages
                  ? 'On: people you share a course, a space or a running lesson with can start a private chat with you.'
                  : 'Off: nobody can start a new private chat with you. Teachers can still reach you, so a course can always contact its participants. Chats you already have keep working.'}
              </p>
            </span>
          </label>
        </div>
      ) : null}

      {privacy ? (
        <div className="settings__section">
          <h2>Blocked people</h2>
          <p className="settings__hint">
            Blocked people cannot write to you and you cannot write to them. Blocks made only for one lesson end with
            that lesson and are not listed here.
          </p>
          {blocks.length === 0 ? <p className="muted">You have not blocked anyone.</p> : null}
          {blocks.map((block) => (
            <div key={block.blockedUserId} className="settings__row">
              <span>{block.profile.displayName}</span>
              <button
                type="button"
                className="btn btn--tiny"
                disabled={pending === block.blockedUserId}
                onClick={() => unblock(block)}
              >
                Unblock
              </button>
            </div>
          ))}
        </div>
      ) : null}

      {status ? (
        <p className={status.error ? 'rooms-status rooms-status--error' : 'rooms-status'} aria-live="polite">
          {status.text}
        </p>
      ) : null}
    </section>
  );
}
