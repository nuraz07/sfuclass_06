#!/usr/bin/env bash
# part2-install.sh — Part 2 of the chat rework: emoji reactions on/off, host only.
#
# Run from the project folder (the one containing server/, packages/ and apps/):
#   bash part2-install.sh
#
# Rewrites ControlBar.jsx, patches 8 files, keeps a backup of every file it
# touches in .part2-backup/<timestamp>/ and checks all of them at the end.
# Undo: bash part2-install.sh --restore   (back to the state before the first install)
set -euo pipefail

if [ ! -d server/src/classroom ] || [ ! -d packages/contracts/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  apps/web/src/components/Classroom/ControlBar.jsx
  packages/contracts/src/events/signaling.events.ts
  server/src/classroom/Room.js
  server/src/classroom/ModerationControls.js
  server/src/classroom/interaction/Reactions.js
  server/src/signaling/socketHandlers.js
  packages/core-client/src/rtc/SfuClient.ts
  packages/core-client/src/state/useClassroom.ts
  apps/web/src/pages/ClassroomPage.jsx
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .part2-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then cp "$FIRST/$f" "$f"; echo "restored $f"; fi
  done
  echo "Restored from $FIRST."
  exit 0
fi

BACKUP=".part2-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

cat > .part2-patch.mjs <<'__P2_EOF__'
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'packages/contracts/src/events/signaling.events.ts',
    marker: 'roomSettings',
    edits: [
      {
        name: 'room state carries reactionsEnabled',
        find: '  waitingRoomEnabled: z.boolean().default(false),\n  startedAt: IsoDateTimeSchema,\n});\n',
        replace:
          '  waitingRoomEnabled: z.boolean().default(false),\n' +
          '  /** Off: only the host may send emoji reactions. Set by the host. */\n' +
          '  reactionsEnabled: z.boolean().default(true),\n' +
          '  startedAt: IsoDateTimeSchema,\n' +
          '});\n',
      },
      {
        name: 'client event: host changes a room setting',
        find: "  breakout: 'classroom:breakout',\n} as const;\n",
        replace:
          "  breakout: 'classroom:breakout',\n" +
          '  /** Host only: { reactionsEnabled: boolean }. */\n' +
          "  roomSettings: 'classroom:room.settings.update',\n" +
          '} as const;\n',
      },
      {
        name: 'server event: a room setting changed',
        find: "  nodeDraining: 'classroom:node.draining',\n} as const;\n",
        replace:
          "  nodeDraining: 'classroom:node.draining',\n" +
          '  /** The host changed a room setting: { reactionsEnabled }. */\n' +
          "  roomSettings: 'classroom:room.settings',\n" +
          '} as const;\n',
      },
    ],
  },
  {
    file: 'server/src/classroom/Room.js',
    marker: 'reactionsEnabled',
    edits: [
      {
        name: 'reactions are on when a room starts',
        find: '    this.settings = { ...MODE_DEFAULTS[mode] ?? MODE_DEFAULTS.seminar };\n',
        replace:
          '    this.settings = { ...(MODE_DEFAULTS[mode] ?? MODE_DEFAULTS.seminar), reactionsEnabled: true };\n',
      },
      {
        name: 'room state reports it',
        find: '      waitingRoomEnabled: this.settings.waitingRoom,\n',
        replace:
          '      waitingRoomEnabled: this.settings.waitingRoom,\n' +
          '      reactionsEnabled: this.settings.reactionsEnabled !== false,\n',
      },
    ],
  },
  {
    file: 'server/src/classroom/ModerationControls.js',
    marker: 'setReactionsEnabled',
    edits: [
      {
        name: 'only the host switches reactions on or off',
        find: '/** Single entry point for the `classroom:host.action` socket event. */\n',
        replace:
          '/**\n' +
          ' * Emoji reactions on or off for everyone except the host. The host only —\n' +
          ' * not a cohost: it is a decision about the whole lesson.\n' +
          ' */\n' +
          'export const setReactionsEnabled = (room, actor, enabled) => {\n' +
          '  if (!actor?.isHost) {\n' +
          "    throw Object.assign(new Error('only the host may switch reactions'), { code: 'not_room_host' });\n" +
          '  }\n' +
          '  room.settings.reactionsEnabled = Boolean(enabled);\n' +
          "  room.broadcast('classroom:room.settings', { reactionsEnabled: room.settings.reactionsEnabled });\n" +
          "  log.info({ roomId: room.id, enabled: room.settings.reactionsEnabled, by: actor.id }, 'reactions switched');\n" +
          '  return room.settings.reactionsEnabled;\n' +
          '};\n' +
          '\n' +
          '/** Single entry point for the `classroom:host.action` socket event. */\n',
      },
    ],
  },
  {
    file: 'server/src/classroom/interaction/Reactions.js',
    marker: 'reactions_disabled',
    edits: [
      {
        name: 'refused while the host has reactions switched off',
        find: 'export const send = (room, peer, emoji) => {\n',
        replace:
          'export const send = (room, peer, emoji) => {\n' +
          '  // Switched off by the host: everyone else is refused here, whatever the\n' +
          '  // client shows. The host can still react.\n' +
          '  if (room.settings?.reactionsEnabled === false && !peer.isHost) {\n' +
          "    return { ok: false, code: 'reactions_disabled', reason: 'The host has switched reactions off.' };\n" +
          '  }\n' +
          '\n',
      },
    ],
  },
  {
    file: 'server/src/signaling/socketHandlers.js',
    marker: 'onRoomSettings',
    edits: [
      {
        name: 'room settings event, host only',
        find: '  { event: CLIENT.breakout, cost: 5, roles: MODERATORS, handler: onBreakout },\n];\n',
        replace:
          '  { event: CLIENT.breakout, cost: 5, roles: MODERATORS, handler: onBreakout },\n' +
          "  { event: CLIENT.roomSettings, cost: 2, roles: ['host'], handler: onRoomSettings },\n" +
          '];\n',
      },
      {
        name: 'a reaction is broadcast once (Reactions.send already does it)',
        find:
          '  // Ephemeral by design: the burst is broadcast and never written to history.\n' +
          '  session.room.broadcast(SERVER.reaction, { peerId: session.peer.id, emoji: payload.emoji });\n' +
          '  return { sent: true };\n',
        replace:
          '  // Reactions.send has broadcast it already; a second broadcast showed every\n' +
          '  // reaction twice.\n' +
          '  return { sent: true };\n',
      },
      {
        name: 'the handler',
        find: 'export default registerSocketHandlers;',
        replace:
          '/* ------------------------------------------------------------------ *\n' +
          ' * Room settings (host)\n' +
          ' * ------------------------------------------------------------------ */\n' +
          '\n' +
          '/** { reactionsEnabled: boolean }. ModerationControls broadcasts the change. */\n' +
          'async function onRoomSettings(_ctx, payload, session) {\n' +
          "  if (typeof payload.reactionsEnabled !== 'boolean') {\n" +
          "    fail('invalid_payload', 'reactionsEnabled must be true or false');\n" +
          '  }\n' +
          '  const reactionsEnabled = ModerationControls.setReactionsEnabled(\n' +
          '    session.room,\n' +
          '    session.peer,\n' +
          '    payload.reactionsEnabled,\n' +
          '  );\n' +
          '  return { reactionsEnabled };\n' +
          '}\n' +
          '\n' +
          'export default registerSocketHandlers;\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/rtc/SfuClient.ts',
    marker: 'setRoomSettings',
    edits: [
      {
        name: 'event type',
        find: '  recordingChanged: (event: { recording: boolean }) => void;\n',
        replace:
          '  recordingChanged: (event: { recording: boolean }) => void;\n' +
          '  /** The host changed a room setting (reactions on/off). */\n' +
          '  roomSettingsChanged: (event: { reactionsEnabled?: boolean }) => void;\n',
      },
      {
        name: 'setRoomSettings()',
        find:
          '    await this.request(CLIENT.hostAction, payload);\n' +
          '  }\n',
        replace:
          '    await this.request(CLIENT.hostAction, payload);\n' +
          '  }\n' +
          '\n' +
          '  /** Host only: reactions on or off for everyone else. */\n' +
          '  async setRoomSettings(settings: { reactionsEnabled: boolean }): Promise<{ reactionsEnabled: boolean }> {\n' +
          '    return this.request<{ reactionsEnabled: boolean }>(CLIENT.roomSettings, settings);\n' +
          '  }\n',
      },
      {
        name: 'listen for the change',
        find:
          '    socket.on(SERVER.recordingChanged, (event: { recording: boolean }) =>\n' +
          "      this.emit('recordingChanged', event),\n" +
          '    );\n',
        replace:
          '    socket.on(SERVER.recordingChanged, (event: { recording: boolean }) =>\n' +
          "      this.emit('recordingChanged', event),\n" +
          '    );\n' +
          '    socket.on(SERVER.roomSettings, (event: { reactionsEnabled?: boolean }) =>\n' +
          "      this.emit('roomSettingsChanged', event),\n" +
          '    );\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/state/useClassroom.ts',
    marker: 'reactionsEnabled',
    edits: [
      {
        name: 'state type',
        find: '  handRaised: boolean;\n  error: ApiError | null;\n}\n',
        replace: '  handRaised: boolean;\n  /** Off: only the host may react. */\n  reactionsEnabled: boolean;\n  error: ApiError | null;\n}\n',
      },
      {
        name: 'action type',
        find: '  admit(peerId: string): Promise<void>;\n}\n',
        replace: '  admit(peerId: string): Promise<void>;\n  /** Host only. */\n  setReactionsEnabled(enabled: boolean): Promise<void>;\n}\n',
      },
      {
        name: 'state',
        find: '  const [handRaised, setHandRaised] = useState(false);\n',
        replace:
          '  const [handRaised, setHandRaised] = useState(false);\n' +
          '  const [reactionsEnabled, setReactionsEnabledState] = useState(true);\n',
      },
      {
        name: 'from the room state',
        find: '        setScreenShare(state.screenShare);\n      }),\n',
        replace:
          '        setScreenShare(state.screenShare);\n' +
          '        setReactionsEnabledState((state as { reactionsEnabled?: boolean }).reactionsEnabled !== false);\n' +
          '      }),\n',
      },
      {
        name: 'live changes',
        find: "      sfu.on('recordingChanged', ({ recording: isRecording }) => setRecording(isRecording)),\n",
        replace:
          "      sfu.on('recordingChanged', ({ recording: isRecording }) => setRecording(isRecording)),\n" +
          "      sfu.on('roomSettingsChanged', (event) => {\n" +
          "        if (typeof event.reactionsEnabled === 'boolean') setReactionsEnabledState(event.reactionsEnabled);\n" +
          '      }),\n',
      },
      {
        name: 'action',
        find: '      admit: async (peerId) => {\n',
        replace:
          '      setReactionsEnabled: async (enabled) => {\n' +
          '        const result = await sfu.setRoomSettings({ reactionsEnabled: enabled });\n' +
          '        setReactionsEnabledState(result.reactionsEnabled);\n' +
          '      },\n' +
          '      admit: async (peerId) => {\n',
      },
      {
        name: 'returned',
        find: '    handRaised,\n    error,\n    actions,\n',
        replace: '    handRaised,\n    reactionsEnabled,\n    error,\n    actions,\n',
      },
    ],
  },
  {
    file: 'apps/web/src/pages/ClassroomPage.jsx',
    marker: 'onToggleReactions',
    edits: [
      {
        name: 'read the setting',
        find: '    handRaised,\n    error,\n    actions,\n    localVideoTrack,\n  } = classroom;\n',
        replace: '    handRaised,\n    reactionsEnabled,\n    error,\n    actions,\n    localVideoTrack,\n  } = classroom;\n',
      },
      {
        name: 'pass it to the control bar; the switch only for the host',
        find: '        onReact={actions.react}\n',
        replace:
          '        onReact={actions.react}\n' +
          '        reactionsEnabled={reactionsEnabled}\n' +
          "        canToggleReactions={selfRole === 'host'}\n" +
          '        onToggleReactions={() => actions.setReactionsEnabled(!reactionsEnabled)}\n',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const count = src.split(edit.find).length - 1;
    if (count !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed in any file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.replace(edit.find, edit.replace);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__P2_EOF__
node .part2-patch.mjs
rm -f .part2-patch.mjs

cat > apps/web/src/components/Classroom/ControlBar.jsx <<'__P2_EOF__'
/**
 * The controls along the bottom of a lesson.
 *
 * Every button reflects state the server confirmed, not what the user clicked:
 * useClassroom rolls an optimistic toggle back if the ack fails, so a mute that
 * the server rejected does not leave the button lying about it.
 *
 * Reactions: the host — and only the host — can switch emoji reactions off for
 * everyone else and back on ("Reactions: on / off"). While they are off, the
 * emoji buttons are disabled for everyone except the host, and the server
 * refuses them as well, so a modified client cannot send them anyway.
 */
export default function ControlBar({
  microphoneEnabled,
  cameraEnabled,
  handRaised,
  isScreenSharing,
  canScreenShare,
  screenTakenBy,
  reactionsEnabled = true,
  canToggleReactions = false,
  onToggleMicrophone,
  onToggleCamera,
  onToggleHand,
  onToggleScreenShare,
  onToggleReactions,
  onReact,
  onLeave,
}) {
  // Disabled rather than hidden: a button that vanishes teaches nothing, a
  // disabled one with a title says who has the lock.
  const shareBlocked = Boolean(screenTakenBy) && !isScreenSharing;
  const reactionsBlocked = !reactionsEnabled && !canToggleReactions;

  return (
    <footer className="controls">
      <button
        type="button"
        className={microphoneEnabled ? 'btn' : 'btn btn--off'}
        onClick={onToggleMicrophone}
        aria-pressed={!microphoneEnabled}
      >
        {microphoneEnabled ? 'Mute' : 'Unmute'}
      </button>

      <button
        type="button"
        className={cameraEnabled ? 'btn' : 'btn btn--off'}
        onClick={onToggleCamera}
        aria-pressed={!cameraEnabled}
      >
        {cameraEnabled ? 'Stop video' : 'Start video'}
      </button>

      <button
        type="button"
        className={handRaised ? 'btn btn--active' : 'btn'}
        onClick={onToggleHand}
        aria-pressed={handRaised}
      >
        {handRaised ? 'Lower hand' : 'Raise hand'}
      </button>

      {canScreenShare && (
        <button
          type="button"
          className={isScreenSharing ? 'btn btn--active' : 'btn'}
          onClick={onToggleScreenShare}
          disabled={shareBlocked}
          title={shareBlocked ? `${screenTakenBy} is sharing` : undefined}
        >
          {isScreenSharing ? 'Stop sharing' : 'Share screen'}
        </button>
      )}

      {canToggleReactions && (
        <button
          type="button"
          className={reactionsEnabled ? 'btn' : 'btn btn--off'}
          onClick={onToggleReactions}
          aria-pressed={!reactionsEnabled}
          title={
            reactionsEnabled
              ? 'Switch emoji reactions off for everyone else'
              : 'Switch emoji reactions back on for everyone'
          }
        >
          {reactionsEnabled ? 'Reactions: on' : 'Reactions: off'}
        </button>
      )}

      <div
        className="controls__reactions"
        title={reactionsBlocked ? 'The host has switched reactions off' : undefined}
      >
        {['👏', '👍', '❤️', '🎉'].map((emoji) => (
          <button
            key={emoji}
            type="button"
            className="btn btn--icon"
            onClick={() => onReact(emoji)}
            disabled={reactionsBlocked}
            aria-label={reactionsBlocked ? `React ${emoji} (switched off by the host)` : `React ${emoji}`}
          >
            {emoji}
          </button>
        ))}
      </div>

      <button type="button" className="btn btn--danger" onClick={onLeave}>
        Leave
      </button>
    </footer>
  );
}
__P2_EOF__
echo "wrote apps/web/src/components/Classroom/ControlBar.jsx"

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
for f in "${TOUCHED[@]}"; do
  case "$f" in
    *.js) node --check "$f" && echo "ok  $f" ;;
    *.ts) if [ -n "$ESBUILD" ]; then "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null && echo "ok  $f"; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null && echo "ok  $f"; else echo "--  $f (no esbuild to check)"; fi ;;
  esac
done

MAIN=$(grep -o '"main": *"[^"]*"' packages/contracts/package.json || true)
case "$MAIN" in
  *src/*) ;;
  *) echo; echo "Note: packages/contracts is loaded from a build ($MAIN). Rebuild it: npm run build -w @classroom/contracts" ;;
esac
echo
echo "Part 2 installed. The API restarts on its own; reload the browser tabs with Ctrl+Shift+R."