#!/usr/bin/env bash
# media-install.sh — the Media area: your own library of uploads.
#
# Run from the project folder (the one with server/, packages/ and apps/):
#   bash media-install.sh
#
# Writes 9 files, patches 3, keeps a backup of everything it touches in
# .media-backup/<timestamp>/, checks every file and runs the rule tests.
# No migration, no containers: nothing is started, stopped or pulled. The API
# (node --watch) and Vite pick the changes up on their own.
#
# Undo: bash media-install.sh --restore   (back to the state before the first install)
set -euo pipefail

if [ ! -f server/src/files/FileService.js ] || [ ! -f packages/core-client/src/api/filesApi.ts ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder. The Materials uploads (server/src/files/) have to be installed first." >&2
  exit 1
fi
command -v node >/dev/null || { echo "node is required." >&2; exit 1; }

TOUCHED=(
  server/src/files/libraryRules.js
  server/test/files/libraryRules.check.mjs
  apps/web/src/components/Library/libraryModel.js
  apps/web/src/components/Library/LibraryItem.jsx
  apps/web/src/components/Library/FilePreview.jsx
  apps/web/src/components/Library/LibraryDialogs.jsx
  apps/web/src/components/Library/library.css
  apps/web/src/components/Library/__checks__/libraryModel.check.mjs
  apps/web/src/pages/MediaPage.jsx
  server/src/files/FileService.js
  server/src/routes/files.routes.js
  packages/core-client/src/api/filesApi.ts
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .media-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  rmdir apps/web/src/components/Library/__checks__ apps/web/src/components/Library 2>/dev/null || true
  echo "Restored from $FIRST."
  exit 0
fi

BACKUP=".media-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

restore_and_exit() {
  for f in "${TOUCHED[@]}"; do
    if [ -f "$BACKUP/$f" ]; then cp "$BACKUP/$f" "$f"; elif [ -f "$f" ]; then rm "$f"; fi
  done
  rm -f .media-patch.mjs
  echo "$1 Every file was put back as it was." >&2
  exit 1
}

echo "--- patching existing files"
cat > .media-patch.mjs <<'__MEDIA_EOF__'
// Patches existing files for the Media library. Every anchor is checked in
// every file before anything is written; a second run changes nothing.
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'server/src/files/FileService.js',
    marker: 'libraryRules.js',
    edits: [
      {
        name: 'import the library rules',
        find: "import * as Store from './FileStore.js';\n",
        replace: "import * as Store from './FileStore.js';\nimport * as Library from './libraryRules.js';\n",
      },
      {
        name: 'list: sortable',
        find: "export const list = async ({ viewer, q = null, kind = null }) => {\n",
        replace: "export const list = async ({ viewer, q = null, kind = null, sort = Library.DEFAULT_SORT }) => {\n",
      },
      {
        name: 'list: fixed ORDER BY from the rules',
        find: "      ORDER BY f.created_at DESC LIMIT 500`,\n",
        replace: '      ORDER BY ${Library.orderBy(sort)} LIMIT 500`,\n',
      },
      {
        name: 'usage: where a file is a material',
        find: '/** Deleting a file also removes it from every space it was a material in. */\n',
        replace:
          '/**\n' +
          ' * Where one of my files is a material: the spaces, so Media can show it and\n' +
          ' * say before a delete what the delete also removes. Only the owner asks;\n' +
          ' * only the owner can have added it (HubExtras.addMaterial).\n' +
          ' */\n' +
          'export const usage = async ({ viewer, fileId }) => {\n' +
          '  const row = await ownFile(viewer, fileId);\n' +
          '  const { rows } = await pool.query(\n' +
          '    `SELECT m.id AS material_id, m.created_at AS added_at, s.id AS space_id, s.name AS space_name,\n' +
          "            to_jsonb(s) ->> 'emoji' AS space_emoji\n" +
          '       FROM space_materials m\n' +
          '       JOIN spaces s ON s.id = m.space_id\n' +
          '      WHERE m.file_id = $1 AND m.deleted_at IS NULL\n' +
          '      ORDER BY lower(s.name), m.created_at`,\n' +
          '    [row.id],\n' +
          '  );\n' +
          '  return { items: rows.map(Library.toUsage) };\n' +
          '};\n' +
          '\n' +
          '/** Deleting a file also removes it from every space it was a material in. */\n',
      },
      {
        name: 'export usage',
        find: 'export default { limits, openPath, toView, createUpload, completeUpload, list, rename, remove, canView, linkFor, open };',
        replace: 'export default { limits, openPath, toView, createUpload, completeUpload, list, usage, rename, remove, canView, linkFor, open };',
      },
    ],
  },
  {
    file: 'server/src/routes/files.routes.js',
    marker: '/:id/usage',
    edits: [
      {
        name: 'document the new route',
        find: ' *   GET    /?q=&kind=          my library, with usage and the accepted formats\n',
        replace:
          ' *   GET    /?q=&kind=&sort=    my library, with usage and the accepted formats\n' +
          ' *                              (sort: new · old · name · size)\n' +
          ' *   GET    /:id/usage          the spaces where one of my files is a material\n',
      },
      {
        name: 'import the sort keys',
        find: "import * as Files from '../files/FileService.js';\n",
        replace: "import * as Files from '../files/FileService.js';\nimport { SORT_KEYS } from '../files/libraryRules.js';\n",
      },
      {
        name: 'list: accept sort',
        find:
          "  validate({ query: z.object({ q: z.string().trim().max(80).optional(), kind: z.enum(['image', 'document', 'video', 'audio', 'text']).optional() }).passthrough() }),\n" +
          "  handle((req, res, viewer) => Files.list({ viewer, q: req.query.q || null, kind: req.query.kind ?? null })),\n",
        replace:
          '  validate({\n' +
          '    query: z\n' +
          "      .object({ q: z.string().trim().max(80).optional(), kind: z.enum(['image', 'document', 'video', 'audio', 'text']).optional(), sort: z.enum(SORT_KEYS).optional() })\n" +
          '      .passthrough(),\n' +
          '  }),\n' +
          '  handle((req, res, viewer) => {\n' +
          '    // Express 5 makes req.query read-only; validate() puts the parsed copy here.\n' +
          '    const query = req.validatedQuery ?? req.query;\n' +
          "    return Files.list({ viewer, q: query.q || null, kind: query.kind ?? null, sort: query.sort ?? 'new' });\n" +
          '  }),\n',
      },
      {
        name: 'usage route',
        find: "router.get('/:id/link', ",
        replace:
          "router.get('/:id/usage', requireAuth, validate({ params: idParam }), handle((req, res, viewer) => Files.usage({ viewer, fileId: req.params.id })));\n\n" +
          "router.get('/:id/link', ",
      },
    ],
  },
  {
    file: 'packages/core-client/src/api/filesApi.ts',
    marker: 'FileUsageSchema',
    edits: [
      {
        name: 'usage schema',
        find: 'export type FileLibrary = z.infer<typeof LibrarySchema>;\n',
        replace:
          'export type FileLibrary = z.infer<typeof LibrarySchema>;\n' +
          '\n' +
          'export const FileUsageSchema = z\n' +
          '  .object({\n' +
          '    items: z.array(\n' +
          '      z\n' +
          '        .object({\n' +
          '          materialId: z.string(),\n' +
          '          spaceId: z.string(),\n' +
          '          spaceName: z.string(),\n' +
          '          emoji: z.string().nullable().default(null),\n' +
          '          addedAt: z.string().nullable().default(null),\n' +
          '        })\n' +
          '        .passthrough(),\n' +
          '    ),\n' +
          '  })\n' +
          '  .passthrough();\n' +
          'export type FileUsage = z.infer<typeof FileUsageSchema>;\n' +
          '\n' +
          "export type LibrarySort = 'new' | 'old' | 'name' | 'size';\n",
      },
      {
        name: 'interface: sort and usage',
        find:
          '  list(query?: { q?: string; kind?: string }, signal?: AbortSignal): Promise<FileLibrary>;\n',
        replace:
          '  list(query?: { q?: string; kind?: string; sort?: LibrarySort }, signal?: AbortSignal): Promise<FileLibrary>;\n' +
          '  /** The spaces where one of my files is a material. */\n' +
          '  usage(fileId: string, signal?: AbortSignal): Promise<FileUsage>;\n',
      },
      {
        name: 'usage call',
        find: '  rename: (fileId, name) => http.patch(',
        replace:
          '  usage: (fileId, signal) => http.get(`/files/${enc(fileId)}/usage`, { schema: FileUsageSchema, signal }),\n' +
          '  rename: (fileId, name) => http.patch(',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  let src;
  try {
    src = readFileSync(entry.file, 'utf8');
  } catch {
    console.error(`${entry.file}: not found. Nothing was changed in any file.`);
    process.exit(1);
  }
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
  for (const edit of entry.edits) src = src.replace(edit.find, () => edit.replace);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__MEDIA_EOF__
node .media-patch.mjs || { rm -f .media-patch.mjs; exit 1; }
rm -f .media-patch.mjs

echo "--- writing new files"
mkdir -p server/src/files
cat > server/src/files/libraryRules.js <<'__MEDIA_EOF__'
// classroom-app/server/src/files/libraryRules.js
/**
 * The Media library's rules  (Media)
 *
 * Pure, so they are tested without a database
 * (server/test/files/libraryRules.check.mjs):
 *
 *   SORTS / orderBy    how a library can be sorted, as a fixed SQL ORDER BY —
 *                      never built from what the client sent
 *   toUsage            one row of "where is this file used" as the client sees it
 */

/** Every sort ends on a unique column, so equal values keep a stable order. */
export const SORTS = Object.freeze({
  new: 'f.created_at DESC, f.id DESC',
  old: 'f.created_at ASC, f.id ASC',
  name: 'lower(f.name) ASC, f.created_at DESC, f.id DESC',
  size: 'f.size_bytes DESC, f.created_at DESC, f.id DESC',
});

export const SORT_KEYS = Object.keys(SORTS);
export const DEFAULT_SORT = 'new';

/** The ORDER BY for a sort key; anything unknown falls back to newest first. */
export const orderBy = (sort) => (Object.hasOwn(SORTS, sort) ? SORTS[sort] : SORTS[DEFAULT_SORT]);

const iso = (value) => (value ? new Date(value).toISOString() : null);

/** A space the file is a material in. */
export const toUsage = (row) => ({
  materialId: row.material_id,
  spaceId: row.space_id,
  spaceName: row.space_name ?? 'A space',
  emoji: row.space_emoji ?? null,
  addedAt: iso(row.added_at),
});

export default { SORTS, SORT_KEYS, DEFAULT_SORT, orderBy, toUsage };
__MEDIA_EOF__
echo "wrote server/src/files/libraryRules.js"
mkdir -p server/test/files
cat > server/test/files/libraryRules.check.mjs <<'__MEDIA_EOF__'
// node --test server/test/files/libraryRules.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SORTS, SORT_KEYS, DEFAULT_SORT, orderBy, toUsage } from '../../src/files/libraryRules.js';

test('every sort is a fixed clause that ends on a unique column', () => {
  assert.deepEqual(SORT_KEYS, ['new', 'old', 'name', 'size']);
  for (const clause of Object.values(SORTS)) assert.match(clause, /f\.id (ASC|DESC)$/);
});

test('known sorts map to their clause', () => {
  assert.equal(orderBy('name'), SORTS.name);
  assert.equal(orderBy('size'), SORTS.size);
  assert.equal(orderBy('old'), SORTS.old);
});

test('anything else falls back to newest first, never to client text', () => {
  for (const value of [undefined, null, '', 'NAME', 'f.name; DROP TABLE files', 'constructor', '__proto__', 'toString']) {
    assert.equal(orderBy(value), SORTS[DEFAULT_SORT]);
  }
});

test('usage rows become the client view', () => {
  const view = toUsage({ material_id: 'm1', space_id: 's1', space_name: 'Algebra', space_emoji: '➗', added_at: '2026-10-01T10:00:00Z' });
  assert.deepEqual(view, { materialId: 'm1', spaceId: 's1', spaceName: 'Algebra', emoji: '➗', addedAt: '2026-10-01T10:00:00.000Z' });
  assert.deepEqual(toUsage({ material_id: 'm2', space_id: 's2' }), { materialId: 'm2', spaceId: 's2', spaceName: 'A space', emoji: null, addedAt: null });
});
__MEDIA_EOF__
echo "wrote server/test/files/libraryRules.check.mjs"
mkdir -p apps/web/src/components/Library
cat > apps/web/src/components/Library/libraryModel.js <<'__MEDIA_EOF__'
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
__MEDIA_EOF__
echo "wrote apps/web/src/components/Library/libraryModel.js"
mkdir -p apps/web/src/components/Library
cat > apps/web/src/components/Library/LibraryItem.jsx <<'__MEDIA_EOF__'
import { fileMeta, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDate } from '../../lib/preferences.js';
import { usedInLabel } from './libraryModel.js';

/**
 * One file in the library  (Media)
 *
 * A tile in the grid, a row in the list. Pictures show themselves (lazily,
 * through the file's signed link); everything else shows its kind. Selecting
 * opens the preview panel; the whole item is one button, so it works with the
 * keyboard as well.
 */
export default function LibraryItem({ file, view, selected, onSelect }) {
  const thumb = file.kind === 'image' && file.openUrl ? fileHref(file.openUrl) : null;
  const usedIn = file.usedIn ?? 0;

  return (
    <li className={`lb-item lb-item--${view}${selected ? ' is-selected' : ''}`}>
      <button type="button" className="lb-item__button" aria-pressed={selected} onClick={() => onSelect(file.fileId)}>
        <span className={`lb-item__thumb lb-kind--${file.kind}`} aria-hidden="true">
          {thumb ? <img src={thumb} alt="" loading="lazy" decoding="async" draggable="false" /> : <span className="lb-item__icon">{iconFor(file.kind)}</span>}
          {view === 'grid' ? <span className="lb-item__ext">{file.ext.toUpperCase()}</span> : null}
        </span>
        <span className="lb-item__text">
          <span className="lb-item__name" title={file.name}>
            {file.name}
          </span>
          <span className="lb-item__meta">
            {fileMeta(file)}
            {view === 'list' && file.createdAt ? ` · ${formatDate(file.createdAt)}` : ''}
          </span>
        </span>
        {usedIn > 0 ? (
          <span className="lb-item__used" title={usedInLabel(usedIn)}>
            <span aria-hidden="true">◎</span> {usedIn}
            <span className="lb-sr"> {usedIn === 1 ? 'space' : 'spaces'}</span>
          </span>
        ) : null}
      </button>
    </li>
  );
}
__MEDIA_EOF__
echo "wrote apps/web/src/components/Library/LibraryItem.jsx"
mkdir -p apps/web/src/components/Library
cat > apps/web/src/components/Library/FilePreview.jsx <<'__MEDIA_EOF__'
import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { fileMeta, formatBytes, iconFor } from '../Files/filesModel.js';
import { fileHref } from '../../lib/files.js';
import { formatDate, formatTime } from '../../lib/preferences.js';
import { nameWithoutExt, openLabel, previewModeOf, renameProblem, usedInLabel } from './libraryModel.js';

/**
 * The preview panel  (Media)
 *
 * The selected file, as large as it fits: pictures, video, audio and plain
 * text right here; PDFs in their own tab; Office files and CSV as a download.
 * Below: its details, the spaces it is a material in, and what you can do —
 * open, add to a space, rename, delete. ← and → move through the visible
 * files, Esc closes.
 */

const TEXT_PREVIEW_BYTES = 64 * 1024;

function TextPreview({ href }) {
  const [text, setText] = useState(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    setText(null);
    setFailed(false);
    fetch(href, { headers: { Range: `bytes=0-${TEXT_PREVIEW_BYTES - 1}` }, signal: controller.signal })
      .then((response) => (response.ok ? response.text() : Promise.reject(new Error(String(response.status)))))
      .then(setText)
      .catch(() => !controller.signal.aborted && setFailed(true));
    return () => controller.abort();
  }, [href]);
  if (failed) return <p className="lb-preview__note">The text could not be loaded. Open the file instead.</p>;
  if (text === null) return <p className="lb-preview__note">Loading…</p>;
  return <pre className="lb-preview__text">{text}</pre>;
}

function Stage({ file }) {
  const href = file.openUrl ? fileHref(file.openUrl) : null;
  const mode = previewModeOf(file);
  if (!href) return <div className="lb-preview__stage"><p className="lb-preview__note">This file is not available.</p></div>;
  return (
    <div className={`lb-preview__stage lb-preview__stage--${mode}`}>
      {mode === 'image' ? <img src={href} alt={file.name} /> : null}
      {mode === 'video' ? <video src={href} controls preload="metadata" playsInline /> : null}
      {mode === 'audio' ? (
        <div className="lb-preview__audio">
          <span className="lb-preview__bigicon" aria-hidden="true">{iconFor('audio')}</span>
          <audio src={href} controls preload="metadata" />
        </div>
      ) : null}
      {mode === 'text' ? <TextPreview href={href} /> : null}
      {mode === 'pdf' || mode === 'download' ? (
        <div className="lb-preview__doc">
          <span className="lb-preview__bigicon" aria-hidden="true">{iconFor(file.kind)}</span>
          <span className="lb-preview__docext">{file.ext.toUpperCase()}</span>
          <a className="btn btn--primary" href={href} target="_blank" rel="noopener noreferrer">
            {openLabel(file)}
          </a>
        </div>
      ) : null}
    </div>
  );
}

function RenameField({ file, onRename }) {
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(nameWithoutExt(file));
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef(null);

  useEffect(() => {
    setEditing(false);
    setError(null);
    setValue(nameWithoutExt(file));
  }, [file.fileId, file.name]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (editing) inputRef.current?.select();
  }, [editing]);

  const save = async () => {
    const problem = renameProblem(value);
    if (problem) return setError(problem);
    if (value.trim() === nameWithoutExt(file)) return setEditing(false);
    setBusy(true);
    setError(null);
    try {
      await onRename(value.trim());
      setEditing(false);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not renamed.');
    } finally {
      setBusy(false);
    }
    return undefined;
  };

  if (!editing) {
    return (
      <div className="lb-preview__title">
        <h2 title={file.name}>{file.name}</h2>
        <button type="button" className="lb-textbtn" onClick={() => setEditing(true)}>
          Rename
        </button>
      </div>
    );
  }
  return (
    <form
      className="lb-rename"
      onSubmit={(event) => {
        event.preventDefault();
        save();
      }}
    >
      <label className="lb-sr" htmlFor={`rename-${file.fileId}`}>
        New name
      </label>
      <div className="lb-rename__field">
        <input
          id={`rename-${file.fileId}`}
          ref={inputRef}
          value={value}
          maxLength={180}
          disabled={busy}
          aria-invalid={Boolean(error)}
          onChange={(event) => setValue(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.stopPropagation();
              setEditing(false);
              setValue(nameWithoutExt(file));
              setError(null);
            }
          }}
        />
        <span className="lb-rename__ext">.{file.ext}</span>
      </div>
      <div className="lb-inline">
        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Saving…' : 'Save'}
        </button>
        <button type="button" className="btn" disabled={busy} onClick={() => setEditing(false)}>
          Cancel
        </button>
      </div>
      {error ? <p className="lb-error">{error}</p> : null}
    </form>
  );
}

export default function FilePreview({ file, files, usageVersion, onClose, onPrev, onNext, onRename, onAddToSpace, onDelete }) {
  const panelRef = useRef(null);
  const [usage, setUsage] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    setUsage(null);
    files
      .usage(file.fileId, controller.signal)
      .then((result) => setUsage(result.items))
      .catch(() => !controller.signal.aborted && setUsage([]));
    return () => controller.abort();
  }, [files, file.fileId, usageVersion]);

  // Keyboard: Esc closes, ← → move, unless someone is typing.
  useEffect(() => {
    const onKey = (event) => {
      const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName ?? '') || event.target?.isContentEditable;
      if (typing || event.defaultPrevented || document.querySelector('dialog[open]')) return;
      if (event.key === 'Escape') onClose();
      else if (event.key === 'ArrowLeft' && onPrev) onPrev();
      else if (event.key === 'ArrowRight' && onNext) onNext();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose, onPrev, onNext]);

  useEffect(() => {
    panelRef.current?.focus({ preventScroll: true });
  }, [file.fileId]);

  const href = file.openUrl ? fileHref(file.openUrl) : null;

  return (
    <aside className="lb-preview" aria-label={`Preview of ${file.name}`} tabIndex={-1} ref={panelRef}>
      <div className="lb-preview__bar">
        <div className="lb-inline">
          <button type="button" className="lb-iconbtn" onClick={onPrev} disabled={!onPrev} aria-label="Previous file" title="Previous (←)">
            ‹
          </button>
          <button type="button" className="lb-iconbtn" onClick={onNext} disabled={!onNext} aria-label="Next file" title="Next (→)">
            ›
          </button>
        </div>
        <button type="button" className="lb-iconbtn" onClick={onClose} aria-label="Close preview" title="Close (Esc)">
          ×
        </button>
      </div>

      <Stage file={file} />

      <div className="lb-preview__body">
        <RenameField file={file} onRename={onRename} />
        <p className="lb-muted">
          {fileMeta(file)}
          {file.createdAt ? ` · uploaded ${formatDate(file.createdAt)}, ${formatTime(file.createdAt)}` : ''}
        </p>

        <div className="lb-actions">
          {href ? (
            <a className="btn" href={href} target="_blank" rel="noopener noreferrer">
              {openLabel(file)}
            </a>
          ) : null}
          <button type="button" className="btn btn--primary" onClick={onAddToSpace}>
            Add to a space
          </button>
          <button type="button" className="btn lb-danger" onClick={onDelete}>
            Delete
          </button>
        </div>

        <section className="lb-usage" aria-live="polite">
          <h3>Used in</h3>
          {usage === null ? <p className="lb-muted">Loading…</p> : null}
          {usage?.length === 0 ? <p className="lb-muted">{usedInLabel(0)}. Add it to a space so its members can open it.</p> : null}
          {usage?.length ? (
            <ul>
              {usage.map((entry) => (
                <li key={entry.materialId}>
                  <Link to={`/community/spaces/${entry.spaceId}`}>
                    <span aria-hidden="true">{entry.emoji ?? '◎'}</span> {entry.spaceName}
                  </Link>
                  {entry.addedAt ? <span className="lb-muted"> · since {formatDate(entry.addedAt)}</span> : null}
                </li>
              ))}
            </ul>
          ) : null}
        </section>

        <dl className="lb-details">
          <dt>Type</dt>
          <dd>{file.ext.toUpperCase()}</dd>
          <dt>Size</dt>
          <dd>{formatBytes(file.sizeBytes)}</dd>
          <dt>Who can open it</dt>
          <dd>{usage?.length ? 'You, and the members of the spaces above' : 'Only you'}</dd>
        </dl>
      </div>
    </aside>
  );
}
__MEDIA_EOF__
echo "wrote apps/web/src/components/Library/FilePreview.jsx"
mkdir -p apps/web/src/components/Library
cat > apps/web/src/components/Library/LibraryDialogs.jsx <<'__MEDIA_EOF__'
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { createHubApi, useCore } from '@classroom/core-client';
import { deleteConsequence, spaceChoices } from './libraryModel.js';

