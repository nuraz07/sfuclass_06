/**
 * Pure helpers for the Messages page  (Messages)
 *
 * Tested in __checks__/messengerModel.check.mjs. The server decides what may
 * be edited, sent or seen; these only order, group and word things so the
 * page shows the same answer before it asks.
 */

const HOUR = 60 * 60 * 1000;

export const MUTE_CHOICES = [
  { id: '1h', label: 'For 1 hour', ms: HOUR },
  { id: '8h', label: 'For 8 hours', ms: 8 * HOUR },
  { id: '1d', label: 'For 1 day', ms: 24 * HOUR },
  { id: '1w', label: 'For 1 week', ms: 7 * 24 * HOUR },
  { id: 'on', label: 'Until I turn it back on', ms: null },
];

export const muteUntil = (choice, now = Date.now()) => (choice?.ms ? new Date(now + choice.ms).toISOString() : null);

export const REPORT_REASONS = [
  { value: 'harassment', label: 'Harassment or bullying' },
  { value: 'abuse', label: 'Abusive or hateful messages' },
  { value: 'spam', label: 'Spam' },
  { value: 'impersonation', label: 'Pretending to be someone else' },
  { value: 'nsfw', label: 'Sexual or shocking content' },
  { value: 'other', label: 'Something else' },
];

/** "MK" for "Mara Klein", "A" for "anna". */
export const initials = (name) => {
  const parts = String(name ?? '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  const letters = parts.length === 1 ? [parts[0][0]] : [parts[0][0], parts.at(-1)[0]];
  return letters.join('').toUpperCase();
};

/** A stable hue per person, so the same person always has the same colour. */
export const hueOf = (seed) => {
  let hash = 0;
  for (const char of String(seed ?? '')) hash = (hash * 31 + char.codePointAt(0)) >>> 0;
  return hash % 360;
};

/** Pinned first (most recently pinned on top), then by last activity. */
export const sortConversations = (list = []) => {
  const activity = (c) => Date.parse(c.lastMessageAt ?? c.createdAt) || 0;
  return [...list].sort((a, b) => {
    const pa = a.pinnedAt ? Date.parse(a.pinnedAt) : 0;
    const pb = b.pinnedAt ? Date.parse(b.pinnedAt) : 0;
    if (Boolean(pa) !== Boolean(pb)) return pa ? -1 : 1;
    if (pa && pb && pa !== pb) return pb - pa;
    return activity(b) - activity(a);
  });
};

/** Case- and accent-insensitive "contains". */
const fold = (text) => String(text ?? '').normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
export const matches = (text, query) => {
  const needle = fold(query).trim();
  return needle ? fold(text).includes(needle) : true;
};

/** Splits text around every match, for <mark>: [{ text, hit }]. */
export const highlightParts = (text, query) => {
  const source = String(text ?? '');
  const needle = fold(query).trim();
  if (!needle) return [{ text: source, hit: false }];
  const folded = fold(source);
  // Folding can change the length (ß, ligatures); highlight only when it did not.
  if (folded.length !== source.length) return [{ text: source, hit: folded.includes(needle) }];
  const parts = [];
  let at = 0;
  for (let index = folded.indexOf(needle); index !== -1; index = folded.indexOf(needle, index + needle.length)) {
    if (index > at) parts.push({ text: source.slice(at, index), hit: false });
    parts.push({ text: source.slice(index, index + needle.length), hit: true });
    at = index + needle.length;
  }
  if (at < source.length) parts.push({ text: source.slice(at), hit: false });
  return parts;
};

const startOfDay = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();

/** Today · Yesterday · Monday … for the last week · a date before that. */
export const dayLabel = (iso, now = new Date(), formatDate = (d) => d.toLocaleDateString()) => {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  const days = Math.round((startOfDay(now) - startOfDay(date)) / (24 * HOUR));
  if (days === 0) return 'Today';
  if (days === 1) return 'Yesterday';
  if (days > 1 && days < 7) return date.toLocaleDateString('en', { weekday: 'long' });
  return formatDate(date);
};

/** Messages of one author within this gap form one group (one name, one avatar). */
export const GROUP_GAP_MS = 5 * 60 * 1000;

/**
 * The thread as rows: day separators, and messages marked as the first or
 * last of a run by the same person.
 */
export const threadRows = (messages = []) => {
  const rows = [];
  let previous = null;
  let previousDay = null;
  for (const message of messages) {
    const date = new Date(message.createdAt);
    const day = Number.isNaN(date.getTime()) ? previousDay : startOfDay(date);
    if (day !== previousDay) {
      rows.push({ type: 'day', key: `day-${day}`, at: message.createdAt });
      previous = null;
      previousDay = day;
    }
    const authorId = message.author?.userId ?? null;
    const startsGroup =
      !previous || previous.author?.userId !== authorId || Date.parse(message.createdAt) - Date.parse(previous.createdAt) > GROUP_GAP_MS;
    if (!startsGroup && rows.at(-1)?.type === 'message') rows.at(-1).lastInGroup = false;
    rows.push({ type: 'message', key: message.clientMessageId ?? message.messageId, message, firstInGroup: startsGroup, lastInGroup: true });
    previous = message;
  }
  return rows;
};

/** Same rule as the server (conversationRules.canEdit): own, sent, not deleted, inside the window. */
export const canEdit = (message, { selfUserId, windowMin = 0, now = Date.now() } = {}) => {
  if (!message || message.author?.userId !== selfUserId || message.deletedAt || message.delivery !== 'sent') return false;
  // A message that is only files (or a voice message) has no text to edit.
  if (!String(message.body ?? '').trim()) return false;
  if (!windowMin || windowMin <= 0) return true;
  const created = Date.parse(message.createdAt);
  return !Number.isNaN(created) && now - created <= windowMin * 60_000;
};

export const canDelete = (message, { selfUserId } = {}) =>
  Boolean(message) && message.author?.userId === selfUserId && !message.deletedAt && message.delivery === 'sent';

/** The newest message the person can still edit — what ↑ in an empty composer opens. */
export const lastEditable = (messages = [], options = {}) => {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (canEdit(messages[index], options)) return messages[index];
  }
  return null;
};

/** Ids of the messages whose text matches, oldest first. */
export const searchHits = (messages = [], query = '') =>
  query.trim() ? messages.filter((m) => !m.deletedAt && matches(m.body, query)).map((m) => m.messageId) : [];

/** "Muted until 14:30" or "Muted", or null. */
export const muteState = (item, now = Date.now()) => {
  if (!item?.muted) return null;
  if (!item.mutedUntil) return { forever: true };
  const until = Date.parse(item.mutedUntil);
  return until > now ? { until: item.mutedUntil } : null;
};

/** The first line of a message, for a reply chip or quote. */
export const snippet = (body, max = 90) => {
  const line = String(body ?? '').replace(/\s+/g, ' ').trim();
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
};
