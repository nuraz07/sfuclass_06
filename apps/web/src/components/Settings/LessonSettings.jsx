import { useCallback, useEffect, useRef, useState } from 'react';
import { Choice, Section, Toggle } from './fields.jsx';
import { mediaConstraints, readDevices, writeDevices } from '../../lib/preferences.js';

/**
 * Lessons: how you join, how your audio is processed, and a test of camera,
 * microphone and speaker with the exact settings a lesson will use
 * (lib/preferences.mediaConstraints) — so a test that works here means the
 * lesson will work the same way.
 */
export default function LessonSettings({ preferences, savePreferences }) {
  const lesson = preferences.lesson;
  return (
    <>
      <Section id="join" title="When you join a lesson">
        <Choice
          label="Microphone"
          value={lesson.joinMicrophone}
          options={[
            { value: 'off', title: 'Off — I unmute when I want to speak', hint: 'Recommended.' },
            { value: 'on', title: 'On' },
          ]}
          onChange={(value) => savePreferences('lesson', { joinMicrophone: value }, 'Microphone when joining')}
        />
        <Choice
          label="Camera"
          value={lesson.joinCamera}
          options={[
            { value: 'on', title: 'On' },
            { value: 'off', title: 'Off — I start it when I want to' },
          ]}
          onChange={(value) => savePreferences('lesson', { joinCamera: value }, 'Camera when joining')}
        />
        <p className="st-hint">
          If the teacher has set their lesson to start with everyone muted, your microphone starts off either way.
        </p>
      </Section>

      <Section id="audio" title="Sound">
        <Toggle
          label="Noise suppression"
          hint="Filters out keyboard, fan and street noise."
          checked={lesson.noiseSuppression}
          onChange={(value) => savePreferences('lesson', { noiseSuppression: value }, 'Noise suppression')}
        />
        <Toggle
          label="Echo cancellation"
          hint="Keep this on unless you use a headset and a professional microphone."
          checked={lesson.echoCancellation}
          onChange={(value) => savePreferences('lesson', { echoCancellation: value }, 'Echo cancellation')}
        />
      </Section>

      <Section title="Connection">
        <Toggle
          id="data-saver"
          label="Data saver"
          hint="Sends your video in lower quality (360p, 15 frames per second). Good on mobile data or a weak connection."
          checked={lesson.dataSaver}
          onChange={(value) => savePreferences('lesson', { dataSaver: value }, 'Data saver')}
        />
      </Section>

      <DeviceTest lesson={lesson} />
    </>
  );
}

const canPickSpeaker = () =>
  typeof HTMLMediaElement !== 'undefined' && typeof HTMLMediaElement.prototype.setSinkId === 'function';

