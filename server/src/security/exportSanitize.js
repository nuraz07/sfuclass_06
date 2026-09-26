// classroom-app/server/src/security/exportSanitize.js
/**
 * What never goes into a data export, whatever table it comes from: password
 * hashes, secrets, tokens, key material. Pure.
 */

const SENSITIVE = /(password|secret|token|hash|private|p256dh|^auth$|public_key|endpoint|fingerprint)/i;

export const stripSensitive = (row) => {
  if (!row || typeof row !== 'object') return row;
  const clean = {};
  for (const [key, value] of Object.entries(row)) {
    if (SENSITIVE.test(key)) continue;
    if (Buffer.isBuffer(value)) continue;
    clean[key] = value instanceof Date ? value.toISOString() : value;
  }
  return clean;
};

/** A file name for the download: classroom-export-2026-09-26.json */
export const exportFileName = (now = new Date()) => `classroom-export-${now.toISOString().slice(0, 10)}.json`;

export default stripSensitive;
