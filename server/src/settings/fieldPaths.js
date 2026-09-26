// classroom-app/server/src/settings/fieldPaths.js
/**
 * The dotted names of what a settings patch touched, for the change history:
 * { lesson: { joinCamera: 'off' } } → ['lesson.joinCamera']. Values are never
 * recorded: "Private messages changed" is history, the new value is not
 * something an audit trail needs to keep for years. Pure.
 */
export const fieldPaths = (value, prefix = '', depth = 0) => {
  if (value === undefined) return [];
  if (value === null || typeof value !== 'object' || Array.isArray(value) || depth >= 3) {
    return prefix ? [prefix] : [];
  }
  return Object.entries(value).flatMap(([key, entry]) =>
    fieldPaths(entry, prefix ? `${prefix}.${key}` : key, depth + 1),
  );
};

export default fieldPaths;