/**
 * The two dialogs of the Media library  (Media)
 *
 *   AddToSpaceDialog   the spaces I belong to; choosing one makes the file a
 *                      material there — the same call as "From my uploads" in
 *                      a space, so the same rules apply (posting paused, ended)
 *   DeleteFileDialog   says what a delete also removes before it happens
 *
 * Native <dialog>: focus stays inside, Esc closes, the page behind is inert.
 */

function useModal(onClose) {
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
  return ref;
}

export function AddToSpaceDialog({ file, files, onClose, onAdded }) {
  const { http } = useCore();
  const hub = useMemo(() => createHubApi(http), [http]);
  const ref = useModal(onClose);
  const [choices, setChoices] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(null);
  const [added, setAdded] = useState([]);

  useEffect(() => {
    const controller = new AbortController();
    Promise.all([hub.spaces({ scope: 'mine' }, controller.signal), files.usage(file.fileId, controller.signal)])
      .then(([spaces, usage]) => setChoices(spaceChoices(spaces.items, usage.items.map((entry) => entry.spaceId))))
      .catch(() => !controller.signal.aborted && setError('Your spaces could not be loaded. Try again.'));
    return () => controller.abort();
  }, [hub, files, file.fileId]);

  const add = async (choice) => {
    setBusy(choice.spaceId);
    setError(null);
    try {
      await hub.addMaterial(choice.spaceId, { fileId: file.fileId });
      setAdded((current) => [...current, choice.spaceId]);
      onAdded?.(choice);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'Not added.');
    } finally {
      setBusy(null);
    }
  };

  return (
    <dialog ref={ref} className="app-dialog lb-dialog" aria-labelledby="lb-add-title">
      <div className="app-dialog__body">
        <h2 id="lb-add-title">Add to a space</h2>
        <p className="lb-muted">
          <strong>{file.name}</strong> becomes a material there. Its members can open it; it stays yours, and deleting it here removes it there too.
        </p>
        {choices === null && !error ? <p className="lb-muted">Loading your spaces…</p> : null}
        {choices?.length === 0 ? (
          <p className="lb-muted">
            You are not in any space yet. <Link to="/community">Find or start one in Community.</Link>
          </p>
        ) : null}
        {choices?.length ? (
          <ul className="lb-spaces">
            {choices.map((choice) => {
              const done = added.includes(choice.spaceId);
              return (
                <li key={choice.spaceId}>
                  <span className="lb-spaces__emoji" aria-hidden="true">{choice.emoji ?? '◎'}</span>
                  <span className="lb-spaces__text">
                    <span className="lb-spaces__name">{choice.name}</span>
                    {done ? (
                      <span className="lb-ok">
                        Added · <Link to={`/community/spaces/${choice.spaceId}`}>open the space</Link>
                      </span>
                    ) : choice.unavailable ? (
                      <span className="lb-muted">{choice.unavailable}</span>
                    ) : null}
                  </span>
                  {!done && !choice.unavailable ? (
                    <button type="button" className="btn" disabled={busy !== null} onClick={() => add(choice)}>
                      {busy === choice.spaceId ? 'Adding…' : 'Add'}
                    </button>
                  ) : null}
                </li>
              );
            })}
          </ul>
        ) : null}
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn btn--primary" onClick={onClose}>
            Done
          </button>
        </div>
      </div>
    </dialog>
  );
}

