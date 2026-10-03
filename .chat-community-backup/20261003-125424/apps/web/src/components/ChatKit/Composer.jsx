import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { uploadFile } from '../../lib/files.js';
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { CHAT_ACCEPT, attachProblem, formatDuration, recorderFormat } from './chatKitModel.js';

/**
 * The composer  (chat kit)
 *
 *   text        Enter sends, Shift+Enter is a new line; grows up to six lines
 *   files       📎, drag-and-drop onto the chat, or paste; each uploads at once
 *               through the normal upload checks and shows its progress; the
 *               message can be sent when all are ready
 *   voice       🎤 when there is nothing to send: records, shows the time, and
 *               sends or cancels; the recording is an ordinary upload too
 *
 * The caller decides what "send" means (onSend({ body, files, voice })), so the
 * same composer serves Messages and the community chat.
 */

const MAX_VOICE_MS = 15 * 60 * 1000;

let stagedSeq = 0;

export function useAttachments(files) {
  const [staged, setStaged] = useState([]);
  const controllers = useRef(new Map());

  // The current list, for add(): a state updater has to stay pure (React may
  // run it twice in development), so uploads are started from here instead.
  const stagedRef = useRef([]);
  useEffect(() => {
    stagedRef.current = staged;
  }, [staged]);

  const add = useCallback(
    (list) => {
      const errors = [];
      const picked = [];
      let count = stagedRef.current.length;
      for (const file of list) {
        const problem = attachProblem(file, { staged: count });
        if (problem) {
          errors.push(problem);
          continue;
        }
        count += 1;
        picked.push({ id: `s${(stagedSeq += 1)}`, file, progress: 0, phase: 'starting', result: null, error: null });
      }
      if (!picked.length) return errors;
      stagedRef.current = [...stagedRef.current, ...picked];
      setStaged((current) => [...current, ...picked]);
      for (const item of picked) {
        const controller = new AbortController();
        controllers.current.set(item.id, controller);
        const patch = (change) => setStaged((current) => current.map((s) => (s.id === item.id ? { ...s, ...change } : s)));
        uploadFile({ files, file: item.file, signal: controller.signal, onProgress: (progress) => patch({ progress }), onPhase: (phase) => patch({ phase }) })
          .then((result) => patch({ result, phase: 'ready', progress: 1 }))
          .catch((cause) => !controller.signal.aborted && patch({ error: cause.message, phase: 'failed' }))
          .finally(() => controllers.current.delete(item.id));
      }
      return errors;
    },
    [files],
  );

  const remove = useCallback((id) => {
    controllers.current.get(id)?.abort();
    stagedRef.current = stagedRef.current.filter((s) => s.id !== id);
    setStaged((current) => current.filter((s) => s.id !== id));
  }, []);

  const clear = useCallback(() => {
    for (const controller of controllers.current.values()) controller.abort();
    controllers.current.clear();
    stagedRef.current = [];
    setStaged([]);
  }, []);

  useEffect(() => () => controllers.current.forEach((c) => c.abort()), []);

  const ready = staged.filter((s) => s.result).map((s) => s.result);
  const busy = staged.some((s) => !s.result && !s.error);
  return { staged, add, remove, clear, ready, busy };
}

function useRecorder() {
  const [state, setState] = useState('idle'); // idle · recording · sending
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState(null);
  const recorder = useRef(null);
  const chunks = useRef([]);
  const startedAt = useRef(0);
  const stream = useRef(null);
  const timer = useRef(null);
  const resolveStop = useRef(null);

  const release = () => {
    window.clearInterval(timer.current);
    stream.current?.getTracks().forEach((track) => track.stop());
    stream.current = null;
  };
  useEffect(() => () => release(), []);

  const start = async () => {
    setError(null);
    const format = recorderFormat(globalThis.MediaRecorder?.isTypeSupported?.bind(globalThis.MediaRecorder));
    if (!format || !navigator.mediaDevices?.getUserMedia) {
      setError('This browser cannot record voice messages.');
      return;
    }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    } catch {
      setError('The microphone is not available. Allow it in the browser and try again.');
      return;
    }
    chunks.current = [];
    const rec = new MediaRecorder(stream.current, { mimeType: format.mimeType, audioBitsPerSecond: 48_000 });
    rec.ondataavailable = (event) => event.data?.size && chunks.current.push(event.data);
    rec.onstop = () => {
      const durationMs = Date.now() - startedAt.current;
      const blob = new Blob(chunks.current, { type: format.mimeType.split(';')[0] });
      release();
      resolveStop.current?.({ blob, durationMs, ext: format.ext });
    };
    recorder.current = rec;
    startedAt.current = Date.now();
    rec.start(250);
    setElapsed(0);
    setState('recording');
    timer.current = window.setInterval(() => {
      const ms = Date.now() - startedAt.current;
      setElapsed(ms);
      if (ms >= MAX_VOICE_MS) recorder.current?.state === 'recording' && recorder.current.stop();
    }, 200);
  };

  const stop = () =>
    new Promise((resolve) => {
      resolveStop.current = resolve;
      if (recorder.current?.state === 'recording') recorder.current.stop();
      else resolve(null);
    });

  const cancel = () => {
    resolveStop.current = null;
    if (recorder.current?.state === 'recording') recorder.current.stop();
    release();
    setState('idle');
  };

  return { state, setState, elapsed, error, setError, start, stop, cancel };
}

