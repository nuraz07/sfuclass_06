import VideoTile from './VideoTile.jsx';

/**
 * Layout while somebody is sharing: the share takes the room, faces shrink to
 * a strip along the bottom.
 *
 * `object-fit: contain` on the share is deliberate — cropping a slide to fill
 * the frame cuts off exactly the text the share exists to show.
 */
export default function ScreenShareStage({
  screenShare,
  streams,
  peers,
  selfPeerId,
  selfLabel,
  localVideoTrack,
  localScreenTrack,
  cameraEnabled,
}) {
  const screenStream = streams.find(
    (stream) => stream.source === 'screen' && stream.peerId === screenShare.peerId,
  );

  const cameraStreams = streams.filter(
    (stream) => stream.kind === 'video' && stream.source === 'camera',
  );

  const isOwnShare = screenShare.peerId === selfPeerId;
  const presenterName = screenShare.user?.displayName ?? 'Someone';

  return (
    <div className="stage">
      <div className="stage__main">
        {/*
          Everyone sees the share, the presenter included — a teacher needs to
          know what the room is actually looking at, and "you are sharing" is
          not the same reassurance as seeing it.

          The source differs though. A remote peer's share arrives as a consumer
          track; your own does not, because the SFU never sends a producer back
          to the peer that created it. So the presenter renders the local track
          directly, muted, with no audio path at all.
        */}
        <VideoTile
          track={isOwnShare ? localScreenTrack : (screenStream?.track ?? null)}
          label={
            isOwnShare
              ? `You — ${screenShare.label ?? 'screen'}`
              : `${presenterName} — ${screenShare.label ?? 'screen'}`
          }
          muted
          variant="stage"
        />
      </div>

      <div className="stage__strip">
        <VideoTile
          track={cameraEnabled ? localVideoTrack : null}
          label={`${selfLabel} (you)`}
          muted
          mirrored
          variant="strip"
        />
        {cameraStreams.map((stream) => (
          <VideoTile
            key={stream.consumerId}
            track={stream.track}
            label={
              peers.find((peer) => peer.peerId === stream.peerId)?.user.displayName ?? 'Participant'
            }
            variant="strip"
          />
        ))}
      </div>
    </div>
  );
}