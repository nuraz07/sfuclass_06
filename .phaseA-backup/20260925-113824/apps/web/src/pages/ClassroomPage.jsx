import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Navigate, useNavigate, useParams } from 'react-router-dom';
import { useClassroom, useCore } from '@classroom/core-client';

import { useSfuClient } from '../lib/useSfuClient.js';
import StudentGrid from '../components/Classroom/StudentGrid.jsx';
import ScreenShareStage from '../components/Classroom/ScreenShareStage.jsx';
import ControlBar from '../components/Classroom/ControlBar.jsx';
import ClassroomChatPanel from '../components/Classroom/ClassroomChatPanel.jsx';
import VideoTile from '../components/Classroom/VideoTile.jsx';

/**
 * Classroom  (F1)
 *
 * Sits outside AppLayout deliberately: no nav, no chat dock, nothing competing
 * with the lesson for the screen.
 *
 * This page renders; it does not decide. Every media decision belongs to
 * SfuClient, every piece of state to useClassroom. If a rule appears here, it
 * is in the wrong file.
 */
export default function ClassroomPage() {
  const { roomId } = useParams();
  const navigate = useNavigate();
  const { session, status } = useCore();

  const { sfu, deviceAdapter, screenShareAdapter } = useSfuClient();

  // Which dependency changed identity between renders. Each line prints only
  // when that value is a different object than last render, so whatever is
  // listed is what is rebuilding the client.
  const prev = useRef({});
  useEffect(() => {
    const now = { sfu, deviceAdapter, screenShareAdapter, roomId, status };
    const changed = Object.keys(now).filter((k) => prev.current[k] !== now[k]);
    if (changed.length) console.log('[deps] changed:', changed.join(', '));
    prev.current = now;
  });
  const [reactions, setReactions] = useState([]);
  const [showParticipants, setShowParticipants] = useState(true);
  // A peer never consumes its own producer — the SFU has nothing to send back —
  // so the sharer's own view has to come from the local track directly.
  const [localScreenTrack, setLocalScreenTrack] = useState(null);

  // Stable identity. useClassroom's join() is a useCallback over these values,
  // and its effect re-runs whenever join() changes — so an inline object
  // literal rebuilt on every render makes the room leave and rejoin in a loop.
  // The second join lands on a socket that already has a session and never
  // gets answered, which presents as "Joining the lesson…" forever.
  const onReaction = useCallback(({ peerId, emoji }) => {
    const id = `${peerId}-${Date.now()}-${Math.random()}`;
    setReactions((current) => [...current, { id, emoji }]);
    setTimeout(() => setReactions((current) => current.filter((r) => r.id !== id)), 3_000);
  }, []);

  const classroomOptions = useMemo(
    () => ({
      sfu,
      deviceAdapter,
      roomId,
      autoJoin: status === 'authenticated',
      // Above ten people, arriving unmuted is a room full of keyboard noise.
      startMuted: true,
      startCameraOff: false,
      onReaction,
    }),
    [sfu, deviceAdapter, roomId, status, onReaction],
  );
  const classroom = useClassroom(classroomOptions);


  const {
    status: connection,
    peers,
    streams,
    screenShare,
    selfPeerId,
    selfRole,
    cameraEnabled,
    microphoneEnabled,
    handRaised,
    reactionsEnabled,
    error,
    actions,
    localVideoTrack,
  } = classroom;

  const handleLeave = useCallback(async () => {
    await actions.leave();
    navigate('/');
  }, [actions, navigate]);

  const isScreenSharing = screenShare?.peerId === selfPeerId;

  const handleToggleScreenShare = useCallback(async () => {
    if (isScreenSharing) {
      await sfu.stopScreenShare('user');
      setLocalScreenTrack(null);
    } else {
      await sfu.startScreenShare({ withAudio: false });
      // Read after the producer exists; startScreenShare resolves once it does.
      setLocalScreenTrack(sfu.localProducers.screen?.track ?? null);
    }
  }, [isScreenSharing, sfu]);

  // The browser's own "Stop sharing" bar ends the track without going through
  // the button, so the local view has to follow the server's view of the lock.
  useEffect(() => {
    if (!isScreenSharing) setLocalScreenTrack(null);
  }, [isScreenSharing]);

  // Closing the tab must still release the seat and the presenter lock, or the
  // room keeps a ghost participant and nobody else can share.
  useEffect(() => {
    const onHide = () => void sfu.leave();
    window.addEventListener('pagehide', onHide);
    return () => window.removeEventListener('pagehide', onHide);
  }, [sfu]);

  if (status === 'restoring') {
    return (
      <main className="room room--pending">
        <p>Checking your session…</p>
      </main>
    );
  }

  if (status === 'anonymous') {
    return <Navigate to="/login" replace state={{ from: `/rooms/${roomId}` }} />;
  }

  if (connection === 'idle' || connection === 'resolving' || connection === 'connecting') {
    return (
      <main className="room room--pending">
        <p>Joining the lesson… ({connection})</p>
        {/*
          A join that fails leaves the state at 'connecting' rather than moving
          to 'closed', so the error screen below never renders and the spinner
          runs forever. Showing it here turns a hang into a message.
        */}
        {error && (
          <p className="banner banner--warn">
            {error.code}: {error.detail ?? error.message}
          </p>
        )}
      </main>
    );
  }

  if (error && connection === 'closed') {
    return (
      <main className="room room--pending">
        <h1>Could not join</h1>
        <p>{error.detail ?? error.message}</p>
        <button type="button" className="btn" onClick={() => actions.join()}>
          Try again
        </button>
        <button type="button" className="btn btn--danger" onClick={() => navigate('/')}>
          Back
        </button>
      </main>
    );
  }

  const selfLabel = session?.displayName ?? 'You';
  const canModerate = selfRole === 'host' || selfRole === 'cohost';
  const audioStreams = streams.filter((stream) => stream.kind === 'audio');

  return (
    <main className="room">
      <header className="room__header">
        <h1 className="room__title">Lesson</h1>
        <span className={`badge badge--${connection}`}>{connection}</span>
        <button
          type="button"
          className="btn btn--tiny"
          onClick={() => setShowParticipants((visible) => !visible)}
        >
          {peers.length} participant{peers.length === 1 ? '' : 's'}
        </button>
      </header>

      {connection === 'reconnecting' && (
        <p className="banner banner--warn">
          Connection lost — moving this session to another server.
        </p>
      )}
      {error && connection !== 'closed' && (
        <p className="banner banner--warn">{error.detail ?? error.message}</p>
      )}

      <div className="room__body">
        <section className="room__stage">
          {screenShare ? (
            <ScreenShareStage
              screenShare={screenShare}
              streams={streams}
              peers={peers}
              selfPeerId={selfPeerId}
              selfLabel={selfLabel}
              localVideoTrack={localVideoTrack}
              localScreenTrack={localScreenTrack}
              cameraEnabled={cameraEnabled}
            />
          ) : (
            <StudentGrid
              peers={peers}
              streams={streams}
              selfPeerId={selfPeerId}
              selfLabel={selfLabel}
              localVideoTrack={localVideoTrack}
              cameraEnabled={cameraEnabled}
            />
          )}

          {reactions.length > 0 && (
            <div className="reactions" aria-live="polite">
              {reactions.map((reaction) => (
                <span key={reaction.id} className="reactions__burst">
                  {reaction.emoji}
                </span>
              ))}
            </div>
          )}
        </section>

        {showParticipants && (
          <ClassroomChatPanel
            roomId={roomId}
            peers={peers}
            selfPeerId={selfPeerId}
            canModerate={canModerate}
            onHostAction={actions.hostAction}
          />
        )}
      </div>

      {/* Remote audio is played, never displayed. One element per track, so a
          single peer dropping does not interrupt everybody else's audio. */}
      {audioStreams.map((stream) => (
        <VideoTile key={stream.consumerId} track={stream.track} kind="audio" />
      ))}

      <ControlBar
        microphoneEnabled={microphoneEnabled}
        cameraEnabled={cameraEnabled}
        handRaised={handRaised}
        isScreenSharing={isScreenSharing}
        canScreenShare={screenShareAdapter.isSupported()}
        screenTakenBy={
          screenShare && !isScreenSharing ? (screenShare.user?.displayName ?? 'Someone') : null
        }
        onToggleMicrophone={actions.toggleMicrophone}
        onToggleCamera={actions.toggleCamera}
        onToggleHand={() => actions.raiseHand(!handRaised)}
        onToggleScreenShare={handleToggleScreenShare}
        onReact={actions.react}
        reactionsEnabled={reactionsEnabled}
        canToggleReactions={selfRole === 'host'}
        onToggleReactions={() => actions.setReactionsEnabled(!reactionsEnabled)}
        onLeave={handleLeave}
      />
    </main>
  );
}