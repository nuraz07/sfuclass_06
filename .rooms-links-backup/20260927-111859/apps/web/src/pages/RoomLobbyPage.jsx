import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, Navigate, useLocation, useNavigate, useParams } from 'react-router-dom';
import { createRoomsApi, useCore } from '@classroom/core-client';

import DeviceCheck from '../components/Rooms/DeviceCheck.jsx';
import { countdown, durationLabel, phaseLabel, reasonText, timeInZones } from '../components/Rooms/roomModel.js';
import { formatDate, formatTime } from '../lib/preferences.js';
import { onUserEvent } from '../lib/userEvents.js';
import '../components/Rooms/rooms.css';

/**
 * The lobby of a room  (Rooms)  —  /rooms/<code>/lobby
 *
 * Where a room link lands. Before the doors open: a countdown, what the room
 * is about, and a camera check. When they open: "Enter room". Around that,
 * the lobby handles everything the room's settings ask for — knocking when a
 * host lets people in, the waiting list when every seat is taken (a freed
 * seat is held for you for two minutes) — and, for hosts, sharing, the
 * knock queue, editing and cancelling.
 *
 * What the server allows is the truth (GET /scheduled-rooms/<code>, and the
 * socket join checks again); the clock here is only corrected by the
 * server's time, never trusted on its own.
 */

const viewerZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

const copy = async (text) => {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
};

function useNow(intervalMs = 1_000) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(timer);
  }, [intervalMs]);
  return now;
}

