/**
 * Pure helpers for sign-in and sign-up  (Landing)
 * Tested in __checks__/authModel.check.mjs.
 */

export const MIN_PASSWORD = 12;

/**
 * 0–4, for the bar under the password field. Length counts most; mixing
 * kinds of characters adds a little. The server decides what is accepted.
 */
export const passwordStrength = (password) => {
  const value = String(password ?? '');
  if (!value) return 0;
  if (value.length < MIN_PASSWORD) return 1;
  const kinds = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((re) => re.test(value)).length;
  if (value.length >= 20 || (value.length >= 16 && kinds >= 3)) return 4;
  if (kinds >= 3 || value.length >= 16) return 3;
  return 2;
};

export const STRENGTH_WORDS = ['', 'Too short', 'Good', 'Strong', 'Very strong'];

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Problems with the sign-up form, keyed by field; empty when it can be sent. */
export const validateSignup = ({ displayName, email, password }) => {
  const errors = {};
  if (!String(displayName ?? '').trim()) errors.displayName = 'Tell us what to call you.';
  else if (String(displayName).trim().length > 80) errors.displayName = 'At most 80 characters.';
  if (!EMAIL.test(String(email ?? '').trim())) errors.email = 'Enter an email address like name@example.com.';
  if (String(password ?? '').length < MIN_PASSWORD) errors.password = `At least ${MIN_PASSWORD} characters.`;
  return errors;
};

/** Only in-app paths may be a destination after signing in: no open redirects. */
export const safeNext = (value, fallback = '/') => {
  const text = String(value ?? '');
  return text.startsWith('/') && !text.startsWith('//') && !text.startsWith('/\\') ? text : fallback;
};

/** Where to go after signing in: ?next=, then where the visitor came from, then home. */
export const destinationOf = ({ search = '', state = null } = {}) => {
  const next = new URLSearchParams(search).get('next');
  if (next) return safeNext(next);
  return safeNext(state?.from, '/');
};

/** Keep ?next= when switching between sign-in and sign-up. */
export const withNext = (path, destination) =>
  destination && destination !== '/' ? `${path}?next=${encodeURIComponent(destination)}` : path;
