import { useEffect, useMemo, useState } from 'react';
import { createRoomsApi, useCore } from '@classroom/core-client';

/**
 * May this person enter this room right now?  (Rooms)
 *
 * Asked by the classroom page before it opens a socket, so someone who
 * arrives too early, uninvited or without a seat lands in the lobby instead
 * of on an error. Only scheduled rooms (codes like "kqz-7hfd-2mx") are asked
 * about; any other room id — and any failure to ask — enters as before. The
 * socket join checks again either way.
 */
const ROOM_CODE = /^[a-hjkmnp-z2-9]{3}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{3}$/;

export const isRoomCode = (value) => ROOM_CODE.test(String(value ?? ''));

export function useRoomGate(roomId) {
  const { http, status } = useCore();
  const rooms = useMemo(() => createRoomsApi(http), [http]);
  const scheduled = isRoomCode(roomId);
  const [gate, setGate] = useState({ ready: !scheduled, canEnter: true, scheduled, reason: null });

  useEffect(() => {
    if (!scheduled) {
      setGate({ ready: true, canEnter: true, scheduled: false, reason: null });
      return undefined;
    }
    if (status !== 'authenticated') return undefined;
    const controller = new AbortController();
    rooms
      .gate(roomId, controller.signal)
      .then((answer) =>
        setGate({ ready: true, canEnter: answer.canEnter, scheduled: answer.scheduled, reason: answer.reason ?? null }),
      )
      .catch(() => {
        if (!controller.signal.aborted) setGate({ ready: true, canEnter: true, scheduled: true, reason: null });
      });
    return () => controller.abort();
  }, [rooms, roomId, scheduled, status]);

  return gate;
}

export default useRoomGate;
