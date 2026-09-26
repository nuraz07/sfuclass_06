import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { createRoomsApi, useCore } from '@classroom/core-client';
import { isRoomCode } from '../../lib/useRoomGate.js';
import { countdown } from './roomModel.js';
import './rooms.css';

/**
 * Time and door control inside a scheduled room  (Rooms)
 *
 * A quiet clock in the header; five minutes before the end a notice for
 * everyone, and for hosts: more time, end for everyone, and the people
 * knocking in the lobby. Renders nothing for rooms that were not scheduled.
 */
export default function RoomClock({ roomId, canModerate }) {
  const { http } = useCore();
  const rooms = useMemo(() => createRoomsApi(http), [http]);
  const [room, setRoom] = useState(null);
  const [knocks, setKnocks] = useState([]);
  const [skew, setSkew] = useState(0);
  const [now, setNow] = useState(Date.now());
  const [notice, setNotice] = useState(null);
  const scheduled = isRoomCode(roomId);

  const load = useCallback(async () => {
    if (!scheduled) return;
    try {
      const next = await rooms.get(roomId);
      setSkew(new Date(next.serverTime).getTime() - Date.now());
      setRoom(next);
      if (next.viewer.moderator && next.approval) setKnocks((await rooms.knocks(roomId)).items);
    } catch {
      // Keep the last known state; the next poll tries again.
    }
  }, [rooms, roomId, scheduled]);

  useEffect(() => {
    load();
    const poll = window.setInterval(load, canModerate ? 10_000 : 30_000);
    const tick = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => {
      window.clearInterval(poll);
      window.clearInterval(tick);
    };
  }, [load, canModerate]);

  if (!scheduled || !room) return null;

  const left = new Date(room.endsAt).getTime() - (now + skew);
  const endingSoon = left > 0 && left <= 5 * 60_000;
  const moderator = room.viewer.moderator;

  const extend = async (minutes) => {
    try {
      await rooms.extend(roomId, minutes);
      setNotice(`${minutes} more minutes.`);
      await load();
    } catch (cause) {
      setNotice(cause?.detail ?? 'The room could not be extended.');
    }
    window.setTimeout(() => setNotice(null), 4_000);
  };

  const endNow = async () => {
    if (!window.confirm('End the room for everyone now?')) return;
    await rooms.end(roomId).catch(() => undefined);
  };

  const admit = async (userIds = []) => {
    await rooms.admit(roomId, userIds).catch(() => undefined);
    await load();
  };

  return (
    <>
      <span className={endingSoon ? 'rm-clock is-warn' : 'rm-clock'} title={`Ends at ${new Date(room.endsAt).toLocaleTimeString()}`}>
        {left > 0 ? `Ends ${countdown(left)}` : 'Ended'}
      </span>
      {moderator && knocks.length > 0 ? (
        <span className="rm-knocks" role="status">
          {knocks.length === 1 ? `${knocks[0].displayName} wants to join` : `${knocks.length} people want to join`}
          {knocks.length === 1 ? (
            <button type="button" className="btn btn--tiny btn--primary" onClick={() => admit([knocks[0].userId])}>
              Admit
            </button>
          ) : (
            <button type="button" className="btn btn--tiny btn--primary" onClick={() => admit([])}>
              Admit all
            </button>
          )}
          <Link className="btn btn--tiny" to={`/rooms/${roomId}/lobby`} target="_blank" rel="noreferrer">
            Details
          </Link>
        </span>
      ) : null}
      {endingSoon || (moderator && left <= 10 * 60_000 && left > 0) ? (
        <div className={endingSoon ? 'rm-ending is-warn' : 'rm-ending'} role="status">
          <span>{endingSoon ? `This room closes ${countdown(left)}.` : `The room ends ${countdown(left)}.`}</span>
          {moderator ? (
            <span className="rm-inline">
              {[5, 10, 15].map((minutes) => (
                <button key={minutes} type="button" className="btn btn--tiny" onClick={() => extend(minutes)}>
                  +{minutes} min
                </button>
              ))}
              <button type="button" className="btn btn--tiny btn--danger" onClick={endNow}>
                End for everyone
              </button>
            </span>
          ) : null}
          {notice ? <span className="rm-hint">{notice}</span> : null}
        </div>
      ) : null}
    </>
  );
}
