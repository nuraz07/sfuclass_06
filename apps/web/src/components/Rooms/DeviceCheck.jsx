import { useCallback, useEffect, useRef, useState } from 'react';
import { mediaConstraints } from '../../lib/preferences.js';

/**
 * Camera and microphone check before entering  (Rooms)
 *
 * The same capture settings the lesson will use (Settings → Lessons), so a
 * check that works here means the lesson will too. Starts only on request:
 * nobody's camera turns on just because they opened a link.
 */
export default function DeviceCheck() {
  const videoRef = useRef(null);
  const streamRef = useRef(null);
  const audioRef = useRef({ context: null, frame: 0 });
  const [running, setRunning] = useState(false);
  const [level, setLevel] = useState(0);
  const [error, setError] = useState(null);

  const stop = useCallback(() => {
    cancelAnimationFrame(audioRef.current.frame);
    audioRef.current.context?.close().catch(() => undefined);
    audioRef.current = { context: null, frame: 0 };
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    setRunning(false);
    setLevel(0);
  }, []);

  const start = useCallback(async () => {
    setError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia(mediaConstraints({ audio: true, video: true }));
      streamRef.current = stream;
      if (videoRef.current) videoRef.current.srcObject = stream;
      const AudioContextClass = window.AudioContext ?? window.webkitAudioContext;
      if (AudioContextClass && stream.getAudioTracks().length) {
        const context = new AudioContextClass();
        const analyser = context.createAnalyser();
        analyser.fftSize = 512;
        context.createMediaStreamSource(stream).connect(analyser);
        const data = new Uint8Array(analyser.fftSize);
        const tick = () => {
          analyser.getByteTimeDomainData(data);
          let peak = 0;
          for (const value of data) peak = Math.max(peak, Math.abs(value - 128));
          setLevel(Math.min(1, peak / 64));
          audioRef.current.frame = requestAnimationFrame(tick);
        };
        audioRef.current = { context, frame: requestAnimationFrame(tick) };
      }
      setRunning(true);
    } catch (cause) {
      setError(
        cause?.name === 'NotAllowedError'
          ? 'Your browser was not allowed to use the camera and microphone. Allow it in the address bar.'
          : cause?.name === 'NotFoundError'
            ? 'No camera or microphone was found. You can still join and listen.'
            : 'The check could not start. Is another app using the camera?',
      );
      stop();
    }
  }, [stop]);

  useEffect(() => stop, [stop]);

  return (
    <div className="rm-device">
      <video ref={videoRef} className="rm-device__video" autoPlay playsInline muted aria-label="Camera preview" />
      <div className="rm-device__side">
        <div className="rm-meter" role="meter" aria-label="Microphone level" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(level * 100)}>
          <span style={{ width: `${Math.round(level * 100)}%` }} />
        </div>
        <p className="rm-hint">{running ? 'Say something: the bar should move.' : 'Check your camera and microphone before you go in.'}</p>
        <button type="button" className="btn btn--tiny" onClick={running ? stop : start}>
          {running ? 'Stop check' : 'Check camera and microphone'}
        </button>
        {error ? <p className="rm-error">{error}</p> : null}
      </div>
    </div>
  );
}
