import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { createRoomsApi, useCore } from '@classroom/core-client';

import RoomCard from '../components/Rooms/RoomCard.jsx';
import { destinationFor } from '../components/Rooms/roomModel.js';
import { onUserEvent } from '../lib/userEvents.js';
import '../components/Rooms/rooms.css';

/**
 * Dashboard  (Rooms)
 *
 * "New room" first, then your rooms — running and upcoming ones, or the
 * past ones — and a box to join by code or link. The course and lesson lists
 * join this page when F3 lands.
 */

export default function DashboardPage() {
  const navigate = useNavigate();
  const core = useCore();
  const { http, session } = core;
  const rooms = useMemo(() => createRoomsApi(http), [http]);

  const [when, setWhen] = useState('upcoming');
  const [items, setItems] = useState(null);
  const [failed, setFailed] = useState(false);
  const [joinText, setJoinText] = useState('');

  const load = useCallback(async () => {
    try {
      setItems((await rooms.mine(when)).items);
      setFailed(false);
    } catch {
      setFailed(true);
      setItems((current) => current ?? []);
    }
  }, [rooms, when]);

  useEffect(() => {
    setItems(null);
    load();
    const timer = window.setInterval(load, 60_000);
    return () => window.clearInterval(timer);
  }, [load]);

  // A new invitation arrives as a notification; show it without a reload.
  useEffect(
    () =>
      onUserEvent(core, 'notification:new', (payload) => {
        if (String(payload?.notification?.kind ?? '').startsWith('session.')) load();
      }),
    [core, load],
  );

  const destination = destinationFor(joinText);
  const live = (items ?? []).filter((room) => room.phase === 'live' || room.phase === 'doors-open');
  const later = (items ?? []).filter((room) => room.phase !== 'live' && room.phase !== 'doors-open');

  return (
    <section className="page rm-page">
      <header className="rm-head">
        <div>
          <h1>{session?.displayName ? `Hello, ${session.displayName.split(' ')[0]}` : 'Dashboard'}</h1>
          <p className="muted">Your rooms, and a way into anyone else’s.</p>
        </div>
        <Link className="btn btn--primary" to="/rooms/new">
          + New room
        </Link>
      </header>

      <div className="rm-dash">
        <div className="rm-dash__main">
          <div className="rm-tabs" role="tablist">
            {[
              ['upcoming', 'Upcoming'],
              ['past', 'Past'],
            ].map(([value, label]) => (
              <button key={value} type="button" role="tab" aria-selected={when === value} className={when === value ? 'rm-tab is-on' : 'rm-tab'} onClick={() => setWhen(value)}>
                {label}
              </button>
            ))}
          </div>

          {items === null ? <p className="muted">Loading…</p> : null}
          {failed ? <p className="rm-error">Your rooms could not be loaded.</p> : null}
          {items?.length === 0 && !failed ? (
            <div className="rm-empty">
              <p>{when === 'upcoming' ? 'No rooms planned.' : 'No rooms in the last 90 days.'}</p>
              {when === 'upcoming' ? (
                <Link className="btn" to="/rooms/new">
                  Plan your first room
                </Link>
              ) : null}
            </div>
          ) : null}

          {live.length > 0 ? (
            <>
              <h2 className="rm-subhead">Now</h2>
              <div className="rm-cards">
                {live.map((room) => (
                  <RoomCard key={room.code} room={room} to={`/rooms/${room.code}/lobby`} />
                ))}
              </div>
            </>
          ) : null}
          {later.length > 0 ? (
            <>
              {live.length > 0 ? <h2 className="rm-subhead">Later</h2> : null}
              <div className="rm-cards">
                {later.map((room) => (
                  <RoomCard key={room.code} room={room} to={`/rooms/${room.code}/lobby`} />
                ))}
              </div>
            </>
          ) : null}
        </div>

        <aside className="card rm-join">
          <h2>Join with a code or link</h2>
          <label htmlFor="rm-join">Room code or link</label>
          <input
            id="rm-join"
            value={joinText}
            onChange={(event) => setJoinText(event.target.value)}
            onKeyDown={(event) => event.key === 'Enter' && destination && navigate(destination)}
            placeholder="kqz-7hfd-2mx"
            autoComplete="off"
          />
          <button type="button" className="btn btn--primary" disabled={!destination} onClick={() => navigate(destination)}>
            Join
          </button>
        </aside>
      </div>
    </section>
  );
}
