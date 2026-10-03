import { useEffect, useRef, useState } from 'react';
import { EMOJI_GROUPS, QUICK_REACTIONS, reactionTitle } from './chatKitModel.js';

/**
 * Reactions  (chat kit)
 *
 *   ReactionChips    under a message: one chip per emoji with its count; yours
 *                    are highlighted; click to add or take back; hover says who
 *   ReactionPicker   six quick ones and "+" for the full set, like a phone
 */

export function ReactionChips({ reactions = [], onToggle, mine = false }) {
  if (!reactions.length) return null;
  return (
    <div className={`ck-chips${mine ? ' is-mine' : ''}`}>
      {reactions.map((reaction) => (
        <button
          key={reaction.emoji}
          type="button"
          className={`ck-chip${reaction.reacted ? ' is-on' : ''}`}
          title={reactionTitle(reaction)}
          aria-pressed={reaction.reacted}
          aria-label={`${reactionTitle(reaction)}. ${reaction.reacted ? 'Take back' : 'React too'}`}
          onClick={() => onToggle(reaction.emoji)}
        >
          <span aria-hidden="true">{reaction.emoji}</span>
          {reaction.count > 1 ? <span className="ck-chip__count">{reaction.count}</span> : null}
        </button>
      ))}
    </div>
  );
}

export function ReactionPicker({ onPick, onClose, align = 'start' }) {
  const [all, setAll] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    const onDown = (event) => !ref.current?.contains(event.target) && onClose();
    const onKey = (event) => event.key === 'Escape' && (event.stopPropagation(), onClose());
    document.addEventListener('pointerdown', onDown);
    document.addEventListener('keydown', onKey, true);
    ref.current?.querySelector('button')?.focus();
    return () => {
      document.removeEventListener('pointerdown', onDown);
      document.removeEventListener('keydown', onKey, true);
    };
  }, [onClose]);

  const pick = (emoji) => {
    onPick(emoji);
    onClose();
  };

  return (
    <div ref={ref} className={`ck-picker ck-picker--${align}${all ? ' is-all' : ''}`} role="dialog" aria-label="React with an emoji">
      <div className="ck-picker__quick">
        {QUICK_REACTIONS.map((emoji) => (
          <button key={emoji} type="button" onClick={() => pick(emoji)} aria-label={`React with ${emoji}`}>
            {emoji}
          </button>
        ))}
        <button type="button" className="ck-picker__more" onClick={() => setAll((value) => !value)} aria-expanded={all} aria-label="More emoji">
          {all ? '−' : '+'}
        </button>
      </div>
      {all ? (
        <div className="ck-picker__all">
          {EMOJI_GROUPS.map((group) => (
            <div key={group.label}>
              <p>{group.label}</p>
              <div className="ck-picker__grid">
                {group.emoji.map((emoji) => (
                  <button key={emoji} type="button" onClick={() => pick(emoji)} aria-label={`React with ${emoji}`}>
                    {emoji}
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
}
