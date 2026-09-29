import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { countdown } from '../Rooms/roomModel.js';

/**
 * Rooms of a space  (Community, part 2)
 *
 * "Open a drop-in room" starts a study room for the space, now, for an hour —
 * with the rooms feature's doors, lobby, seats and closing time — and tells
 * the members. If one is already open, you are taken to it: one study hall at
 * a time. Only the space's members can enter.
 */
export default function SpaceRooms({ hub, space, onChanged }) {
  const navigate = useNavigate();
  const [items, setItems] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      setItems((await hub.rooms(space.spaceId)).items);
    } catch {
      setItems([]);
    }
  }, [hub, space.spaceId]);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 30_000);
    return () => window.clearInterval(timer);
  }, [load]);

  const dropIn = async () => {
    setBusy(true);
    setError(null);
    try {
      const { room } = await hub.dropIn(space.spaceId);
      onChanged?.();
      navigate(`/rooms/${room.code}/lobby`);
    } catch (cause) {
      setError(cause?.detail ?? 'The room could not be opened.');
      setBusy(false);
    }
  };

  const now = Date.now();

  return (
    <div>
      <div className="hb-dropin">
        <div>
          <p className="hb-label">Study together, right now</p>
          <p className="hb-muted">
            A drop-in room for {space.name}, open for an hour. Everyone joins muted; only members of this space can enter.
          </p>
        </div>
        {space.me?.postingBlocked ? null : (
          <button type="button" className="btn btn--primary" disabled={busy} onClick={dropIn}>
            {busy ? 'Opening…' : 'Open a drop-in room'}
          </button>
        )}
      </div>
      {error ? <p className="hb-error">{error}</p> : null}

      {items === null ? <p className="hb-muted">Loading…</p> : null}
      {items?.length === 0 ? <p className="hb-muted">No rooms planned in this space.</p> : null}
      <ul className="hb-roomlist">
        {(items ?? []).map((room) => {
          const live = room.phase === 'live' || room.phase === 'doors-open';
          return (
            <li key={room.code} className={live ? 'hb-roomitem is-live' : 'hb-roomitem'}>
              <span className={live ? 'hb-livedot' : 'hb-livedot is-off'} aria-hidden="true" />
              <span className="hb-roomitem__text">
                <span className="hb-label">{room.title}</span>
                <span className="hb-muted">
                  {live
                    ? `${room.here} here, closes ${countdown(new Date(room.endsAt).getTime() - now)}`
                    : `Starts ${countdown(new Date(room.startsAt).getTime() - now)}`}
                  {room.hostName ? `, opened by ${room.hostName}` : ''}
                </span>
              </span>
              <Link className={live ? 'btn btn--primary' : 'btn'} to={`/rooms/${room.code}/lobby`}>
                {live ? 'Join' : 'Details'}
              </Link>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