export default function Composer({ files, placeholder, disabled = false, disabledReason = '', onSend, onTyping, onArrowUp, onEscape, top = null, inputRef: externalRef = null, hint = true }) {
  const [draft, setDraft] = useState('');
  const [notice, setNotice] = useState(null);
  const [dragging, setDragging] = useState(false);
  const ownRef = useRef(null);
  const inputRef = externalRef ?? ownRef;
  const pickerRef = useRef(null);
  const attachments = useAttachments(files);
  const voice = useRecorder();

  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 180)}px`;
  }, [draft, inputRef]);

  const addFiles = (list) => {
    const errors = attachments.add([...list]);
    setNotice(errors.length ? errors.join(' ') : null);
  };

  // Drop onto the chat area (the composer's parent listens through these).
  useEffect(() => {
    const area = inputRef.current?.closest('[data-ck-dropzone]');
    if (!area || disabled) return undefined;
    let depth = 0;
    const hasFiles = (event) => [...(event.dataTransfer?.types ?? [])].includes('Files');
    const enter = (event) => hasFiles(event) && (depth += 1, setDragging(true), event.preventDefault());
    const over = (event) => hasFiles(event) && event.preventDefault();
    const leave = () => (depth = Math.max(0, depth - 1)) === 0 && setDragging(false);
    const drop = (event) => {
      if (!hasFiles(event)) return;
      event.preventDefault();
      depth = 0;
      setDragging(false);
      addFiles(event.dataTransfer.files);
    };
    area.addEventListener('dragenter', enter);
    area.addEventListener('dragover', over);
    area.addEventListener('dragleave', leave);
    area.addEventListener('drop', drop);
    return () => {
      area.removeEventListener('dragenter', enter);
      area.removeEventListener('dragover', over);
      area.removeEventListener('dragleave', leave);
      area.removeEventListener('drop', drop);
    };
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const canSend = !disabled && !attachments.busy && (draft.trim() || attachments.ready.length) && voice.state === 'idle';

  const send = async () => {
    if (!canSend) return;
    const body = draft.trim();
    const ready = attachments.ready;
    setDraft('');
    attachments.clear();
    onTyping?.(false);
    setNotice(null);
    try {
      await onSend({ body, files: ready });
    } catch (cause) {
      setNotice(cause?.detail ?? cause?.message ?? 'Not sent.');
    }
  };

  const sendVoice = async () => {
    const recording = await voice.stop();
    if (!recording) return;
    if (recording.durationMs < 700 || recording.blob.size === 0) {
      voice.setState('idle');
      setNotice('That was too short. Hold on a little longer.');
      return;
    }
    voice.setState('sending');
    try {
      const file = new File([recording.blob], `Voice message.${recording.ext}`, { type: recording.blob.type });
      const uploaded = await uploadFile({ files, file });
      await onSend({ body: '', files: [uploaded], voice: { durationMs: Math.round(recording.durationMs) } });
      setNotice(null);
    } catch (cause) {
      setNotice(cause?.message ?? 'The voice message was not sent.');
    } finally {
      voice.setState('idle');
    }
  };

  const showMic = !draft.trim() && attachments.staged.length === 0;

  return (
    <div className={`ck-composer${dragging ? ' is-dragging' : ''}`}>
      {dragging ? <div className="ck-dropveil">Drop to attach</div> : null}
      {disabledReason ? <p className="ck-composer__notice">{disabledReason}</p> : null}
      {top}
      {attachments.staged.length ? (
        <ul className="ck-tray" aria-label="Attachments">
          {attachments.staged.map((item) => (
            <li key={item.id} className={`ck-tray__item${item.error ? ' is-failed' : ''}${item.result ? ' is-ready' : ''}`}>
              <span className="ck-tray__icon" aria-hidden="true">{iconFor(item.result?.kind ?? 'document')}</span>
              <span className="ck-tray__text">
                <span className="ck-tray__name" title={item.file.name}>{item.file.name}</span>
                <span className="ck-tray__meta">
                  {item.error ? item.error : item.result ? fileMeta(item.result) : item.phase === 'checking' ? 'Checking…' : `${Math.round(item.progress * 100)} %`}
                </span>
                {!item.result && !item.error ? <i className="ck-tray__bar" style={{ transform: `scaleX(${item.progress})` }} /> : null}
              </span>
              <button type="button" onClick={() => attachments.remove(item.id)} aria-label={`Remove ${item.file.name}`}>×</button>
            </li>
          ))}
        </ul>
      ) : null}
      {notice || voice.error ? (
        <p className="ck-composer__error" role="alert">
          {notice ?? voice.error}
          <button type="button" onClick={() => (setNotice(null), voice.setError(null))} aria-label="Dismiss">×</button>
        </p>
      ) : null}

      {voice.state === 'idle' ? (
        <form
          className="ck-composer__row"
          onSubmit={(event) => {
            event.preventDefault();
            send();
          }}
        >
          <button type="button" className="ck-round ck-round--ghost" onClick={() => pickerRef.current?.click()} disabled={disabled} aria-label="Attach files" title="Attach files">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16.5 6.5l-7.8 7.8a2 2 0 102.8 2.8l7.8-7.8a4 4 0 10-5.7-5.7l-8 8a6 6 0 108.5 8.5l6.6-6.6" /></svg>
          </button>
          <input ref={pickerRef} type="file" multiple hidden accept={CHAT_ACCEPT.map((ext) => `.${ext}`).join(',')} onChange={(event) => (addFiles(event.target.files), (event.target.value = ''))} />
          <textarea
            ref={inputRef}
            rows={1}
            value={draft}
            maxLength={4000}
            placeholder={placeholder}
            aria-label={placeholder}
            disabled={disabled}
            onChange={(event) => {
              setDraft(event.target.value);
              onTyping?.(event.target.value.length > 0);
            }}
            onPaste={(event) => {
              const pasted = [...(event.clipboardData?.files ?? [])];
              if (pasted.length) {
                event.preventDefault();
                addFiles(pasted);
              }
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                send();
              } else if (event.key === 'ArrowUp' && !draft && onArrowUp?.()) {
                event.preventDefault();
              } else if (event.key === 'Escape') {
                onEscape?.();
              }
            }}
          />
          {showMic ? (
            <button type="button" className="ck-round ck-round--accent" onClick={voice.start} disabled={disabled} aria-label="Record a voice message" title="Record a voice message">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15a3 3 0 003-3V6a3 3 0 10-6 0v6a3 3 0 003 3zm5-3a5 5 0 01-10 0H5a7 7 0 006 6.9V21h2v-2.1A7 7 0 0019 12h-2z" /></svg>
            </button>
          ) : (
            <button type="submit" className="ck-round ck-round--accent" disabled={!canSend} aria-label={attachments.busy ? 'Uploading…' : 'Send'} title={attachments.busy ? 'Waiting for the upload' : 'Send'}>
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12l16-8-6 16-2.5-6.5L4 12z" /></svg>
            </button>
          )}
        </form>
      ) : (
        <div className="ck-recording" role="group" aria-label="Voice message">
          <button type="button" className="ck-round ck-round--ghost" onClick={voice.cancel} disabled={voice.state === 'sending'} aria-label="Cancel voice message" title="Cancel">
            🗑
          </button>
          <span className="ck-recording__dot" aria-hidden="true" />
          <span className="ck-recording__time" aria-live="off">{formatDuration(voice.elapsed)}</span>
          <span className="ck-recording__label">{voice.state === 'sending' ? 'Sending…' : 'Recording'}</span>
          <button type="button" className="ck-round ck-round--accent" onClick={sendVoice} disabled={voice.state === 'sending'} aria-label="Send voice message" title="Send">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12l16-8-6 16-2.5-6.5L4 12z" /></svg>
          </button>
        </div>
      )}
      {hint ? <p className="ck-composer__hint">Enter to send · Shift+Enter for a new line · drop files to attach</p> : null}
    </div>
  );
}
