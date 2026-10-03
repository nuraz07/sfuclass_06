import { useEffect, useRef, useState } from 'react';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDuration, splitFiles } from './chatKitModel.js';

/**
 * Files in a message  (chat kit)
 *
 * Pictures and videos as a grid (a picture opens large on click), voice
 * messages as a player, everything else as a card with Open or Download.
 * Links are signed for two hours; a page left open longer reloads them.
 */

export function VoicePlayer({ src, durationMs = 0, mine = false }) {
  const audio = useRef(null);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [length, setLength] = useState(durationMs / 1000);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const el = audio.current;
    if (!el) return undefined;
    const onTime = () => setPosition(el.currentTime);
    const onMeta = () => Number.isFinite(el.duration) && el.duration > 0 && setLength(el.duration);
    const onEnd = () => {
      setPlaying(false);
      setPosition(0);
    };
    const onPause = () => setPlaying(false);
    const onPlay = () => setPlaying(true);
    el.addEventListener('timeupdate', onTime);
    el.addEventListener('loadedmetadata', onMeta);
    el.addEventListener('ended', onEnd);
    el.addEventListener('pause', onPause);
    el.addEventListener('play', onPlay);
    return () => {
      el.removeEventListener('timeupdate', onTime);
      el.removeEventListener('loadedmetadata', onMeta);
      el.removeEventListener('ended', onEnd);
      el.removeEventListener('pause', onPause);
      el.removeEventListener('play', onPlay);
    };
  }, []);

  const toggle = async () => {
    const el = audio.current;
    if (!el) return;
    if (playing) return el.pause();
    // One voice message at a time, like any messenger.
    document.querySelectorAll('audio[data-ck-voice]').forEach((other) => other !== el && other.pause());
    try {
      await el.play();
    } catch {
      setFailed(true);
    }
    return undefined;
  };

  const seek = (event) => {
    const el = audio.current;
    if (!el || !length) return;
    const box = event.currentTarget.getBoundingClientRect();
    el.currentTime = Math.min(length, Math.max(0, ((event.clientX - box.left) / box.width) * length));
  };

  const share = length ? Math.min(1, position / length) : 0;
  return (
    <div className={`ck-voice${mine ? ' is-mine' : ''}`}>
      <audio ref={audio} src={src} preload="metadata" data-ck-voice onError={() => setFailed(true)} />
      <button type="button" className="ck-voice__play" onClick={toggle} aria-label={playing ? 'Pause voice message' : 'Play voice message'} disabled={failed}>
        {playing ? '❚❚' : '▶'}
      </button>
      <div className="ck-voice__track" onClick={seek} role="slider" tabIndex={0} aria-label="Position" aria-valuemin={0} aria-valuemax={Math.round(length)} aria-valuenow={Math.round(position)}
        onKeyDown={(event) => {
          const el = audio.current;
          if (!el) return;
          if (event.key === 'ArrowRight') el.currentTime = Math.min(length, el.currentTime + 5);
          if (event.key === 'ArrowLeft') el.currentTime = Math.max(0, el.currentTime - 5);
        }}
      >
        <i style={{ transform: `scaleX(${share})` }} />
      </div>
      <span className="ck-voice__time">{failed ? 'Unavailable' : formatDuration((playing || position ? position : length) * 1000)}</span>
    </div>
  );
}

function Lightbox({ file, onClose }) {
  const ref = useRef(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog && !dialog.open) dialog.showModal?.();
    const onCancel = (event) => {
      event.preventDefault();
      onClose();
    };
    dialog?.addEventListener('cancel', onCancel);
    return () => dialog?.removeEventListener('cancel', onCancel);
  }, [onClose]);
  const href = fileHref(file.openUrl);
  return (
    <dialog ref={ref} className="ck-lightbox" aria-label={file.name} onClick={(event) => event.target === ref.current && onClose()}>
      <div className="ck-lightbox__bar">
        <span>{file.name}</span>
        <span>
          <a href={href} target="_blank" rel="noopener noreferrer">Open</a>
          <button type="button" onClick={onClose} aria-label="Close">×</button>
        </span>
      </div>
      <img src={href} alt={file.name} />
    </dialog>
  );
}

export default function MessageFiles({ files = [], mine = false }) {
  const [large, setLarge] = useState(null);
  if (!files.length) return null;
  const { visual, voice, other } = splitFiles(files);
  return (
    <div className="ck-files">
      {visual.length ? (
        <div className={`ck-grid ck-grid--${Math.min(visual.length, 4)}`}>
          {visual.slice(0, 4).map((file, index) => {
            const href = file.openUrl ? fileHref(file.openUrl) : null;
            const more = index === 3 && visual.length > 4 ? visual.length - 4 : 0;
            if (!href) return <span key={file.fileId} className="ck-grid__gone">No longer available</span>;
            return file.kind === 'image' ? (
              <button key={file.fileId} type="button" className="ck-grid__item" onClick={() => setLarge(file)} aria-label={`Open ${file.name}`}>
                <img src={href} alt={file.name} loading="lazy" decoding="async" />
                {more ? <span className="ck-grid__more">+{more}</span> : null}
              </button>
            ) : (
              <span key={file.fileId} className="ck-grid__item">
                <video src={href} controls preload="metadata" playsInline />
              </span>
            );
          })}
        </div>
      ) : null}
      {voice.map((file) => (file.openUrl ? <VoicePlayer key={file.fileId} src={fileHref(file.openUrl)} durationMs={file.durationMs ?? 0} mine={mine} /> : null))}
      {other.map((file) => {
        const href = file.openUrl ? fileHref(file.openUrl) : null;
        return (
          <div key={file.fileId} className="ck-doc">
            <span className="ck-doc__icon" aria-hidden="true">{iconFor(file.kind)}</span>
            <span className="ck-doc__text">
              <span className="ck-doc__name" title={file.name}>{file.name}</span>
              <span className="ck-doc__meta">{fileMeta(file)}</span>
            </span>
            {file.kind === 'audio' && href ? <audio src={href} controls preload="none" className="ck-doc__audio" /> : null}
            {href ? (
              <a className="ck-doc__open" href={href} target="_blank" rel="noopener noreferrer">
                {file.inline ? 'Open' : 'Download'}
              </a>
            ) : (
              <span className="ck-doc__meta">Unavailable</span>
            )}
          </div>
        );
      })}
      {large ? <Lightbox file={large} onClose={() => setLarge(null)} /> : null}
    </div>
  );
}