function SharePanel({ room, rooms, highlight }) {
  const [copied, setCopied] = useState(false);
  const [qr, setQr] = useState(null);

  useEffect(() => {
    let cancelled = false;
    rooms
      .qr(room.code)
      .then((result) => !cancelled && setQr(result.dataUrl))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [rooms, room.code]);

  const downloadCalendar = async () => {
    const blob = await rooms.calendarFile(room.code);
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `${room.title.replace(/[^\w-]+/g, '-').slice(0, 40) || 'room'}.ics`;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
  };

  return (
    <section className={highlight ? 'rm-share is-new' : 'rm-share'} aria-label="Share this room">
      {highlight ? <p className="rm-label">Your room is ready. Share the link:</p> : <p className="rm-label">Link</p>}
      <div className="rm-share__row">
        <code className="rm-share__url">{room.url}</code>
        <button
          type="button"
          className="btn btn--tiny"
          onClick={async () => {
            setCopied(await copy(room.url));
            window.setTimeout(() => setCopied(false), 2_000);
          }}
        >
          {copied ? 'Copied' : 'Copy link'}
        </button>
        <button type="button" className="btn btn--tiny" onClick={() => downloadCalendar().catch(() => undefined)}>
          Add to calendar
        </button>
      </div>
      <p className="rm-hint">
        {room.access === 'link'
          ? 'Anyone in your organisation who has this link can come in.'
          : 'Only invited people can come in; for everyone else the link does nothing.'}{' '}
        Room code <strong>{room.code}</strong>
      </p>
      {qr ? <img className="rm-share__qr" src={qr} alt={`QR code for ${room.url}`} width={132} height={132} /> : null}
    </section>
  );
}

function KnockQueue({ room, rooms, onChange }) {
  const [knocks, setKnocks] = useState([]);

  const load = useCallback(async () => {
    try {
      setKnocks((await rooms.knocks(room.code)).items);
    } catch {
      // Shown again on the next poll.
    }
  }, [rooms, room.code]);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 5_000);
    return () => window.clearInterval(timer);
  }, [load]);

  if (!room.approval) return null;
  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
    onChange();
  };

  return (
    <section className="rm-panel" aria-live="polite">
      <div className="rm-panel__head">
        <p className="rm-label">Waiting to be let in ({knocks.length})</p>
        {knocks.length > 1 ? (
          <button type="button" className="btn btn--tiny" onClick={() => act(() => rooms.admit(room.code, []))}>
            Admit all
          </button>
        ) : null}
      </div>
      {knocks.length === 0 ? <p className="rm-hint">Nobody is knocking.</p> : null}
      <ul className="rm-list">
        {knocks.map((knock) => (
          <li key={knock.userId}>
            <span>{knock.displayName}</span>
            <span className="rm-inline">
              <button type="button" className="btn btn--tiny btn--primary" onClick={() => act(() => rooms.admit(room.code, [knock.userId]))}>
                Admit
              </button>
              <button type="button" className="btn btn--tiny" onClick={() => act(() => rooms.deny(room.code, knock.userId))}>
                Decline
              </button>
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function HostPanel({ room, rooms, navigate, reload }) {
  const [cancelling, setCancelling] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const isHost = room.viewer.relation === 'host';
  const open = room.phase !== 'ended' && room.phase !== 'cancelled';

  const cancel = async (scope) => {
    setBusy(true);
    setError(null);
    try {
      await rooms.cancel(room.code, { scope, reason: reason.trim() || null });
      setCancelling(false);
      reload();
    } catch (cause) {
      setError(cause?.detail ?? 'The room was not cancelled.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="rm-panel">
      <p className="rm-label">{isHost ? 'You host this room' : 'You co-host this room'}</p>
      <p className="rm-hint">
        {room.occupied} in the room
        {room.capacity ? ` of ${room.capacity} seats` : ''}
        {room.invitees ? ` · ${room.invitees.length} invited` : ''}
        {room.cohosts.length ? ` · co-hosts: ${room.cohosts.map((c) => c.displayName).join(', ')}` : ''}
      </p>
      {isHost && open ? (
        <div className="rm-inline">
          <Link className="btn btn--tiny" to={`/rooms/${room.code}/edit`}>
            Edit
          </Link>
          <Link className="btn btn--tiny" to={`/rooms/new?from=${room.code}`}>
            Copy to a new date
          </Link>
          <button type="button" className="btn btn--tiny" onClick={() => setCancelling((v) => !v)}>
            Cancel room…
          </button>
        </div>
      ) : null}
      {isHost && !open ? (
        <Link className="btn btn--tiny" to={`/rooms/new?from=${room.code}`}>
          Plan it again
        </Link>
      ) : null}
      {cancelling ? (
        <div className="rm-confirm">
          <input className="rm-input" placeholder="Reason (optional, sent to invitees)" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} />
          <div className="rm-inline">
            <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => cancel('this')}>
              Cancel this date
            </button>
            {room.seriesId ? (
              <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => cancel('following')}>
                Cancel this and all later dates
              </button>
            ) : null}
            <button type="button" className="btn btn--tiny" onClick={() => setCancelling(false)}>
              Keep it
            </button>
          </div>
          {error ? <p className="rm-error">{error}</p> : null}
        </div>
      ) : null}
      {room.viewer.canEnter ? null : (
        <p className="rm-hint">You can open the room from {formatTime(room.hostOpensAt)}.</p>
      )}
      <button type="button" className="rm-link rm-back" onClick={() => navigate('/')}>
        All my rooms
      </button>
    </section>
  );
}

export default function RoomLobbyPage() {
  const { code } = useParams();
  const navigate = useNavigate();
  const location = useLocation();
  const core = useCore();
  const { http, status } = core;
  const rooms = useMemo(() => createRoomsApi(http), [http]);

  const [room, setRoom] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [skew, setSkew] = useState(0);
  const now = useNow();
  const loading = useRef(false);

  const load = useCallback(async () => {
    if (loading.current) return;
    loading.current = true;
    try {
      const next = await rooms.get(code);
      setSkew(new Date(next.serverTime).getTime() - Date.now());
      setRoom(next);
      setError(null);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'This room could not be loaded.');
    } finally {
      loading.current = false;
    }
  }, [rooms, code]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    load();
    const timer = window.setInterval(load, 10_000);
    return () => window.clearInterval(timer);
  }, [load, status]);

  // Being let in, a freed seat, a knock: reload at once instead of on the next poll.
  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    const offs = ['room:admitted', 'room:denied', 'room:seat-available', 'room:knock'].map((event) =>
      onUserEvent(core, event, (payload) => {
        if (!payload?.code || payload.code === code) load();
      }),
    );
    return () => offs.forEach((off) => off());
  }, [core, status, code, load]);

  // The doors open while someone watches the countdown: ask the server then, not 10 s later.
  const serverNow = now + skew;
  const opensAt = room?.viewer?.opensAt ? new Date(room.viewer.opensAt).getTime() : null;
  useEffect(() => {
    if (opensAt && serverNow >= opensAt && !room?.viewer?.canEnter) load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [opensAt && serverNow >= opensAt]);

  if (status === 'anonymous') {
    return <Navigate to="/login" replace state={{ from: `/rooms/${code}/lobby` }} />;
  }

  if (error && !room) {
    return (
      <main className="rm-lobby">
        <div className="rm-lobby__card">
          <h1>Room not found</h1>
          <p className="muted">{error}</p>
          <Link className="btn" to="/">
            Back
          </Link>
        </div>
      </main>
    );
  }

  if (!room) {
    return (
      <main className="rm-lobby">
        <p className="muted">Loading…</p>
      </main>
    );
  }

  const { viewer } = room;
  const minutes = Math.round((new Date(room.endsAt) - new Date(room.startsAt)) / 60_000);
  const act = async (fn) => {
    setBusy(true);
    try {
      setRoom(await fn());
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'That did not work.');
    } finally {
      setBusy(false);
    }
  };

  const enter = () => navigate(`/rooms/${room.code}`);
  const startsIn = new Date(room.startsAt).getTime() - serverNow;
  const endsIn = new Date(room.endsAt).getTime() - serverNow;
  const holdLeft = viewer.holdUntil ? new Date(viewer.holdUntil).getTime() - serverNow : 0;

  let action;
  if (viewer.canEnter) {
    action = (
      <>
        {holdLeft > 0 ? <p className="rm-good">A seat is free and held for you — {countdown(holdLeft).replace('in ', '')} left.</p> : null}
        <button type="button" className="btn btn--primary rm-enter" onClick={enter}>
          {room.phase === 'live' ? 'Enter room' : viewer.moderator ? 'Open the room' : 'Enter room'}
        </button>
        <p className="rm-hint">
          {room.phase === 'live' ? `Running · ends ${countdown(endsIn)}` : `Starts ${countdown(startsIn)}`}
        </p>
      </>
    );
  } else if (viewer.reason === 'room_not_open' && opensAt) {
    action = (
      <>
        <p className="rm-countdown" aria-live="polite">
          Doors open {countdown(opensAt - serverNow)}
        </p>
        <p className="rm-hint">at {formatTime(viewer.opensAt)} · the page opens the doors for you</p>
      </>
    );
  } else if (viewer.reason === 'needs_admission') {
    action = viewer.knocked ? (
      <>
        <p className="rm-countdown">Waiting for a host to let you in…</p>
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => act(() => rooms.withdrawKnock(room.code))}>
          Stop asking
        </button>
      </>
    ) : (
      <>
        <p className="rm-hint">A host lets people in.</p>
        <button type="button" className="btn btn--primary rm-enter" disabled={busy} onClick={() => act(() => rooms.knock(room.code))}>
          Ask to join
        </button>
      </>
    );
  } else if (viewer.reason === 'room_full') {
    action = viewer.waitlistPosition ? (
      <>
        <p className="rm-countdown">You are number {viewer.waitlistPosition} on the waiting list.</p>
        <p className="rm-hint">When a seat is free it is held for you for 2 minutes, and you are told at once.</p>
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => act(() => rooms.leaveWaitlist(room.code))}>
          Leave the waiting list
        </button>
      </>
    ) : (
      <>
        <p className="rm-hint">All {room.effectiveCapacity} seats are taken.</p>
        <button type="button" className="btn btn--primary rm-enter" disabled={busy} onClick={() => act(() => rooms.joinWaitlist(room.code))}>
          Join the waiting list
        </button>
      </>
    );
  } else {
    action = <p className="rm-countdown">{viewer.message ?? reasonText(viewer.reason, room) ?? 'You cannot enter this room.'}</p>;
  }

  return (
    <main className="rm-lobby">
      <div className="rm-lobby__grid">
        <section className="rm-lobby__card">
          <div className="rm-card__top">
            <span className={`rm-phase rm-phase--${room.phase}`}>{phaseLabel(room.phase)}</span>
            <span className="rm-hint">by {room.host.displayName}</span>
          </div>
          <h1 className="rm-lobby__title">{room.title}</h1>
          <p className="rm-card__when">
            {formatDate(room.startsAt)} · {timeInZones(room.startsAt, room.timeZone, viewerZone())} · {durationLabel(minutes)}
          </p>
          {room.cancelReason && room.phase === 'cancelled' ? <p className="rm-error">Cancelled: {room.cancelReason}</p> : null}
          {room.description ? <p className="rm-lobby__text">{room.description}</p> : null}
          {room.agenda ? (
            <div className="rm-agenda">
              <p className="rm-label">Agenda</p>
              <ol>
                {room.agenda
                  .split('\n')
                  .map((line) => line.replace(/^\s*(\d+[.)]|[-*•])\s*/, '').trim())
                  .filter(Boolean)
                  .map((line, index) => (
                    <li key={`${index}-${line}`}>{line}</li>
                  ))}
              </ol>
            </div>
          ) : null}

          <div className="rm-action">{action}</div>
          {error ? <p className="rm-error">{error}</p> : null}

          <ul className="rm-facts">
            <li>Doors open {room.earlyEntryMinutes} minutes before the start ({formatTime(room.doorsOpenAt)})</li>
            {room.lateUntil ? <li>No new arrivals after {formatTime(room.lateUntil)}</li> : null}
            {room.capacity ? <li>{room.capacity} seats</li> : null}
            {room.approval ? <li>A host lets people in</li> : null}
            {room.settings.learnersJoinMuted ? <li>You join muted</li> : null}
          </ul>
        </section>

        <aside className="rm-lobby__side">
          {viewer.moderator || room.access === 'link' ? (
            <SharePanel room={room} rooms={rooms} highlight={Boolean(location.state?.created)} />
          ) : null}
          {location.state?.created && location.state?.occurrences?.length > 1 ? (
            <p className="rm-hint">
              {location.state.occurrences.length} dates created, each with its own link. Find them all under “My rooms”.
            </p>
          ) : null}
          {viewer.moderator ? <KnockQueue room={room} rooms={rooms} onChange={load} /> : null}
          {viewer.moderator ? <HostPanel room={room} rooms={rooms} navigate={navigate} reload={load} /> : null}
          {room.phase !== 'ended' && room.phase !== 'cancelled' ? (
            <section className="rm-panel">
              <p className="rm-label">Camera and microphone</p>
              <DeviceCheck />
            </section>
          ) : null}
          {!viewer.moderator ? (
            <Link className="rm-link rm-back" to="/">
              All my rooms
            </Link>
          ) : null}
        </aside>
      </div>
    </main>
  );
}
