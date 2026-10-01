/**
 * Pure helpers for the community pages  (Community, part 1)
 * Tested in __checks__/hubModel.check.mjs. The server decides what is
 * allowed; these only shape forms and words.
 */

export const KINDS = [
  { value: 'topic', label: 'Topic space', hint: 'An interest or subject: open to everyone who cares about it.' },
  { value: 'study', label: 'Study group', hint: 'Up to 12 people working towards something, with an end date.' },
  { value: 'class', label: 'Class space', hint: 'For a class or course you teach. Teachers only.' },
];

export const ACCESS = [
  { value: 'open', label: 'Open', hint: 'Anyone in your organisation can read and join.' },
  { value: 'request', label: 'Ask to join', hint: 'Anyone can find it; you admit people.' },
  { value: 'invite', label: 'Invite only', hint: 'Invisible to everyone you have not added.' },
];

export const KIND_LABEL = { topic: 'Topic', study: 'Study group', class: 'Class' };
export const ROLE_LABEL = { owner: 'Owner', moderator: 'Moderator', member: 'Member' };
export const REPORT_REASONS = [
  { value: 'harassment', label: 'Harassment or bullying' },
  { value: 'hate', label: 'Hateful content' },
  { value: 'inappropriate', label: 'Inappropriate content' },
  { value: 'spam', label: 'Spam or advertising' },
  { value: 'off-topic', label: 'Off-topic' },
  { value: 'other', label: 'Something else' },
];

export const TIMEOUTS = [
  { minutes: 60, label: '1 hour' },
  { minutes: 24 * 60, label: '1 day' },
  { minutes: 7 * 24 * 60, label: '1 week' },
];

export const emptySpaceForm = () => ({
  name: '',
  description: '',
  kind: 'topic',
  access: 'open',
  memberList: 'members',
  joinQuestion: '',
  endsOn: '',
  emoji: '',
  tags: '',
});

/** "maths, exam prep" → ['maths', 'exam prep'], at most five, no duplicates. */
export const parseTags = (text) =>
  [...new Set(String(text ?? '').split(',').map((tag) => tag.trim().toLowerCase()).filter(Boolean))].slice(0, 5);

export const validateSpaceForm = (form, { today = new Date().toISOString().slice(0, 10), canCreateClass = false } = {}) => {
  const errors = {};
  if (form.name.trim().length < 2) errors.name = 'At least 2 characters.';
  if (form.name.trim().length > 80) errors.name = 'At most 80 characters.';
  if (form.kind === 'class' && !canCreateClass) errors.kind = 'Only teachers can create class spaces.';
  if (form.kind === 'study') {
    if (!form.endsOn) errors.endsOn = 'Choose when the group ends, for example the exam date.';
    else if (form.endsOn <= today) errors.endsOn = 'The end date has to be in the future.';
  }
  if (parseTags(form.tags).some((tag) => tag.length > 24)) errors.tags = 'Each tag at most 24 characters.';
  return errors;
};

/** The API's input for the create form. A study group ends at the end of its last day. */
export const spaceFormToInput = (form) => ({
  name: form.name.trim(),
  description: form.description.trim() || null,
  kind: form.kind,
  access: form.access,
  memberList: form.memberList,
  joinQuestion: form.access === 'request' ? form.joinQuestion.trim() || null : null,
  endsAt: form.kind === 'study' && form.endsOn ? new Date(`${form.endsOn}T23:59:00`).toISOString() : null,
  emoji: form.emoji.trim() || null,
  tags: parseTags(form.tags),
});

export const validateThreadForm = ({ title, body }) => {
  const errors = {};
  if (title.trim().length < 3) errors.title = 'A title of at least 3 characters.';
  if (!body.trim()) errors.body = 'Write something first.';
  return errors;
};

/** A space's avatar: its emoji, or its first letter. */
export const spaceMark = (space) => space?.emoji || (space?.name ?? '?').trim().charAt(0).toUpperCase() || '?';

/** "Ends in 3 days", "Ended", or null. */
export const endsLabel = (endsAt, now = new Date()) => {
  if (!endsAt) return null;
  const days = Math.ceil((new Date(endsAt) - now) / 86_400_000);
  if (days <= 0) return 'Ended';
  if (days === 1) return 'Ends tomorrow';
  return `Ends in ${days} days`;
};

/** The badge on a thread row. */
export const threadBadge = (thread) => {
  if (thread.kind !== 'question') return null;
  return thread.answered ? { tone: 'done', text: 'Answered' } : { tone: 'open', text: 'Question' };
};

/** Tab from ?tab=, limited to the ones that exist. */
export const tabFrom = (search, allowed, fallback) => {
  const value = new URLSearchParams(search).get('tab');
  return allowed.includes(value) ? value : fallback;
};

/** Paragraphs of a post, for rendering as text (never as HTML). */
export const paragraphs = (body) =>
  String(body ?? '')
    .split(/\n{2,}/)
    .map((part) => part.trim())
    .filter(Boolean);

// ---------------------------------------------------------------------------
// Part 2: chat, materials
// ---------------------------------------------------------------------------

const GROUP_GAP_MS = 5 * 60_000;

/** Consecutive messages from one person within five minutes read as one block. */
export const groupMessages = (items) => {
  const groups = [];
  for (const message of items) {
    const last = groups[groups.length - 1];
    const lastAt = last ? new Date(last.items[last.items.length - 1].createdAt).getTime() : 0;
    if (last && last.author.userId === message.author.userId && new Date(message.createdAt).getTime() - lastAt < GROUP_GAP_MS) {
      last.items.push(message);
    } else {
      groups.push({ key: message.messageId, author: message.author, items: [message] });
    }
  }
  return groups;
};

/** "Today", "Yesterday", or the date — for dividers in the chat. */
export const dayLabel = (value, now = new Date(), locale) => {
  const date = new Date(value);
  const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diff = Math.round((day(now) - day(date)) / 86_400_000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  return new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'long' }).format(date);
};

/** "example.com/a" → "https://example.com/a"; anything that is not a web address → null. */
export const normalizeUrl = (input) => {
  const text = String(input ?? '').trim();
  if (!text) return null;
  const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(text) ? text : `https://${text}`;
  try {
    const url = new URL(withScheme);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.hostname.includes('.') ? url.toString() : null;
  } catch {
    return null;
  }
};
