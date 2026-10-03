/**
 * The chat kit's pure helpers  (Messages · Community)
 *
 * Shared by every chat in the app; tested in __checks__/chatKitModel.check.mjs.
 */

import { DEFAULT_ACCEPT, extensionOf } from '../Files/filesModel.js';

export const QUICK_REACTIONS = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/** The full picker, grouped like on a phone. */
export const EMOJI_GROUPS = [
  { label: 'Smileys', emoji: ['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😋', '😛', '🤔', '🤨', '😐', '🙄', '😏', '😬', '😌', '😴', '🤯', '🥳', '😎', '🤓', '😕', '😟', '😮', '😲', '😳', '🥺', '😢', '😭', '😤', '😡'] },
  { label: 'Gestures', emoji: ['👍', '👎', '👏', '🙌', '👐', '🤝', '🙏', '✌️', '🤞', '🤟', '👌', '🤌', '👋', '💪', '✍️', '👀'] },
  { label: 'Hearts and symbols', emoji: ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '💔', '❣️', '💯', '✅', '❌', '❓', '❗', '⭐', '🔥', '✨', '🎉', '🎊', '💡'] },
  { label: 'Learning', emoji: ['📚', '📖', '📝', '✏️', '📐', '🧮', '🔬', '🧪', '🌍', '💻', '🎓', '🏆', '⏰', '📅', '☕', '🍕'] },
];

/** Files a chat accepts: everything uploads take, plus voice recordings. */
export const CHAT_ACCEPT = [...new Set([...DEFAULT_ACCEPT, 'webm', 'ogg'])];
export const MAX_FILES = 10;
export const MAX_FILE_BYTES = 50 * 1024 * 1024;

/** Why a file cannot be attached, or null. */
export const attachProblem = (file, { staged = 0, accept = CHAT_ACCEPT, maxBytes = MAX_FILE_BYTES } = {}) => {
  if (staged >= MAX_FILES) return `Up to ${MAX_FILES} files per message.`;
  const ext = extensionOf(file?.name);
  if (!ext || !accept.includes(ext)) return `${file?.name ?? 'This file'}: this type of file cannot be sent.`;
  if (!file.size) return `${file.name} is empty.`;
  if (file.size > maxBytes) return `${file.name} is larger than ${Math.round(maxBytes / 1024 / 1024)} MB.`;
  return null;
};

/** 0:07 · 1:05 · 12:00 */
export const formatDuration = (ms) => {
  const total = Math.max(0, Math.round((Number(ms) || 0) / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
};

/**
 * The recording format this browser can make, and the file extension the
 * upload checks know for it. Chrome/Edge: WebM · Firefox: Ogg · Safari: MP4.
 */
export const recorderFormat = (isTypeSupported) => {
  const supported = (type) => {
    try {
      return Boolean(isTypeSupported?.(type));
    } catch {
      return false;
    }
  };
  if (supported('audio/webm;codecs=opus')) return { mimeType: 'audio/webm;codecs=opus', ext: 'webm' };
  if (supported('audio/webm')) return { mimeType: 'audio/webm', ext: 'webm' };
  if (supported('audio/ogg;codecs=opus')) return { mimeType: 'audio/ogg;codecs=opus', ext: 'ogg' };
  if (supported('audio/mp4')) return { mimeType: 'audio/mp4', ext: 'm4a' };
  return null;
};

/** "Ann and You" · "Ann, Ben and 3 others" — the tooltip of a reaction. */
export const reactionTitle = ({ emoji, count = 0, names = [] }) => {
  if (!names.length) return `${count} reacted with ${emoji}`;
  const rest = count - names.length;
  const shown = rest > 0 ? [...names, `${rest} ${rest === 1 ? 'other' : 'others'}`] : names;
  const list = shown.length === 1 ? shown[0] : `${shown.slice(0, -1).join(', ')} and ${shown.at(-1)}`;
  return `${list} reacted with ${emoji}`;
};

/** Add if I have not reacted with it, remove if I have. */
export const toggleAction = (reactions = [], emoji) => (reactions.some((r) => r.emoji === emoji && r.reacted) ? 'remove' : 'add');

/** Pictures and videos as a grid, everything else as a list below it. */
export const splitFiles = (files = []) => ({
  visual: files.filter((f) => !f.voice && (f.kind === 'image' || f.kind === 'video')),
  voice: files.filter((f) => f.voice),
  other: files.filter((f) => !f.voice && f.kind !== 'image' && f.kind !== 'video'),
});

/** What a message with only files says in a preview or a reply chip. */
export const filesLabel = (files = []) => {
  if (!files.length) return '';
  if (files[0].voice) return `🎤 Voice message (${formatDuration(files[0].durationMs)})`;
  if (files.length > 1) return `📎 ${files.length} files`;
  const icon = { image: '🖼', video: '🎬', audio: '🎵' }[files[0].kind] ?? '📄';
  return `${icon} ${files[0].name}`;
};
