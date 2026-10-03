// classroom-app/server/src/messaging/chatExtrasRules.js
/**
 * Rules for reactions, attachments and voice messages  (Messages)
 *
 * Pure, tested in server/test/messaging/chatExtrasRules.check.mjs, and shared
 * with the community chat (step 2), so both chats follow the same rules.
 */

export const MAX_FILES_PER_MESSAGE = 10;
export const MAX_VOICE_MS = 15 * 60 * 1000;
export const MAX_REACTIONS_PER_PERSON = 12;
export const MEDIA_KINDS = ['media', 'files', 'voice'];

/**
 * One emoji (with its skin tone, flags and ZWJ sequences), nothing else:
 * no text, no markup. At most 16 code units, like the column.
 */
export const isEmoji = (value) => {
  const text = String(value ?? '');
  if (!text || text.length > 16 || /\s/.test(text)) return false;
  if (/^[0-9#*]\ufe0f?\u20e3$/u.test(text)) return true; // keycaps: 1️⃣ #️⃣
  if (!/\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(text)) return false;
  // Every code point has to belong to an emoji sequence.
  return /^(?:\p{Extended_Pictographic}|\p{Emoji_Modifier}|\p{Emoji_Component}|\p{Regional_Indicator}|\u200d|\ufe0f|\u20e3)+$/u.test(text);
};

/** Rows of (emoji, user_id, display_name) → the per-message summary the client shows. */
export const summariseReactions = (rows = [], viewerId = null) => {
  const byEmoji = new Map();
  for (const row of rows) {
    const entry = byEmoji.get(row.emoji) ?? { emoji: row.emoji, count: 0, reacted: false, names: [], first: row.created_at };
    entry.count += 1;
    if (row.user_id === viewerId) entry.reacted = true;
    if (entry.names.length < 10) entry.names.push(row.user_id === viewerId ? 'You' : row.display_name ?? 'Someone');
    if (row.created_at && (!entry.first || new Date(row.created_at) < new Date(entry.first))) entry.first = row.created_at;
    byEmoji.set(row.emoji, entry);
  }
  return [...byEmoji.values()]
    .sort((a, b) => b.count - a.count || new Date(a.first ?? 0) - new Date(b.first ?? 0))
    .slice(0, 20)
    .map(({ first, ...rest }) => rest);
};

/** Which gallery tab a file belongs to. */
export const galleryKindOf = (file) => {
  if (file.voice_duration_ms !== null && file.voice_duration_ms !== undefined) return 'voice';
  if (file.kind === 'image' || file.kind === 'video') return 'media';
  return 'files';
};

/** The duration the client claims, kept within bounds. */
export const voiceDuration = (value) => {
  const ms = Math.round(Number(value));
  if (!Number.isFinite(ms) || ms < 0) return 0;
  return Math.min(ms, MAX_VOICE_MS);
};

export default { MAX_FILES_PER_MESSAGE, MAX_VOICE_MS, MAX_REACTIONS_PER_PERSON, MEDIA_KINDS, isEmoji, summariseReactions, galleryKindOf, voiceDuration };