function DeviceTest({ lesson }) {
  const [devices, setDevices] = useState({ cameras: [], microphones: [], speakers: [] });
  const [chosen, setChosen] = useState(readDevices);
  const [running, setRunning] = useState(false);
  const [level, setLevel] = useState(0);
  const [error, setError] = useState(null);

  const videoRef = useRef(null);
  const streamRef = useRef(null);
  const audioRef = useRef({ context: null, frame: 0 });

  const listDevices = useCallback(async () => {
    const all = await navigator.mediaDevices.enumerateDevices();
    const named = (kind, fallback) =>
      all.filter((d) => d.kind === kind).map((d, i) => ({ id: d.deviceId, label: d.label || `${fallback} ${i + 1}` }));
    setDevices({
      cameras: named('videoinput', 'Camera'),
      microphones: named('audioinput', 'Microphone'),
      speakers: named('audiooutput', 'Speaker'),
    });
  }, []);

  const stop = useCallback(() => {
    cancelAnimationFrame(audioRef.current.frame);
    audioRef.current.context?.close().catch(() => undefined);
    audioRef.current = { context: null, frame: 0 };
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    setLevel(0);
    setRunning(false);
  }, []);

  const start = useCallback(async () => {
    stop();
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
      await listDevices(); // labels are only available after permission
    } catch (cause) {
      setError(
        cause?.name === 'NotAllowedError'
          ? 'The browser was not allowed to use your camera and microphone. Allow it in the address bar and try again.'
          : cause?.name === 'NotFoundError'
            ? 'No camera or microphone was found.'
            : 'The test could not start. Check that no other app is using your camera.',
      );
      stop();
    }
  }, [listDevices, stop]);

  useEffect(() => {
    if (navigator.mediaDevices?.enumerateDevices) listDevices().catch(() => undefined);
    return stop;
  }, [listDevices, stop]);

  // Settings that change the capture restart a running test with them.
  const restartKey = `${chosen.cameraId}|${chosen.microphoneId}|${lesson.noiseSuppression}|${lesson.echoCancellation}|${lesson.dataSaver}`;
  const firstRun = useRef(true);
  useEffect(() => {
    if (firstRun.current) {
      firstRun.current = false;
      return;
    }
    if (running) start();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [restartKey]);

  const choose = (patch) => setChosen(writeDevices(patch));

  const playTone = async () => {
    const AudioContextClass = window.AudioContext ?? window.webkitAudioContext;
    if (!AudioContextClass) return;
    const context = new AudioContextClass();
    const oscillator = context.createOscillator();
    const gain = context.createGain();
    oscillator.frequency.value = 523.25;
    gain.gain.setValueAtTime(0.0001, context.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.2, context.currentTime + 0.05);
    gain.gain.exponentialRampToValueAtTime(0.0001, context.currentTime + 0.9);
    oscillator.connect(gain);

    if (chosen.speakerId && canPickSpeaker()) {
      const destination = context.createMediaStreamDestination();
      gain.connect(destination);
      const audio = new Audio();
      audio.srcObject = destination.stream;
      await audio.setSinkId(chosen.speakerId).catch(() => undefined);
      await audio.play().catch(() => undefined);
    } else {
      gain.connect(context.destination);
    }
    oscillator.start();
    oscillator.stop(context.currentTime + 1);
    oscillator.onended = () => context.close().catch(() => undefined);
  };

  const noDevices = !navigator.mediaDevices?.getUserMedia;

  return (
    <Section
      id="devices"
      title="Camera, microphone and speaker"
      hint="Camera and microphone choices are remembered on this device and used in your lessons, with the sound settings above. Lessons play sound through your system's default output."
    >
      {noDevices ? <p className="st-error">This browser cannot use a camera or microphone.</p> : null}

      <div className="st-devices">
        <video ref={videoRef} className="st-devices__preview" autoPlay playsInline muted aria-label="Camera preview" />

        <div className="st-devices__controls">
          <label className="st-label">
            Camera
            <select className="st-select" value={chosen.cameraId ?? ''} onChange={(e) => choose({ cameraId: e.target.value || null })}>
              <option value="">Default</option>
              {devices.cameras.map((d) => (
                <option key={d.id} value={d.id}>{d.label}</option>
              ))}
            </select>
          </label>

          <label className="st-label">
            Microphone
            <select className="st-select" value={chosen.microphoneId ?? ''} onChange={(e) => choose({ microphoneId: e.target.value || null })}>
              <option value="">Default</option>
              {devices.microphones.map((d) => (
                <option key={d.id} value={d.id}>{d.label}</option>
              ))}
            </select>
          </label>

          <div className="st-meter" role="meter" aria-label="Microphone level" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(level * 100)}>
            <span className="st-meter__bar" style={{ width: `${Math.round(level * 100)}%` }} />
          </div>
          <p className="st-hint">{running ? 'Speak: the bar should move.' : 'Start the test to see your camera and microphone level.'}</p>

          {canPickSpeaker() ? (
            <label className="st-label">
              Speaker for the test sound
              <select className="st-select" value={chosen.speakerId ?? ''} onChange={(e) => choose({ speakerId: e.target.value || null })}>
                <option value="">Default</option>
                {devices.speakers.map((d) => (
                  <option key={d.id} value={d.id}>{d.label}</option>
                ))}
              </select>
            </label>
          ) : null}

          <div className="st-inline">
            <button type="button" className="btn" onClick={running ? stop : start} disabled={noDevices}>
              {running ? 'Stop test' : 'Start test'}
            </button>
            <button type="button" className="btn btn--tiny" onClick={playTone}>
              Play test sound
            </button>
          </div>
          {error ? <p className="st-error">{error}</p> : null}
        </div>
      </div>
    </Section>
  );
}