export function DeleteFileDialog({ file, files, onClose, onDeleted }) {
  const ref = useModal(onClose);
  const [usage, setUsage] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    files
      .usage(file.fileId, controller.signal)
      .then((result) => setUsage(result.items))
      .catch(() => !controller.signal.aborted && setUsage([]));
    return () => controller.abort();
  }, [files, file.fileId]);

  const remove = async () => {
    setBusy(true);
    setError(null);
    try {
      await files.remove(file.fileId);
      onDeleted(file);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'The file was not deleted.');
      setBusy(false);
    }
  };

  return (
    <dialog ref={ref} className="app-dialog lb-dialog" aria-labelledby="lb-del-title">
      <div className="app-dialog__body">
        <h2 id="lb-del-title">Delete this file?</h2>
        <p>
          <strong>{file.name}</strong> is deleted for good.
        </p>
        <p className="lb-muted">{usage === null ? 'Checking where it is used…' : deleteConsequence(usage)}</p>
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button type="button" className="btn btn--danger" onClick={remove} disabled={busy || usage === null}>
            {busy ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>
    </dialog>
  );
}
__MEDIA_EOF__
echo "wrote apps/web/src/components/Library/LibraryDialogs.jsx"
mkdir -p apps/web/src/components/Library
cat > apps/web/src/components/Library/library.css <<'__MEDIA_EOF__'
/* Media library — see pages/MediaPage.jsx and components/Library/.
   Uses the app's colour variables (styles/theme.css); no colours of its own
   beyond soft tints of them. */

