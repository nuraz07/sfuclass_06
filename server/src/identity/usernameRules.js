// classroom-app/server/src/identity/usernameRules.js
/**
 * Usernames  (Sign in with a username)
 *
 * Pure — tested in server/test/identity/usernameRules.check.mjs.
 *
 *   3–30 characters: a–z, 0–9, dot, hyphen, underscore
 *   starts and ends with a letter or digit, no two punctuation marks in a row
 *   never contains "@" — so an identifier with "@" is always an email address
 *   case does not matter: "Anna.B" is stored and found as "anna.b"
 *   a few names are reserved, so nobody can look like the platform
 */

export const MIN = 3;
export const MAX = 30;

const RESERVED = new Set([
  'admin', 'administrator', 'root', 'system', 'support', 'help', 'helpdesk', 'security', 'moderator', 'mod',
  'staff', 'team', 'classroom', 'official', 'api', 'www', 'mail', 'email', 'noreply', 'no-reply', 'postmaster',
  'settings', 'account', 'login', 'signup', 'register', 'me', 'you', 'everyone', 'anonymous', 'null', 'undefined',
]);

export const normalise = (value) => String(value ?? '').trim().toLowerCase();

/** A reason the name cannot be used, or null. */
export const problemWith = (value) => {
  const name = normalise(value);
  if (name.length < MIN) return `At least ${MIN} characters.`;
  if (name.length > MAX) return `At most ${MAX} characters.`;
  if (name.includes('@')) return 'A username cannot contain "@".';
  if (!/^[a-z0-9._-]+$/.test(name)) return 'Only letters a–z, digits, dot, hyphen and underscore.';
  if (!/^[a-z0-9]/.test(name) || !/[a-z0-9]$/.test(name)) return 'Start and end with a letter or a digit.';
  if (/[._-]{2}/.test(name)) return 'No two dots, hyphens or underscores in a row.';
  if (RESERVED.has(name)) return 'This name is reserved.';
  return null;
};

/** Email address or username? An "@" decides. */
export const isEmail = (identifier) => String(identifier ?? '').includes('@');

export default { MIN, MAX, normalise, problemWith, isEmail };
