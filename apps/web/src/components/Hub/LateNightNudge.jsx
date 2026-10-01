import { useState } from 'react';
import { isLateNight, morningLabel } from './hubModel.js';

/**
 * The late-night nudge  (Community, part 3)
 *
 * Between 22:00 and 8:00, under a reply, a new thread or a chat message:
 * "It's late — send at 8:00 instead?" The normal Send button still works;
 * this only offers a kinder option. The post waits on the server and is
 * sent at 8:00 in your time zone, and can be cancelled until then.
 *
 * `build()` returns what to schedule (or null when the form is not ready);
 * `onScheduled()` lets the form clear itself.
 */
export default function LateNightNudge({ hub, build, onScheduled, now = new Date() }) {
  const [state, setState] = useState({ phase: 'idle' });
  if (!isLateNight(now) && state.phase === 'idle') return null;

  if (state.phase === 'done') {
    return (
      <p className="hb-nudge is-done" role="status">
        <span aria-hidden="true">🌙</span> Scheduled for {morningLabel(state.item.sendAt)}.
        <button
          type="button"
          className="hb-link"
          onClick={async () => {
            await hub.cancelScheduled(state.item.scheduledId).catch(() => undefined);
            setState({ phase: 'idle' });
          }}
        >
          Cancel
        </button>
      </p>
    );
  }

  const schedule = async () => {
    const input = build();
    if (!input) return;
    setState({ phase: 'busy' });
    try {
      const item = await hub.schedule(input);
      onScheduled?.(item);
      setState({ phase: 'done', item });
    } catch (cause) {
      setState({ phase: 'error', error: cause?.detail ?? 'It could not be scheduled.' });
    }
  };

  return (
    <div className="hb-nudge">
      <span aria-hidden="true">🌙</span>
      <span className="hb-nudge__text">It’s late. This can wait until 8:00 — people are asleep, and you could be too.</span>
      <button type="button" className="btn btn--tiny" disabled={state.phase === 'busy'} onClick={schedule}>
        Send at 8:00
      </button>
      {state.phase === 'error' ? <span className="hb-error">{state.error}</span> : null}
    </div>
  );
}