.lb-page { display: grid; gap: 18px; }
.lb-head { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 16px 28px; }
.lb-head h1 { margin: 0 0 4px; }
.lb-head p { margin: 0; max-width: 60ch; }
.lb-muted { color: var(--color-muted, #5d6f73); }
.lb-error { color: var(--color-danger, #c93636); margin: 0; }
.lb-ok { color: var(--color-live, #1e9a77); }
.lb-inline { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.lb-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

/* ---------------------------------------------------------------- storage */
.lb-storage { min-width: 240px; display: grid; gap: 6px; padding: 12px 14px; border-radius: 14px; background: var(--color-surface, #fff); border: 1px solid var(--color-border, #dbe4e1); }
.lb-storage__numbers { font-size: 14.5px; }
.lb-storage__bar { height: 6px; border-radius: 3px; background: var(--color-surface-sunken, #eaf0ee); overflow: hidden; }
.lb-storage__bar i { display: block; height: 100%; background: var(--color-accent, #2f63d6); transform-origin: left; transition: transform 0.6s var(--app-ease, ease); }
.lb-storage.is-high .lb-storage__bar i { background: #e0a21b; }
.lb-storage.is-full .lb-storage__bar i { background: var(--color-danger, #c93636); }
.lb-storage__hint { margin: 0; font-size: 13px; color: var(--color-muted, #5d6f73); }
.lb-storage.is-full .lb-storage__hint { color: var(--color-danger, #c93636); }

/* ---------------------------------------------------------------- toolbar */
.lb-toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: 10px 12px; }
.lb-search { flex: 1 1 220px; min-width: 0; padding: 10px 14px; border-radius: 999px; border: 1px solid var(--color-border, #dbe4e1); font: inherit; }
.lb-chips { display: flex; flex-wrap: wrap; gap: 6px; }
.lb-chip { padding: 7px 13px; border-radius: 999px; border: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface, #fff); color: var(--color-muted, #5d6f73); font: inherit; font-size: 14px; cursor: pointer; transition: background-color 0.2s ease, color 0.2s ease, border-color 0.2s ease; }
.lb-chip:hover { color: var(--color-text, #15272c); }
.lb-chip.is-on { background: var(--color-text, #15272c); border-color: var(--color-text, #15272c); color: #fff; }
.lb-toolbar__end { display: inline-flex; align-items: center; gap: 8px; margin-left: auto; }
.lb-select { padding: 8px 10px; border-radius: 10px; border: 1px solid var(--color-border, #dbe4e1); font: inherit; font-size: 14px; }
.lb-segment { display: inline-flex; padding: 3px; border-radius: 10px; background: var(--color-surface-2, #f1f5f4); }
.lb-segment button { width: 36px; height: 30px; border: 0; border-radius: 8px; background: transparent; color: var(--color-muted, #5d6f73); font-size: 16px; cursor: pointer; }
.lb-segment button.is-on { background: #fff; color: var(--color-text, #15272c); box-shadow: 0 1px 3px rgba(20, 38, 43, 0.12); }

/* ---------------------------------------------------------------- layout */
.lb-layout { display: grid; grid-template-columns: minmax(0, 1fr); gap: 20px; align-items: start; }
.lb-page.has-preview .lb-layout { grid-template-columns: minmax(0, 1fr) minmax(340px, 420px); }
.lb-main { min-width: 0; display: grid; gap: 18px; }
.lb-main[aria-busy='true'] .lb-items { opacity: 0.6; transition: opacity 0.2s ease; }
.lb-section { display: grid; gap: 10px; }
.lb-section__label { margin: 0; font-size: 13px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; color: var(--color-muted, #5d6f73); font-family: var(--font-sans, inherit) !important; }
.lb-scrim { display: none; }

.lb-empty { display: grid; justify-items: start; gap: 8px; padding: 28px; border-radius: 16px; border: 1px dashed var(--color-border, #dbe4e1); background: var(--color-surface, #fff); }
.lb-empty p { margin: 0; }
.lb-empty__title { font-weight: 700; font-size: 17px; }

/* ---------------------------------------------------------------- items */
.lb-items { list-style: none; margin: 0; padding: 0; }
.lb-items--grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(168px, 1fr)); gap: 12px; }
.lb-items--list { display: grid; gap: 6px; }
.lb-item__button {
  position: relative; display: flex; width: 100%; padding: 0; border: 1px solid var(--color-border, #dbe4e1); border-radius: 14px;
  background: var(--color-surface, #fff); color: inherit; font: inherit; text-align: left; cursor: pointer;
  transition: transform 0.35s var(--app-ease, ease), box-shadow 0.35s var(--app-ease, ease), border-color 0.2s ease;
}
.lb-item__button:hover { transform: translateY(-2px); box-shadow: var(--app-shadow, 0 8px 20px -12px rgba(0, 0, 0, 0.3)); }
.lb-item.is-selected .lb-item__button { border-color: var(--color-accent, #2f63d6); box-shadow: 0 0 0 3px rgba(47, 99, 214, 0.18); }
.lb-item--grid .lb-item__button { flex-direction: column; overflow: hidden; }
.lb-item--list .lb-item__button { align-items: center; gap: 12px; padding: 8px 12px 8px 8px; }

.lb-item__thumb { position: relative; display: grid; place-items: center; background: var(--color-surface-2, #f1f5f4); overflow: hidden; }
.lb-item--grid .lb-item__thumb { aspect-ratio: 4 / 3; }
.lb-item--list .lb-item__thumb { width: 44px; height: 44px; flex: 0 0 auto; border-radius: 10px; }
.lb-item__thumb img { width: 100%; height: 100%; object-fit: cover; }
.lb-item__icon { font-size: 34px; line-height: 1; }
.lb-item--list .lb-item__icon { font-size: 22px; }
.lb-kind--document { background: #eef3fe; }
.lb-kind--video { background: #f2eefe; }
.lb-kind--audio { background: #fef6e4; }
.lb-kind--text { background: #eef7f3; }
.lb-item__ext { position: absolute; left: 8px; bottom: 8px; padding: 2px 7px; border-radius: 6px; background: rgba(255, 255, 255, 0.92); font-size: 11px; font-weight: 700; letter-spacing: 0.04em; color: var(--color-text, #15272c); }
.lb-item__text { display: grid; gap: 2px; min-width: 0; flex: 1; }
.lb-item--grid .lb-item__text { padding: 10px 12px 12px; }
.lb-item__name { font-weight: 700; font-size: 14.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.lb-item__meta { font-size: 12.5px; color: var(--color-muted, #5d6f73); }
.lb-item__used { display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; border-radius: 999px; background: var(--app-sun-soft, #fff3c4); color: var(--app-sun-ink, #2a2206); font-size: 12px; font-weight: 700; }
.lb-item--grid .lb-item__used { position: absolute; top: 8px; right: 8px; }

/* ---------------------------------------------------------------- preview */
.lb-preview {
  position: sticky; top: 76px; display: grid; max-height: calc(100vh - 96px); overflow: auto; border-radius: 18px;
  border: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface, #fff); box-shadow: var(--app-shadow, none);
  animation: lb-in 0.4s var(--app-ease, ease) both; outline: none;
}
@keyframes lb-in { from { opacity: 0; transform: translateX(12px); } to { opacity: 1; transform: none; } }
.lb-preview__bar { position: sticky; top: 0; z-index: 1; display: flex; justify-content: space-between; align-items: center; padding: 8px; background: rgba(255, 255, 255, 0.9); backdrop-filter: blur(8px); }
.lb-iconbtn { width: 34px; height: 34px; border: 0; border-radius: 10px; background: transparent; color: var(--color-text, #15272c); font-size: 22px; line-height: 1; cursor: pointer; }
.lb-iconbtn:hover:not(:disabled) { background: var(--color-surface-2, #f1f5f4); }
.lb-iconbtn:disabled { opacity: 0.3; cursor: default; }

.lb-preview__stage { display: grid; place-items: center; min-height: 200px; margin: 0 12px; border-radius: 14px; background: var(--color-surface-sunken, #eaf0ee); overflow: hidden; }
.lb-preview__stage img, .lb-preview__stage video { display: block; max-width: 100%; max-height: 52vh; object-fit: contain; }
.lb-preview__stage--video { background: #0d1a1e; }
.lb-preview__audio, .lb-preview__doc { display: grid; justify-items: center; gap: 14px; padding: 28px 16px; width: 100%; }
.lb-preview__audio audio { width: 100%; }
.lb-preview__bigicon { font-size: 54px; line-height: 1; }
.lb-preview__docext { font-weight: 700; letter-spacing: 0.06em; color: var(--color-muted, #5d6f73); }
.lb-preview__text { width: 100%; max-height: 52vh; margin: 0; padding: 14px; overflow: auto; background: #fff; font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; word-break: break-word; }
.lb-preview__note { padding: 24px; margin: 0; color: var(--color-muted, #5d6f73); }

.lb-preview__body { display: grid; gap: 14px; padding: 16px; }
.lb-preview__body p { margin: 0; }
.lb-preview__title { display: flex; align-items: flex-start; gap: 10px; justify-content: space-between; }
.lb-preview__title h2 { margin: 0; font-size: 19px; line-height: 1.25; overflow-wrap: anywhere; }
.lb-textbtn { flex: 0 0 auto; padding: 4px 8px; border: 0; border-radius: 8px; background: none; color: var(--color-accent, #2f63d6); font: inherit; font-size: 14px; font-weight: 700; cursor: pointer; }
.lb-textbtn:hover { background: rgba(47, 99, 214, 0.08); }
.lb-rename { display: grid; gap: 8px; }
.lb-rename__field { display: flex; align-items: stretch; }
.lb-rename__field input { flex: 1; min-width: 0; padding: 9px 12px; border: 1px solid var(--color-border, #dbe4e1); border-radius: 10px 0 0 10px; font: inherit; }
.lb-rename__ext { display: grid; place-items: center; padding: 0 10px; border: 1px solid var(--color-border, #dbe4e1); border-left: 0; border-radius: 0 10px 10px 0; background: var(--color-surface-2, #f1f5f4); color: var(--color-muted, #5d6f73); }
.lb-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.lb-actions .btn { padding: 9px 14px; border-radius: 10px; font: inherit; font-size: 14.5px; cursor: pointer; }
.lb-danger { color: var(--color-danger, #c93636) !important; }
.lb-danger:hover:not(:disabled) { background: #fdecec !important; border-color: #f3c2c2 !important; }

.lb-usage h3 { margin: 0 0 6px; font-size: 14px; }
.lb-usage ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; }
.lb-usage a { color: var(--color-text, #15272c); font-weight: 700; text-decoration: none; }
.lb-usage a:hover { color: var(--color-accent, #2f63d6); text-decoration: underline; }
.lb-details { display: grid; grid-template-columns: auto 1fr; gap: 4px 14px; margin: 0; padding-top: 12px; border-top: 1px solid var(--color-border, #dbe4e1); font-size: 14px; }
.lb-details dt { color: var(--color-muted, #5d6f73); }
.lb-details dd { margin: 0; }

/* ---------------------------------------------------------------- dialogs */
.lb-dialog { width: min(520px, 94vw); }
.lb-spaces { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; max-height: 50vh; overflow: auto; }
.lb-spaces li { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 12px; border: 1px solid var(--color-border, #dbe4e1); }
.lb-spaces__emoji { font-size: 20px; width: 28px; text-align: center; }
.lb-spaces__text { display: grid; flex: 1; min-width: 0; font-size: 13.5px; }
.lb-spaces__name { font-weight: 700; font-size: 15px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.lb-spaces .btn { padding: 7px 14px; border-radius: 10px; font: inherit; font-size: 14px; cursor: pointer; }

.lb-notice {
  position: fixed; left: 50%; bottom: 24px; z-index: 70; transform: translateX(-50%); max-width: min(560px, 92vw);
  padding: 11px 18px; border-radius: 12px; background: var(--color-text, #15272c); color: #fff; font-size: 14.5px;
  box-shadow: 0 16px 40px -16px rgba(20, 38, 43, 0.6); animation: lb-up 0.35s var(--app-ease, ease) both;
}
@keyframes lb-up { from { opacity: 0; transform: translate(-50%, 10px); } to { opacity: 1; transform: translate(-50%, 0); } }

/* ---------------------------------------------------------------- narrow screens: the preview becomes a sheet */
@media (max-width: 980px) {
  .lb-page.has-preview .lb-layout { grid-template-columns: minmax(0, 1fr); }
  .lb-scrim { display: block; position: fixed; inset: 0; z-index: 64; border: 0; background: rgba(20, 38, 43, 0.35); cursor: pointer; }
  .lb-preview { position: fixed; z-index: 65; top: auto; left: 0; right: 0; bottom: 0; max-height: 88vh; border-radius: 20px 20px 0 0; animation-name: lb-sheet; }
  @keyframes lb-sheet { from { transform: translateY(24px); opacity: 0; } to { transform: none; opacity: 1; } }
  .lb-toolbar__end { margin-left: 0; }
}
@media (max-width: 560px) {
  .lb-items--grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
  .lb-storage { width: 100%; }
}

@media (prefers-reduced-motion: reduce) {
  .lb-preview, .lb-notice { animation: none; }
  .lb-item__button, .lb-storage__bar i, .lb-chip { transition: none; }
  .lb-item__button:hover { transform: none; }
}
__MEDIA_EOF__
echo "wrote apps/web/src/components/Library/library.css"
mkdir -p apps/web/src/components/Library/__checks__
cat > apps/web/src/components/Library/__checks__/libraryModel.check.mjs <<'__MEDIA_EOF__'
// node --test apps/web/src/components/Library/__checks__/libraryModel.check.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  readQuery, writeQuery, previewModeOf, openLabel, nameWithoutExt, renameProblem, usageLevel, usedInLabel,
  deleteConsequence, neighbours, dateGroupOf, sectionsOf, spaceChoices, linksAreStale, LINK_REFRESH_MS,
} from '../libraryModel.js';

const ID = '3f1c9a7e-2b4d-4e6f-8a9b-0c1d2e3f4a5b';

test('the address bar is read defensively', () => {
  assert.deepEqual(readQuery(new URLSearchParams('')), { q: '', kind: '', sort: 'new', view: 'grid', file: null });
  assert.deepEqual(readQuery(new URLSearchParams(`q=maths&kind=video&sort=size&view=list&file=${ID}`)), { q: 'maths', kind: 'video', sort: 'size', view: 'list', file: ID });
  assert.deepEqual(readQuery(new URLSearchParams('kind=exe&sort=drop&view=3d&file=../x')), { q: '', kind: '', sort: 'new', view: 'grid', file: null });
  assert.equal(readQuery(new URLSearchParams(`q=${'a'.repeat(200)}`)).q.length, 80);
});

test('defaults are left out of the address bar', () => {
  assert.equal(writeQuery({ q: '', kind: '', sort: 'new', view: 'grid', file: null }).toString(), '');
  assert.equal(writeQuery({ sort: 'new' }, { kind: 'image', file: ID }).toString(), `kind=image&file=${ID}`);
  assert.equal(writeQuery({ q: 'a b', view: 'list' }, { file: null }).toString(), 'q=a+b&view=list');
});

test('preview modes by kind and format', () => {
  assert.equal(previewModeOf({ kind: 'image', ext: 'png' }), 'image');
  assert.equal(previewModeOf({ kind: 'video', ext: 'mp4' }), 'video');
  assert.equal(previewModeOf({ kind: 'audio', ext: 'mp3' }), 'audio');
  assert.equal(previewModeOf({ kind: 'text', ext: 'txt' }), 'text');
  assert.equal(previewModeOf({ kind: 'text', ext: 'csv' }), 'download');
  assert.equal(previewModeOf({ kind: 'document', ext: 'pdf' }), 'pdf');
  assert.equal(previewModeOf({ kind: 'document', ext: 'docx' }), 'download');
  assert.equal(previewModeOf(null), 'none');
  assert.equal(openLabel({ inline: true }), 'Open in new tab');
  assert.equal(openLabel({ inline: false }), 'Download');
});

test('rename shows the name without its extension and checks it like the server', () => {
  assert.equal(nameWithoutExt({ name: 'Worksheet 3.PDF', ext: 'pdf' }), 'Worksheet 3');
  assert.equal(nameWithoutExt({ name: 'notes', ext: 'txt' }), 'notes');
  assert.equal(renameProblem('  '), 'Give the file a name.');
  assert.match(renameProblem('a/b'), /cannot contain/);
  assert.match(renameProblem('x'.repeat(181)), /too long/);
  assert.equal(renameProblem('Fractions, part 2'), null);
});

test('storage levels and wording', () => {
  assert.equal(usageLevel({ usedBytes: 10, quotaBytes: 100 }), 'ok');
  assert.equal(usageLevel({ usedBytes: 80, quotaBytes: 100 }), 'high');
  assert.equal(usageLevel({ usedBytes: 99, quotaBytes: 100 }), 'full');
  assert.equal(usageLevel({}), 'ok');
  assert.equal(usedInLabel(0), 'Not in any space yet');
  assert.equal(usedInLabel(1), 'In 1 space');
  assert.equal(usedInLabel(4), 'In 4 spaces');
});

test('a delete says what else it removes', () => {
  assert.match(deleteConsequence([]), /nothing else changes/);
  assert.equal(deleteConsequence([{ spaceName: 'Algebra' }]), 'It is also removed from the materials of Algebra.');
  assert.equal(deleteConsequence([{ spaceName: 'A' }, { spaceName: 'B' }, { spaceName: 'C' }]), 'It is also removed from the materials of A, B and C.');
});

test('neighbours for arrow keys', () => {
  const items = [{ fileId: 'a' }, { fileId: 'b' }, { fileId: 'c' }];
  assert.deepEqual(neighbours(items, 'b'), { prev: 'a', next: 'c' });
  assert.deepEqual(neighbours(items, 'a'), { prev: null, next: 'b' });
  assert.deepEqual(neighbours(items, 'zz'), { prev: null, next: null });
});

test('date sections only for date sorts', () => {
  const now = new Date(2026, 9, 15, 12, 0);
  assert.equal(dateGroupOf(new Date(2026, 9, 15, 8, 0), now), 'Today');
  assert.equal(dateGroupOf(new Date(2026, 9, 14, 23, 0), now), 'Yesterday');
  assert.equal(dateGroupOf(new Date(2026, 9, 10, 9, 0), now), 'This week');
  assert.equal(dateGroupOf(new Date(2026, 9, 2, 9, 0), now), 'This month');
  assert.equal(dateGroupOf(new Date(2026, 7, 2, 9, 0), now), 'Earlier');
  assert.equal(dateGroupOf('not a date', now), 'Earlier');
  const items = [
    { fileId: '1', createdAt: new Date(2026, 9, 15, 9).toISOString() },
    { fileId: '2', createdAt: new Date(2026, 9, 15, 8).toISOString() },
    { fileId: '3', createdAt: new Date(2026, 6, 1).toISOString() },
  ];
  assert.deepEqual(sectionsOf(items, 'new', now).map((s) => [s.label, s.items.length]), [['Today', 2], ['Earlier', 1]]);
  assert.deepEqual(sectionsOf(items, 'name', now).map((s) => [s.label, s.items.length]), [[null, 3]]);
});

test('space choices: mine only, available first, with the reason', () => {
  const spaces = [
    { spaceId: 's1', name: 'Zoology', myRole: 'member' },
    { spaceId: 's2', name: 'Algebra', myRole: 'member' },
    { spaceId: 's3', name: 'Biology', myRole: 'member', ended: true },
    { spaceId: 's4', name: 'Chemistry', myRole: 'member', me: { postingBlocked: 'You are timed out until 14:00.' } },
    { spaceId: 's5', name: 'Not mine', myRole: null },
  ];
  const choices = spaceChoices(spaces, ['s1']);
  assert.deepEqual(choices.map((c) => [c.name, c.unavailable]), [
    ['Algebra', null],
    ['Biology', 'This space has ended'],
    ['Chemistry', 'You are timed out until 14:00.'],
    ['Zoology', 'Already in this space'],
  ]);
});

test('links are refreshed before they expire', () => {
  assert.equal(linksAreStale(null), true);
  assert.equal(linksAreStale(1_000, 1_000 + LINK_REFRESH_MS - 1), false);
  assert.equal(linksAreStale(1_000, 1_000 + LINK_REFRESH_MS + 1), true);
  assert.ok(LINK_REFRESH_MS < 2 * 60 * 60 * 1000);
});
__MEDIA_EOF__
echo "wrote apps/web/src/components/Library/__checks__/libraryModel.check.mjs"
mkdir -p apps/web/src/pages
cat > apps/web/src/pages/MediaPage.jsx <<'__MEDIA_EOF__'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { createFilesApi, useCore } from '@classroom/core-client';
import FileDrop from '../components/Files/FileDrop.jsx';
import { DEFAULT_ACCEPT, KIND_FILTERS, formatBytes, usagePercent } from '../components/Files/filesModel.js';
import LibraryItem from '../components/Library/LibraryItem.jsx';
import FilePreview from '../components/Library/FilePreview.jsx';
import { AddToSpaceDialog, DeleteFileDialog } from '../components/Library/LibraryDialogs.jsx';
import { SORTS, VIEWS, linksAreStale, neighbours, readQuery, sectionsOf, usageLevel, writeQuery } from '../components/Library/libraryModel.js';
import '../components/Library/library.css';

/**
 * Media — your own library  (Media)
 *
 * Everything you have uploaded, in one place: upload (same checks as in a
 * space's materials), find (search, type, sort, grid or list), look at it in
 * the preview panel, rename it, add it to one of your spaces, delete it.
 *
 * The state lives in the address bar (?q=&kind=&sort=&view=&file=), so a
 * reload, the back button or a bookmark brings back the same view. The data
 * comes from /files (files/FileService.js); every file link is signed and
 * lasts two hours, so the list reloads itself before links go stale.
 */
export default function MediaPage() {
  const { http } = useCore();
  const files = useMemo(() => createFilesApi(http), [http]);
  const [params, setParams] = useSearchParams();
  const state = readQuery(params);

  const [library, setLibrary] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState(state.q);
  const [dialog, setDialog] = useState(null); // { type: 'add' | 'delete', file }
  const [notice, setNotice] = useState(null);
  const [usageVersion, setUsageVersion] = useState(0);
  const loadedAt = useRef(0);
  const requestRef = useRef(null);
  const noticeTimer = useRef(null);

  const update = useCallback(
    (patch, { replace = true } = {}) => setParams(writeQuery(readQuery(params), patch), { replace }),
    [params, setParams],
  );

  const load = useCallback(async () => {
    requestRef.current?.abort();
    const controller = new AbortController();
    requestRef.current = controller;
    setLoading(true);
    try {
      const result = await files.list({ q: state.q || undefined, kind: state.kind || undefined, sort: state.sort }, controller.signal);
      setLibrary(result);
      setError(null);
      loadedAt.current = Date.now();
    } catch (cause) {
      if (!controller.signal.aborted) setError(cause?.detail ?? 'Your files could not be loaded.');
    } finally {
      if (requestRef.current === controller) setLoading(false);
    }
  }, [files, state.q, state.kind, state.sort]);

  useEffect(() => {
    load();
  }, [load]);
  useEffect(() => () => requestRef.current?.abort(), []);

  // The search box writes to the address bar after a short pause.
  useEffect(() => {
    if (search === state.q) return undefined;
    const timer = window.setTimeout(() => update({ q: search.trim() }), 250);
    return () => window.clearTimeout(timer);
  }, [search]); // eslint-disable-line react-hooks/exhaustive-deps

  // Back/forward changes the address bar under the search box.
  useEffect(() => {
    setSearch((current) => (current.trim() === state.q ? current : state.q));
  }, [state.q]);

  // Signed links last two hours: coming back to a tab later reloads them.
  useEffect(() => {
    const onVisible = () => document.visibilityState === 'visible' && linksAreStale(loadedAt.current) && load();
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('focus', onVisible);
    return () => {
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('focus', onVisible);
    };
  }, [load]);

  useEffect(() => () => window.clearTimeout(noticeTimer.current), []);
  const announce = (text) => {
    window.clearTimeout(noticeTimer.current);
    setNotice(text);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 5000);
  };

  const items = library?.items ?? [];
  const selected = state.file ? items.find((item) => item.fileId === state.file) ?? null : null;
  const { prev, next } = neighbours(items, selected?.fileId);
  const sections = useMemo(() => sectionsOf(items, state.sort), [items, state.sort]);
  const usage = library?.usage;
  const accept = library?.accept?.length ? library.accept : DEFAULT_ACCEPT;
  const filtered = Boolean(state.q || state.kind);
  const level = usage ? usageLevel(usage) : 'ok';

  // A file in the address bar that is not in the list closes the panel — or,
  // right after a delete, moves on to the file next to it.
  const afterDelete = useRef(null);
  useEffect(() => {
    if (library && state.file && !selected) update({ file: afterDelete.current });
    afterDelete.current = null;
  }, [library, state.file, selected]); // eslint-disable-line react-hooks/exhaustive-deps

  const select = useCallback((fileId) => update({ file: fileId === state.file ? null : fileId }), [update, state.file]);

  const replaceItem = (file) =>
    setLibrary((current) => (current ? { ...current, items: current.items.map((item) => (item.fileId === file.fileId ? { ...item, ...file } : item)) } : current));

  const rename = async (name) => {
    const renamed = await files.rename(selected.fileId, name);
    replaceItem(renamed);
    announce(`Renamed to ${renamed.name}.`);
    if (state.sort === 'name') load();
  };

  const deleted = (file) => {
    setDialog(null);
    const after = neighbours(items, file.fileId);
    afterDelete.current = after.next ?? after.prev ?? null;
    setLibrary((current) =>
      current
        ? {
            ...current,
            items: current.items.filter((item) => item.fileId !== file.fileId),
            usage: { ...current.usage, usedBytes: Math.max(0, current.usage.usedBytes - file.sizeBytes) },
          }
        : current,
    );
    announce(`${file.name} was deleted.`);
  };

  const addedToSpace = (file, choice) => {
    // Counted on the current item: several spaces can be added in one dialog.
    setLibrary((current) =>
      current
        ? { ...current, items: current.items.map((item) => (item.fileId === file.fileId ? { ...item, usedIn: (item.usedIn ?? 0) + 1 } : item)) }
        : current,
    );
    setUsageVersion((value) => value + 1);
    announce(`${file.name} is now a material in ${choice.name}.`);
  };

  const uploadedTimer = useRef(null);
  const uploaded = () => {
    // Several uploads finishing together reload the list once.
    window.clearTimeout(uploadedTimer.current);
    uploadedTimer.current = window.setTimeout(load, 300);
  };
  useEffect(() => () => window.clearTimeout(uploadedTimer.current), []);

  return (
    <section className={`page lb-page${selected ? ' has-preview' : ''}`}>
      <header className="lb-head">
        <div>
          <h1>Media</h1>
          <p className="lb-muted">Everything you have uploaded. Only you see this library; a file reaches others when you add it to a space.</p>
        </div>
        {usage ? (
          <div className={`lb-storage is-${level}`} role="group" aria-label="Storage">
            <div className="lb-storage__numbers">
              <strong>{formatBytes(usage.usedBytes)}</strong>
              <span className="lb-muted"> of {formatBytes(usage.quotaBytes)} used</span>
            </div>
            <div className="lb-storage__bar" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={usagePercent(usage)} aria-label="Storage used">
              <i style={{ transform: `scaleX(${usagePercent(usage) / 100})` }} />
            </div>
            {level !== 'ok' ? (
              <p className="lb-storage__hint">{level === 'full' ? 'Your storage is full. Delete files you no longer need to upload new ones.' : 'Your storage is almost full.'}</p>
            ) : null}
          </div>
        ) : null}
      </header>

      <FileDrop accept={accept} maxBytes={usage?.maxFileBytes ?? 50 * 1024 * 1024} compact={items.length > 0 || filtered} onUploaded={uploaded} />

      <div className="lb-toolbar" role="toolbar" aria-label="Find files">
        <input
          className="lb-search"
          type="search"
          placeholder="Search by name"
          aria-label="Search by name"
          value={search}
          maxLength={80}
          onChange={(event) => setSearch(event.target.value)}
        />
        <div className="lb-chips" role="radiogroup" aria-label="Type">
          {KIND_FILTERS.map((option) => (
            <button
              key={option.value || 'all'}
              type="button"
              role="radio"
              aria-checked={state.kind === option.value}
              className={state.kind === option.value ? 'lb-chip is-on' : 'lb-chip'}
              onClick={() => update({ kind: option.value })}
            >
              {option.label}
            </button>
          ))}
        </div>
        <div className="lb-toolbar__end">
          <label className="lb-sr" htmlFor="lb-sort">
            Sort
          </label>
          <select id="lb-sort" className="lb-select" value={state.sort} onChange={(event) => update({ sort: event.target.value })}>
            {SORTS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
          <div className="lb-segment" role="radiogroup" aria-label="View">
            {VIEWS.map((option) => (
              <button
                key={option.value}
                type="button"
                role="radio"
                aria-checked={state.view === option.value}
                className={state.view === option.value ? 'is-on' : ''}
                onClick={() => update({ view: option.value })}
                title={option.label}
              >
                <span aria-hidden="true">{option.value === 'grid' ? '▦' : '☰'}</span>
                <span className="lb-sr">{option.label}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="lb-layout">
        <div className="lb-main" aria-busy={loading}>
          {error ? (
            <div className="lb-empty">
              <p className="lb-error">{error}</p>
              <button type="button" className="btn" onClick={load}>
                Try again
              </button>
            </div>
          ) : null}
          {!error && library === null ? <p className="lb-muted">Loading your files…</p> : null}
          {!error && library && items.length === 0 ? (
            <div className="lb-empty">
              {filtered ? (
                <>
                  <p>No file matches.</p>
                  <button
                    type="button"
                    className="btn"
                    onClick={() => {
                      setSearch('');
                      update({ q: '', kind: '' });
                    }}
                  >
                    Show all files
                  </button>
                </>
              ) : (
                <>
                  <p className="lb-empty__title">Your library is empty</p>
                  <p className="lb-muted">Upload worksheets, slides, pictures or recordings above. From here you can add them to any of your spaces.</p>
                </>
              )}
            </div>
          ) : null}

          {sections.map((section) =>
            section.items.length ? (
              <div key={section.label ?? 'all'} className="lb-section">
                {section.label ? <h2 className="lb-section__label">{section.label}</h2> : null}
                <ul className={`lb-items lb-items--${state.view}`}>
                  {section.items.map((file) => (
                    <LibraryItem key={file.fileId} file={file} view={state.view} selected={file.fileId === selected?.fileId} onSelect={select} />
                  ))}
                </ul>
              </div>
            ) : null,
          )}
          {items.length >= 500 ? <p className="lb-muted">Showing the first 500 files. Search or filter to find older ones.</p> : null}
        </div>

        {selected ? (
          <>
            <button type="button" className="lb-scrim" aria-label="Close preview" onClick={() => update({ file: null })} />
            <FilePreview
              file={selected}
              files={files}
              usageVersion={usageVersion}
              onClose={() => update({ file: null })}
              onPrev={prev ? () => update({ file: prev }) : null}
              onNext={next ? () => update({ file: next }) : null}
              onRename={rename}
              onAddToSpace={() => setDialog({ type: 'add', file: selected })}
              onDelete={() => setDialog({ type: 'delete', file: selected })}
            />
          </>
        ) : null}
      </div>

      {dialog?.type === 'add' ? (
        <AddToSpaceDialog file={dialog.file} files={files} onClose={() => setDialog(null)} onAdded={(choice) => addedToSpace(dialog.file, choice)} />
      ) : null}
      {dialog?.type === 'delete' ? <DeleteFileDialog file={dialog.file} files={files} onClose={() => setDialog(null)} onDeleted={deleted} /> : null}

      {notice ? (
        <div className="lb-notice" role="status">
          {notice}
        </div>
      ) : null}
    </section>
  );
}
__MEDIA_EOF__
echo "wrote apps/web/src/pages/MediaPage.jsx"

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
[ "$FAILED" -eq 0 ] || restore_and_exit "A file did not pass its check (see above)."

echo "--- rule tests (node --test)"
CHECKS=$(find server/test apps/web/src -name '*.check.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
if node --test $CHECKS > .media-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .media-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .media-test.log
else
  cat .media-test.log
  rm -f .media-test.log
  restore_and_exit "The rule tests failed (see above)."
fi

echo
echo "Media is installed. Nothing was started: the API and Vite reload on their own"
echo "if they are running. Reload the browser with Ctrl+Shift+R and open Media."