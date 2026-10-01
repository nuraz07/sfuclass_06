// classroom-app/server/src/identity/Usernames.js
/**
 * Usernames: storing, checking, and signing in with one  (Sign in with a username)
 *
 * resolveLoginIdentifier() is what the login route calls first: an identifier
 * with "@" is an email address and passes through; anything else is looked up
 * as a username and replaced by that account's email. An unknown username
 * becomes an address that matches nobody, so the answer is the same
 * "Email or password is incorrect" either way — sign-in never tells which
 * usernames exist.
 */

import { pool } from '../db/pool.js';
import * as Rules from './usernameRules.js';

const fail = (code, message) => {
  throw Object.assign(new Error(message), { code });
};

const NOBODY = 'nobody@invalid.invalid';

export const resolveLoginIdentifier = async (identifier) => {
  const value = String(identifier ?? '').trim();
  if (Rules.isEmail(value)) return value;
  if (Rules.problemWith(value)) return NOBODY;
  const { rows } = await pool.query(
    `SELECT email FROM users WHERE lower(username) = $1 AND deleted_at IS NULL LIMIT 1`,
    [Rules.normalise(value)],
  );
  return rows[0]?.email ?? NOBODY;
};

const takenBySomeoneElse = async (name, userId = null) => {
  const { rows } = await pool.query(
    `SELECT id FROM users WHERE lower(username) = $1 AND deleted_at IS NULL AND ($2::uuid IS NULL OR id <> $2) LIMIT 1`,
    [name, userId],
  );
  return rows.length > 0;
};

/** { available, problem } — for the form, before saving. */
export const check = async ({ name, userId = null }) => {
  const problem = Rules.problemWith(name);
  if (problem) return { available: false, problem };
  if (await takenBySomeoneElse(Rules.normalise(name), userId)) return { available: false, problem: 'This username is taken.' };
  return { available: true, problem: null };
};

export const getMine = async ({ userId }) => {
  const { rows } = await pool.query(`SELECT username FROM users WHERE id = $1`, [userId]);
  return { username: rows[0]?.username ?? null };
};

/** Sets (or, with null, removes) the caller's username. */
export const setMine = async ({ userId, name }) => {
  if (name === null || name === '') {
    await pool.query(`UPDATE users SET username = NULL, updated_at = now() WHERE id = $1`, [userId]);
    return { username: null };
  }
  const problem = Rules.problemWith(name);
  if (problem) fail('validation_failed', problem);
  const value = Rules.normalise(name);
  if (await takenBySomeoneElse(value, userId)) fail('conflict', 'This username is taken.');
  try {
    await pool.query(`UPDATE users SET username = $2, updated_at = now() WHERE id = $1`, [userId, value]);
  } catch (cause) {
    // Two people saving the same name at the same moment: the unique index decides.
    if (cause?.code === '23505') fail('conflict', 'This username is taken.');
    throw cause;
  }
  return { username: value };
};

export default { resolveLoginIdentifier, check, getMine, setMine };
