import { Link } from 'react-router-dom';
import { formatDate, formatTime } from '../../lib/preferences.js';
import { durationLabel, phaseLabel } from './roomModel.js';

/**
 * One room as a card: in "My rooms" and as the live preview while creating one  (Rooms)
 */
export default function RoomCard({ room, to = null, preview = false }) {
  const minutes = Math.round((new Date(room.endsAt) - new Date(room.startsAt)) / 60_000);
  const body = (
    <>
      <div className="rm-card__top">
        <span className={`rm-phase rm-phase--${room.phase ?? 'scheduled'}`}>{phaseLabel(room.phase ?? 'scheduled')}</span>
        {room.relation && room.relation !== 'invitee' ? (
          <span className="rm-hint">{room.relation === 'host' ? 'You host' : 'You co-host'}</span>
        ) : room.hostName ? (
          <span className="rm-hint">by {room.hostName}</span>
        ) : null}
      </div>
      <p className="rm-card__title">{room.title || (preview ? 'Your room' : 'Room')}</p>
      <p className="rm-card__when">
        {formatDate(room.startsAt)} · {formatTime(room.startsAt)}–{formatTime(room.endsAt)} · {durationLabel(minutes)}
      </p>
      <p className="rm-hint">
        Doors open {formatTime(room.doorsOpenAt)}
        {room.capacity ? ` · ${room.capacity} seats` : ''}
        {room.access === 'link' ? ' · anyone with the link' : room.inviteeCount ? ` · ${room.inviteeCount} invited` : ''}
      </p>
    </>
  );
  if (to) {
    return (
      <Link to={to} className="rm-card rm-card--link">
        {body}
      </Link>
    );
  }
  return <div className={preview ? 'rm-card rm-card--preview' : 'rm-card'}>{body}</div>;
}
