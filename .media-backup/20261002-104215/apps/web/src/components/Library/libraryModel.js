/**
 * Pure helpers for the Media library  (Media)
 *
 * Tested in __checks__/libraryModel.check.mjs. The server decides what is
 * stored, sorted and allowed; these only read the address bar, word things
 * and choose how a file is previewed.
 */

import { KIND_FILTERS } from '../Files/filesModel.js';

export const SORTS = [
  { value: 'new', label: 'Newest first' },
  { value: 'old', label: 'Oldest first' },
  { value: 'name', label: 'Name (A–Z)' },
  { value: 'size', label: 'Largest first' },
];

export const VIEWS = [
  { value: 'grid', label: 'Grid' },
  { value: 'list', label: 'List' },
];

const DEFAULTS = { q: '', kind: '', sort: 'new', view: 'grid', file: null };
const KINDS = new Set(KIND_FILTERS.map((option) => option.value));
const SORT_VALUES = new Set(SORTS.map((option) => option.value));
const VIEW_VALUES = new Set(VIEWS.map((option) => option.value));

/** The library's state from the address bar; anything unknown is the default. */
export const readQuery = (params) => {
  const get = (key) => (typeof params?.get === 'function' ? params.get(key) : null);
  const q = String(get('q') ?? '').slice(0, 80);
  const kind = get('kind') ?? '';
  const sort = get('sort') ?? '';
  const view = get('view') ?? '';
  const file = get('file');
  return {
    q,
    kind: KINDS.has(kind) ? kind : DEFAULTS.kind,
    sort: SORT_VALUES.has(sort) ? sort : DEFAULTS.sort,
    view: VIEW_VALUES.has(view) ? view : DEFAULTS.view,
    file: file && /^[0-9a-f-]{36}$/i.test(file) ? file : null,
  };
};

/** The address-bar parameters for a state; defaults are left out so links stay short. */
export const writeQuery = (state, patch = {}) => {
  const next = { ...DEFAULTS, ...state, ...patch };
  const params = new URLSearchParams();
  for (const key of ['q', 'kind', 'sort', 'view', 'file']) {
    const value = next[key];
    if (value && value !== DEFAULTS[key]) params.set(key, value);
  }
  return params;
};

/**
 * How a file is shown in the preview panel. Images, video, audio and plain
 * text play in the page; PDFs open in their own tab (a PDF viewer inside the
 * page would need the API to allow framing); Office files and CSV download.
 */
export const previewModeOf = (file) => {
  if (!file) return 'none';
  if (file.kind === 'image') return 'image';
  if (file.kind === 'video') return 'video';
  if (file.kind === 'audio') return 'audio';
  if (file.ext === 'txt') return 'text';
  if (file.ext === 'pdf') return 'pdf';
  return 'download';
};

/** "Open" for what opens in a tab, "Download" for what downloads. */
export const openLabel = (file) => (file?.inline ? 'Open in new tab' : 'Download');

/** "Worksheet" for "Worksheet.pdf": what a rename field shows. */
export const nameWithoutExt = (file) => {
  const name = String(file?.name ?? '');
  const suffix = file?.ext ? `.${file.ext}` : '';
  return suffix && name.toLowerCase().endsWith(suffix.toLowerCase()) ? name.slice(0, -suffix.length) : name;
};

/** The same limits the server applies to a new name; a reason, or null. */
export const renameProblem = (value) => {
  const name = String(value ?? '').trim();
  if (!name) return 'Give the file a name.';
  if (name.length > 180) return 'That name is too long (180 characters at most).';
  if (/[\\/]/.test(name)) return 'A name cannot contain / or \\.';
  return null;
};

/** ok · high (80 %) · full (98 %) — how the storage bar is coloured. */
export const usageLevel = ({ usedBytes = 0, quotaBytes = 0 } = {}) => {
  if (!quotaBytes) return 'ok';
  const share = usedBytes / quotaBytes;
  if (share >= 0.98) return 'full';
  if (share >= 0.8) return 'high';
  return 'ok';
};

/** "Not in any space yet" · "In 1 space" · "In 3 spaces". */
export const usedInLabel = (count) => {
  const n = Number(count) || 0;
  if (n === 0) return 'Not in any space yet';
  return `In ${n} ${n === 1 ? 'space' : 'spaces'}`;
};

/** The sentence a delete dialog shows, from the file's usage. */
export const deleteConsequence = (usage = []) => {
  if (!usage.length) return 'It is not a material in any space, so nothing else changes.';
  const names = usage.map((entry) => entry.spaceName);
  const list = names.length === 1 ? names[0] : `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`;
  return `It is also removed from the materials of ${list}.`;
};

/** The previous and next file of the visible list, for arrow keys in the preview. */
export const neighbours = (items = [], fileId) => {
  const index = items.findIndex((item) => item.fileId === fileId);
  if (index === -1) return { prev: null, next: null };
  return { prev: items[index - 1]?.fileId ?? null, next: items[index + 1]?.fileId ?? null };
};

const DAY = 24 * 60 * 60 * 1000;
const startOfDay = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();

/** Today · Yesterday · This week · This month · Earlier — in the viewer's time zone. */
export const dateGroupOf = (createdAt, now = new Date()) => {
  const time = new Date(createdAt).getTime();
  if (Number.isNaN(time)) return 'Earlier';
  const today = startOfDay(now);
  if (time >= today) return 'Today';
  if (time >= today - DAY) return 'Yesterday';
  if (time >= today - 6 * DAY) return 'This week';
  if (time >= new Date(now.getFullYear(), now.getMonth(), 1).getTime()) return 'This month';
  return 'Earlier';
};

/**
 * Sections for the list. Only when sorted by date, where the headings say
 * something; any other sort is one section without a heading.
 */
export const sectionsOf = (items = [], sort = 'new', now = new Date()) => {
  if (sort !== 'new' && sort !== 'old') return [{ label: null, items }];
  const sections = [];
  for (const item of items) {
    const label = dateGroupOf(item.createdAt, now);
    const last = sections.at(-1);
    if (last && last.label === label) last.items.push(item);
    else sections.push({ label, items: [item] });
  }
  return sections;
};

/**
 * The spaces a file can be added to, available ones first. A space is not
 * available when it has ended, when posting is paused for me there, or when
 * the file is already one of its materials.
 */
export const spaceChoices = (spaces = [], usedSpaceIds = []) => {
  const used = new Set(usedSpaceIds);
  return spaces
    .filter((space) => space.myRole)
    .map((space) => {
      let unavailable = null;
      if (used.has(space.spaceId)) unavailable = 'Already in this space';
      else if (space.ended) unavailable = 'This space has ended';
      else if (space.me?.postingBlocked) unavailable = space.me.postingBlocked;
      return { spaceId: space.spaceId, name: space.name, emoji: space.emoji ?? null, unavailable };
    })
    .sort((a, b) => Number(Boolean(a.unavailable)) - Number(Boolean(b.unavailable)) || a.name.localeCompare(b.name));
};

/** Signed file links last two hours; the library reloads well before that. */
export const LINK_REFRESH_MS = 90 * 60 * 1000;
export const linksAreStale = (loadedAt, now = Date.now()) => !loadedAt || now - loadedAt > LINK_REFRESH_MS;
