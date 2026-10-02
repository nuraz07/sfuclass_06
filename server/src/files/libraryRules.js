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
