/**
 * The controls along the bottom of a lesson.
 *
 * Every button reflects state the server confirmed, not what the user clicked:
 * useClassroom rolls an optimistic toggle back if the ack fails, so a mute that
 * the server rejected does not leave the button lying about it.
 *
 * Reactions: the host — and only the host — can switch emoji reactions off for
 * everyone else and back on ("Reactions: on / off"). While they are off, the
 * emoji buttons are disabled for everyone except the host, and the server
 * refuses them as well, so a modified client cannot send them anyway.
 */
export default function ControlBar({
  microphoneEnabled,
  cameraEnabled,
  handRaised,
  isScreenSharing,
  canScreenShare,
  screenTakenBy,
  reactionsEnabled = true,
  canToggleReactions = false,
  onToggleMicrophone,
  onToggleCamera,
  onToggleHand,
  onToggleScreenShare,
  onToggleReactions,
  onReact,
  onLeave,
}) {
  // Disabled rather than hidden: a button that vanishes teaches nothing, a
  // disabled one with a title says who has the lock.
  const shareBlocked = Boolean(screenTakenBy) && !isScreenSharing;
  const reactionsBlocked = !reactionsEnabled && !canToggleReactions;

  return (
    <footer className="controls">
      <button
        type="button"
        className={microphoneEnabled ? 'btn' : 'btn btn--off'}
        onClick={onToggleMicrophone}
        aria-pressed={!microphoneEnabled}
      >
        {microphoneEnabled ? 'Mute' : 'Unmute'}
      </button>

      <button
        type="button"
        className={cameraEnabled ? 'btn' : 'btn btn--off'}
        onClick={onToggleCamera}
        aria-pressed={!cameraEnabled}
      >
        {cameraEnabled ? 'Stop video' : 'Start video'}
      </button>

      <button
        type="button"
        className={handRaised ? 'btn btn--active' : 'btn'}
        onClick={onToggleHand}
        aria-pressed={handRaised}
      >
        {handRaised ? 'Lower hand' : 'Raise hand'}
      </button>

      {canScreenShare && (
        <button
          type="button"
          className={isScreenSharing ? 'btn btn--active' : 'btn'}
          onClick={onToggleScreenShare}
          disabled={shareBlocked}
          title={shareBlocked ? `${screenTakenBy} is sharing` : undefined}
        >
          {isScreenSharing ? 'Stop sharing' : 'Share screen'}
        </button>
      )}

      {canToggleReactions && (
        <button
          type="button"
          className={reactionsEnabled ? 'btn' : 'btn btn--off'}
          onClick={onToggleReactions}
          aria-pressed={!reactionsEnabled}
          title={
            reactionsEnabled
              ? 'Switch emoji reactions off for everyone else'
              : 'Switch emoji reactions back on for everyone'
          }
        >
          {reactionsEnabled ? 'Reactions: on' : 'Reactions: off'}
        </button>
      )}

      <div
        className="controls__reactions"
        title={reactionsBlocked ? 'The host has switched reactions off' : undefined}
      >
        {['👏', '👍', '❤️', '🎉'].map((emoji) => (
          <button
            key={emoji}
            type="button"
            className="btn btn--icon"
            onClick={() => onReact(emoji)}
            disabled={reactionsBlocked}
            aria-label={reactionsBlocked ? `React ${emoji} (switched off by the host)` : `React ${emoji}`}
          >
            {emoji}
          </button>
        ))}
      </div>

      <button type="button" className="btn btn--danger" onClick={onLeave}>
        Leave
      </button>
    </footer>
  );
}
