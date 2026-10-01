#!/usr/bin/env bash
# look-install.sh — a light app, staying signed in, the profile menu,
# signing in with a username, and Messages side by side.
#
#   - the inside of the app is light (the dark green is gone); the classroom
#     with its video stays dark on purpose
#   - you stay signed in — across reloads and for as long as your session
#     runs (REFRESH_TTL), until you sign out yourself
#   - your picture in the top bar opens a menu: Profile, username, Settings,
#     Privacy, Homepage, Sign out ("Settings" leaves the top bar)
#   - sign in with your email or your username; choose a username at sign-up
#     or later from the menu
#   - Messages: on wide screens the list and the conversation side by side
#
# Needs the earlier updates (homepage, Messages, materials).
# Run from the project folder:  bash look-install.sh
# Writes 19 files, patches 6 more, backup in .look-backup/<timestamp>/.
# Undo:                         bash look-install.sh --restore
#   (the username column added by 030 stays — unused without these files)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/030_usernames.sql
  server/src/identity/Usernames.js
  server/src/identity/signup.js
  server/src/identity/usernameRules.js
  server/src/routes/username.routes.js
  server/test/identity/usernameRules.check.mjs
  packages/core-client/src/api/usernameApi.ts
  apps/web/src/components/Auth/__checks__/authModel.check.mjs
  apps/web/src/components/Auth/auth.css
  apps/web/src/components/Auth/authModel.js
  apps/web/src/components/Chat/messages.css
  apps/web/src/components/Hub/hub.css
  apps/web/src/components/system/AppHeader.jsx
  apps/web/src/components/system/UsernameDialog.jsx
  apps/web/src/lib/signOutIntent.js
  apps/web/src/pages/LoginPage.jsx
  apps/web/src/pages/MessagesPage.jsx
  apps/web/src/pages/SignupPage.jsx
  apps/web/src/styles/theme.css
  packages/core-client/src/CoreProvider.tsx
  server/src/routes/auth.routes.js
  apps/web/src/pages/AppLayout.jsx
  apps/web/src/components/Chat/ChatRooms.jsx
  server/src/app.js
  packages/core-client/src/index.ts
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .look-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/030_usernames.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  echo "Restored from $FIRST. The migration file 030 stays, because the database already has it."
  exit 0
fi

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need apps/web/src/components/Chat/ChatRooms.jsx "showLobby" "the Messages update (messages-install.sh)"
need apps/web/src/components/Hub/hub.css "hb-matadd" "the materials update (materials-install.sh)"
need apps/web/src/components/system/AppHeader.jsx "app__nav" "the homepage v2 update"
need apps/web/src/pages/AppLayout.jsx "AppHeader" "the homepage v2 update"
need apps/web/src/pages/SignupPage.jsx "signUp" "the homepage update"
need packages/core-client/src/CoreProvider.tsx "const signUp = useCallback" "the homepage update"
need packages/core-client/src/CoreProvider.tsx "completeSignIn" "Settings Phase C"
need server/src/routes/auth.routes.js "'/register'" "the homepage update"
need server/src/identity/signup.js "registerOpen" "the homepage update"
need packages/core-client/src/index.ts "hubApi" "Community"
if ls server/src/db/migrations/030_*.sql 2>/dev/null | grep -qv 030_usernames.sql; then
  MISSING+=("another migration 030 exists: $(ls server/src/db/migrations/030_*.sql | tr '\n' ' ')")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what this update expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".look-backup/$(date +%Y%m%d-%H%M%S)-$$"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/030_usernames.sql <<'__LOOK_EOF__'
-- 030_usernames.sql  (Sign in with a username)
--
-- An optional username per account, unique regardless of case among accounts
-- that are not deleted, so someone can sign in with "anna.b" instead of an
-- email address. Stored as typed (lower-case, see identity/usernameRules.js).
-- Additive only.

alter table users add column if not exists username text;

create unique index if not exists users_username_key
  on users (lower(username))
  where username is not null and deleted_at is null;
__LOOK_EOF__
echo "wrote server/src/db/migrations/030_usernames.sql"

mkdir -p server/src/identity
cat > server/src/identity/Usernames.js <<'__LOOK_EOF__'
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
__LOOK_EOF__
echo "wrote server/src/identity/Usernames.js"

mkdir -p server/src/identity
cat > server/src/identity/signup.js <<'__LOOK_EOF__'
// classroom-app/server/src/identity/signup.js
/**
 * Creating an account from the homepage  (Landing)
 *
 * AuthService.register has always been able to create an account; nothing
 * exposed it. This decides the two things register() needs from outside:
 *
 *   may people sign up?   SIGNUP_MODE=open (default) or closed
 *   which organisation?   SIGNUP_TENANT_ID when set; otherwise the
 *                         organisation most people already belong to, so a
 *                         new account can join "anyone with the link" rooms
 *                         and find its classmates. With no users yet, the
 *                         first organisation there is.
 *
 * New accounts are always learners: a role is never chosen at sign-up.
 * Signing in looks accounts up by email across organisations, so an address
 * that exists anywhere is refused here — it could not be signed in to.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Users from './User.js';
import * as Usernames from './Usernames.js';

const log = logger.child({ component: 'signup' });

const fail = (code, message) => {
  throw Object.assign(new Error(message), { code });
};

export const signupMode = () => (String(process.env.SIGNUP_MODE ?? 'open').trim().toLowerCase() === 'closed' ? 'closed' : 'open');

export const resolveSignupTenant = async () => {
  const pinned = process.env.SIGNUP_TENANT_ID?.trim();
  if (pinned) {
    const { rows } = await pool.query(`SELECT id FROM tenants WHERE id = $1`, [pinned]).catch(() => ({ rows: [] }));
    if (rows[0]) return rows[0].id;
    log.error({ tenantId: pinned }, 'SIGNUP_TENANT_ID does not name an organisation; falling back');
  }
  const { rows } = await pool.query(
    `SELECT tenant_id FROM users WHERE deleted_at IS NULL
      GROUP BY tenant_id ORDER BY count(*) DESC, tenant_id LIMIT 1`,
  );
  if (rows[0]) return rows[0].tenant_id;
  const first = await pool.query(`SELECT id FROM tenants LIMIT 1`);
  return first.rows[0]?.id ?? null;
};

const TIME_ZONES = new Set(Intl.supportedValuesOf('timeZone'));

/**
 * @returns the same as AuthService.login: { user, accessToken, refreshToken, sessionId, … }
 */
export const registerOpen = async ({ displayName, email, password, username = null, timeZone = null, locale = null, device }) => {
  if (signupMode() === 'closed') {
    fail('forbidden', 'New accounts cannot be created here. Ask your school or organisation for an invitation.');
  }

  const address = String(email).trim();
  if (await Users.findCredentials(address)) {
    fail('conflict', 'An account with this email already exists.');
  }

  // An optional username, checked before the account exists so a taken name
  // never leaves a half-made account behind.
  if (username) {
    const { available, problem } = await Usernames.check({ name: username });
    if (!available) fail(problem === 'This username is taken.' ? 'conflict' : 'validation_failed', problem);
  }

  const tenantId = await resolveSignupTenant();
  if (!tenantId) fail('validation_failed', 'Sign-up is not set up yet: there is no organisation to join.');

  const AuthService = await import('./AuthService.js');
  const result = await AuthService.register({
    tenantId,
    email: address,
    password,
    displayName: String(displayName).trim(),
    role: 'learner',
    locale: locale && /^[a-z]{2}(-[A-Z]{2})?$/.test(locale) ? locale : 'en',
    timeZone: timeZone && TIME_ZONES.has(timeZone) ? timeZone : 'UTC',
    device,
  });
  if (username && result.user?.userId) {
    await Usernames.setMine({ userId: result.user.userId, name: username }).catch((cause) =>
      log.warn({ err: cause }, 'username not saved at sign-up; it can be chosen later'),
    );
  }
  log.info({ userId: result.user?.userId, tenantId }, 'account created from the homepage');
  return result;
};

export default { registerOpen, resolveSignupTenant, signupMode };
__LOOK_EOF__
echo "wrote server/src/identity/signup.js"

mkdir -p server/src/identity
cat > server/src/identity/usernameRules.js <<'__LOOK_EOF__'
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
__LOOK_EOF__
echo "wrote server/src/identity/usernameRules.js"

mkdir -p server/src/routes
cat > server/src/routes/username.routes.js <<'__LOOK_EOF__'
/**
 * username.routes — your username  (Sign in with a username)
 *
 * Mounted under /account/username (app.js).
 *
 *   GET  /                    my username (or null)
 *   PUT  /  { username }      set it; null or "" removes it
 *   GET  /available?name=     is it free? — also for the sign-up form, so no
 *                             sign-in needed; rate-limited per address
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Usernames from '../identity/Usernames.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, badRequest, conflict } from './_helpers.js';

const router = Router();

const asHttp = (error) => {
  if (error?.code === 'validation_failed') return badRequest(error.message);
  if (error?.code === 'conflict') return conflict(error.message);
  return error;
};

router.get(
  '/available',
  rateLimit({ key: 'username:available', points: 60, durationSec: 300, by: ['ip'] }),
  validate({ query: z.object({ name: z.string().max(60) }).passthrough() }),
  route((req) => Usernames.check({ name: req.query.name, userId: req.user?.id ?? null })),
);

router.get('/', requireAuth, route((req) => Usernames.getMine({ userId: req.user.id })));

router.put(
  '/',
  requireAuth,
  rateLimit({ key: 'username:set', points: 10, durationSec: 3600, by: ['user'] }),
  validate({ body: z.object({ username: z.string().max(60).nullable() }) }),
  route(async (req) => {
    try {
      return await Usernames.setMine({ userId: req.user.id, name: req.body.username });
    } catch (error) {
      throw asHttp(error);
    }
  }),
);

export default router;
__LOOK_EOF__
echo "wrote server/src/routes/username.routes.js"

mkdir -p server/test/identity
cat > server/test/identity/usernameRules.check.mjs <<'__LOOK_EOF__'
// Usernames — what is allowed, and email-or-username.
// Run: node --test server/test/identity/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { isEmail, normalise, problemWith } from '../../src/identity/usernameRules.js';

test('good usernames', () => {
  for (const name of ['anna', 'anna.b', 'Anna_B', 'a1b', 'mr-okafor', 'x'.repeat(30)]) assert.equal(problemWith(name), null, name);
  assert.equal(normalise('  Anna.B '), 'anna.b');
});

test('refused usernames, with reasons', () => {
  assert.match(problemWith('ab'), /At least 3/);
  assert.match(problemWith('x'.repeat(31)), /At most 30/);
  assert.match(problemWith('anna@x'), /"@"/);
  assert.match(problemWith('anna b'), /Only letters/);
  assert.match(problemWith('ännä'), /Only letters/);
  assert.match(problemWith('.anna'), /Start and end/);
  assert.match(problemWith('anna_'), /Start and end/);
  assert.match(problemWith('an..na'), /two dots/);
  assert.match(problemWith('Admin'), /reserved/);
});

test('an "@" makes it an email address', () => {
  assert.equal(isEmail('anna@school.example'), true);
  assert.equal(isEmail('anna.b'), false);
});
__LOOK_EOF__
echo "wrote server/test/identity/usernameRules.check.mjs"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/usernameApi.ts <<'__LOOK_EOF__'
/**
 * Username API  (Sign in with a username)
 *
 * Paths: server/src/routes/username.routes.js, mounted under /account/username.
 * available() needs no sign-in, so the sign-up form can use it.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const UsernameSchema = z.object({ username: z.string().nullable() }).passthrough();
const AvailableSchema = z.object({ available: z.boolean(), problem: z.string().nullable() }).passthrough();

export interface UsernameApi {
  mine(signal?: AbortSignal): Promise<{ username: string | null }>;
  available(name: string, signal?: AbortSignal): Promise<{ available: boolean; problem: string | null }>;
  set(username: string | null): Promise<{ username: string | null }>;
}

export const createUsernameApi = (http: HttpClient): UsernameApi => ({
  mine: (signal) => http.get('/account/username', { schema: UsernameSchema, signal }),
  available: (name, signal) =>
    http.get('/account/username/available', { schema: AvailableSchema, query: { name }, signal, anonymous: true }),
  set: (username) => http.put('/account/username', { username }, { schema: UsernameSchema }),
});
__LOOK_EOF__
echo "wrote packages/core-client/src/api/usernameApi.ts"

mkdir -p apps/web/src/components/Auth/__checks__
cat > apps/web/src/components/Auth/__checks__/authModel.check.mjs <<'__LOOK_EOF__'
// Landing — sign-in and sign-up helpers.
// Run: node --test apps/web/src/components/Auth/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { destinationOf, passwordStrength, safeNext, validateSignup, withNext } from '../authModel.js';

test('password strength grows with length first', () => {
  assert.equal(passwordStrength(''), 0);
  assert.equal(passwordStrength('short'), 1);
  assert.equal(passwordStrength('abcdefghijkl'), 2);
  assert.equal(passwordStrength('Abcdefghijk1'), 3);
  assert.equal(passwordStrength('correct horse battery staple'), 4);
});

test('sign-up validation', () => {
  assert.deepEqual(validateSignup({ displayName: 'Anna', email: 'anna@example.com', password: 'twelve chars!' }), {});
  const errors = validateSignup({ displayName: ' ', email: 'anna@', password: 'short' });
  assert.ok(errors.displayName && errors.email && errors.password);
});

test('destinations after signing in never leave the app', () => {
  assert.equal(destinationOf({ search: '?next=%2Frooms%2Fnew' }), '/rooms/new');
  assert.equal(destinationOf({ search: '?next=https%3A%2F%2Fevil.example' }), '/');
  assert.equal(destinationOf({ search: '?next=%2F%2Fevil.example' }), '/');
  assert.equal(destinationOf({ state: { from: '/rooms/abc-defg-hjk/lobby' } }), '/rooms/abc-defg-hjk/lobby');
  assert.equal(destinationOf({}), '/');
  assert.equal(safeNext('/\\evil'), '/');
  assert.equal(withNext('/signup', '/rooms/new'), '/signup?next=%2Frooms%2Fnew');
  assert.equal(withNext('/signup', '/'), '/signup');
});

import { usernameProblem } from '../authModel.js';

test('usernames: the same rules as the server, and optional at sign-up', () => {
  assert.equal(usernameProblem('anna.b'), null);
  assert.match(usernameProblem('ab'), /At least 3/);
  assert.match(usernameProblem('anna@x'), /"@"/);
  assert.match(usernameProblem('an..na'), /two dots/);
  assert.deepEqual(validateSignup({ displayName: 'Anna', email: 'anna@example.com', password: 'twelve chars!', username: '' }), {});
  assert.ok(validateSignup({ displayName: 'Anna', email: 'anna@example.com', password: 'twelve chars!', username: '.x' }).username);
});
__LOOK_EOF__
echo "wrote apps/web/src/components/Auth/__checks__/authModel.check.mjs"

mkdir -p apps/web/src/components/Auth
cat > apps/web/src/components/Auth/auth.css <<'__LOOK_EOF__'
/* Sign-in and sign-up — see components/Auth/AuthShell.jsx.
   Same palette and type as the homepage (components/Landing/landing.css):
   a light page for the form, and the slate board as the one dark panel. */

@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500..800&display=swap');

.au {
  --au-board: #15262b;
  --au-board-2: #1d353b;
  --au-board-3: #26444b;
  --au-chalk: #eef2ee;
  --au-chalk-2: rgba(238, 242, 238, 0.72);
  --au-chalk-3: rgba(238, 242, 238, 0.5);
  --au-sun: #ffd54a;
  --au-sun-ink: #2a2206;
  --au-sky: #8cc8ff;
  --au-danger: #b3261e;
  --au-paper: #f4f8f7;
  --au-white: #ffffff;
  --au-ink: #13262b;
  --au-ink-2: #3f5559;
  --au-ink-3: #6b7f82;
  --au-line: #d8e3e0;
  --au-display: 'Bricolage Grotesque', 'Segoe UI', system-ui, sans-serif;
  --au-body: 'Atkinson Hyperlegible', system-ui, -apple-system, 'Segoe UI', sans-serif;

  min-height: 100vh;
  display: grid;
  grid-template-columns: minmax(320px, 0.9fr) minmax(0, 1.1fr);
  background: var(--au-paper);
  color: var(--au-ink);
  font-family: var(--au-body);
  font-size: 16.5px;
  line-height: 1.55;
}
.au :focus-visible { outline: 3px solid #2e6fd8; outline-offset: 2px; border-radius: 6px; }
:where(.au) a { color: #2e6fd8; }

.au-board {
  position: relative; display: flex; flex-direction: column; justify-content: space-between; gap: 32px;
  padding: 32px 40px 40px;
  background:
    radial-gradient(700px 400px at 20% 110%, rgba(255, 213, 74, 0.12), transparent 60%),
    radial-gradient(600px 400px at 110% -10%, rgba(140, 200, 255, 0.12), transparent 60%),
    var(--au-board-2);
  color: var(--au-chalk);
  overflow: hidden;
}
.au-brand { display: inline-flex; align-items: center; gap: 10px; color: var(--au-chalk) !important; text-decoration: none; font: 750 20px/1 var(--au-display); }
.au-brand__mark { width: 28px; height: 28px; fill: none; stroke: var(--au-chalk); stroke-width: 2.2; stroke-linecap: round; }
.au-brand__mark circle { fill: var(--au-sun); stroke: none; }
.au-board__art { align-self: center; text-align: center; }
.au-board__big { margin: 0; color: var(--au-chalk-2); }
.au-board__count { margin: 0; font: 800 clamp(64px, 9vw, 120px) / 1 var(--au-display); font-variation-settings: 'wdth' 80; letter-spacing: -0.03em; font-variant-numeric: tabular-nums; }
.au-board__track { display: block; width: min(280px, 70%); height: 10px; margin: 18px auto 0; border-radius: 5px; background: rgba(238, 242, 238, 0.12); overflow: hidden; }
.au-board__track i { display: block; width: 72%; height: 100%; border-radius: 5px; background: repeating-linear-gradient(45deg, rgba(255, 213, 74, 0.8) 0 6px, rgba(255, 213, 74, 0.5) 6px 12px); }
.au-board__line { margin: 0; max-width: 24em; font: 700 22px/1.3 var(--au-display); letter-spacing: -0.01em; }

.au-main { color: var(--au-ink); display: flex; flex-direction: column; justify-content: center; align-items: center; gap: 20px; padding: 48px 24px; }
.au-card { width: 100%; max-width: 420px; }
.au-title { margin: 0; font: 800 clamp(32px, 4vw, 44px) / 1.05 var(--au-display); letter-spacing: -0.03em; }
.au-lead { margin: 10px 0 0; color: var(--au-ink-2); }
.au-footer { width: 100%; max-width: 420px; color: var(--au-ink-2); font-size: 15px; }
.au-footer p { margin: 6px 0; }

.au-form { display: grid; gap: 16px; margin-top: 28px; }
.au-field { display: grid; gap: 6px; }
.au-label { font-weight: 700; font-size: 15px; }
.au-hint { font-size: 13.5px; color: var(--au-ink-3); }
.au-input-wrap { position: relative; }
.au-input {
  width: 100%; box-sizing: border-box; min-height: 48px; padding: 12px 14px; border-radius: 12px;
  border: 1.5px solid var(--au-line); background: var(--au-white); color: var(--au-ink); font: inherit;
  transition: border-color 0.25s ease, box-shadow 0.35s cubic-bezier(0.16, 1, 0.3, 1);
}
.au-input:focus { border-color: var(--au-ink); outline: none; box-shadow: 0 0 0 4px rgba(255, 213, 74, 0.45); }
.au-input[aria-invalid='true'] { border-color: var(--au-danger); }
.au-input--code { font-size: 22px; letter-spacing: 0.25em; text-align: center; }
.au-reveal { position: absolute; right: 8px; top: 50%; transform: translateY(-50%); padding: 6px 10px; border: 0; border-radius: 8px; background: transparent; color: var(--au-ink-2); font: inherit; font-size: 14px; cursor: pointer; }
.au-reveal:hover { color: var(--au-ink); background: #eaf2f0; }

.au-meter { display: flex; gap: 4px; margin-top: 2px; }
.au-meter i { flex: 1; height: 5px; border-radius: 3px; background: #dbe6e3; transition: background-color 0.3s ease; }
.au-meter[data-level='1'] i:nth-child(-n + 1) { background: #e0584f; }
.au-meter[data-level='2'] i:nth-child(-n + 2) { background: #e8b400; }
.au-meter[data-level='3'] i:nth-child(-n + 3) { background: #6bb84a; }
.au-meter[data-level='4'] i { background: #1e9a77; }

.au-button {
  display: inline-flex; align-items: center; justify-content: center; min-height: 50px; padding: 0 22px;
  border: 2px solid transparent; border-radius: 999px; font: 700 16px/1 var(--au-body); cursor: pointer; text-decoration: none;
}
.au-button { transition: transform 0.35s cubic-bezier(0.16, 1, 0.3, 1), background-color 0.25s ease, border-color 0.25s ease; }
.au-button:active:not(:disabled) { transform: scale(0.98); }
.au-button--primary { background: var(--au-sun); color: var(--au-sun-ink); box-shadow: 0 8px 22px -10px rgba(214, 160, 0, 0.7); }
.au-button--primary:hover { background: #ffe07a; }
.au-button--primary:disabled { opacity: 0.6; cursor: default; }
.au-button--ghost { background: var(--au-white); color: var(--au-ink); border-color: var(--au-line); }
.au-button--ghost:hover { border-color: var(--au-ink-3); }
.au-textbutton { justify-self: start; padding: 0; border: 0; background: none; color: #2e6fd8; font: inherit; font-size: 15px; cursor: pointer; text-decoration: underline; text-underline-offset: 3px; }

.au-or { display: flex; align-items: center; gap: 12px; color: var(--au-ink-3); font-size: 14px; }
.au-or::before, .au-or::after { content: ''; flex: 1; height: 1px; background: var(--au-line); }

.au-alert { margin: 0; padding: 12px 14px; border-radius: 12px; font-size: 15px; }
.au-alert--error { background: #fde8e6; color: #8c1d18; }
.au-alert--info { background: #e0ecff; color: #173a73; }

@media (max-width: 860px) {
  .au { grid-template-columns: 1fr; }
  .au-board { flex-direction: row; align-items: center; padding: 18px 20px; }
  .au-board__art { display: none; }
  .au-board__line { display: none; }
  .au-main { justify-content: flex-start; padding-top: 36px; }
}
@media (prefers-reduced-motion: reduce) { .au-meter i { transition: none; } }

.au-card, .au-footer { animation: au-in 0.9s cubic-bezier(0.16, 1, 0.3, 1) both; }
.au-footer { animation-delay: 0.12s; }
@keyframes au-in { from { opacity: 0; transform: translateY(18px); filter: blur(6px); } to { opacity: 1; transform: none; filter: none; } }
@media (prefers-reduced-motion: reduce) { .au-card, .au-footer { animation: none; } .au-button, .au-input { transition: none; } }

.au-optional { margin-left: 6px; font-weight: 400; font-size: 13px; color: var(--au-ink-3); }
__LOOK_EOF__
echo "wrote apps/web/src/components/Auth/auth.css"

mkdir -p apps/web/src/components/Auth
cat > apps/web/src/components/Auth/authModel.js <<'__LOOK_EOF__'
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

/**
 * The server's username rules (server/src/identity/usernameRules.js), for an
 * early answer while typing. The server decides; reserved names it knows.
 */
export const usernameProblem = (value) => {
  const name = String(value ?? '').trim().toLowerCase();
  if (name.length < 3) return 'At least 3 characters.';
  if (name.length > 30) return 'At most 30 characters.';
  if (name.includes('@')) return 'A username cannot contain "@".';
  if (!/^[a-z0-9._-]+$/.test(name)) return 'Only letters a–z, digits, dot, hyphen and underscore.';
  if (!/^[a-z0-9]/.test(name) || !/[a-z0-9]$/.test(name)) return 'Start and end with a letter or a digit.';
  if (/[._-]{2}/.test(name)) return 'No two dots, hyphens or underscores in a row.';
  return null;
};

/** Problems with the sign-up form, keyed by field; empty when it can be sent. The username is optional. */
export const validateSignup = ({ displayName, email, password, username = '' }) => {
  const errors = {};
  if (String(username ?? '').trim()) {
    const problem = usernameProblem(username);
    if (problem) errors.username = problem;
  }
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
__LOOK_EOF__
echo "wrote apps/web/src/components/Auth/authModel.js"

mkdir -p apps/web/src/components/Chat
cat > apps/web/src/components/Chat/messages.css <<'__LOOK_EOF__'
/* Messages page — see pages/MessagesPage.jsx.
 *
 * The page is exactly as tall as the window below the top bar. Inside it the
 * list or the open conversation scrolls on its own, so the conversation's
 * header — back button, name, ⋯ menu — never scrolls out of view.
 * Colours come from the app's variables (styles/theme.css), so this follows
 * the app's look.
 */

.messages-page {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-width: 1280px;
  margin: 0 auto;
  height: calc(100dvh - 150px);
  min-height: 420px;
}
.app .app__content:has(.messages-page) { padding-bottom: 20px; }

.messages-page__head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex: 0 0 auto; }
.messages-page__head h1 { margin: 0; display: flex; align-items: center; gap: 10px; }

.messages-page__panel {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  border-radius: 18px;
  border: 1px solid var(--color-border, rgba(127, 140, 140, 0.25));
  background: var(--color-surface, #223a41);
  box-shadow: 0 18px 40px -28px rgba(0, 0, 0, 0.5);
  overflow: hidden;
}
.messages-page .rooms { flex: 1 1 auto; min-height: 0; gap: 0; }
.messages-page .rooms-list { padding: 8px; flex: 1 1 auto; min-height: 0; }
.messages-page .rooms-row { padding: 10px 12px; border-radius: 12px; grid-template-columns: 42px 1fr auto auto; gap: 12px; }
.messages-page .rooms-row:hover, .messages-page .rooms-row:focus-visible { background: rgba(127, 140, 140, 0.14); }
.messages-page .rooms-row__avatar { width: 42px; height: 42px; font-size: 16px; background: rgba(90, 123, 242, 0.22); color: inherit; }
.messages-page .rooms-row__name { font-size: 15.5px; }
.messages-page .rooms-row__preview { font-size: 13.5px; }
.messages-page .rooms-notice { padding: 18px 16px; margin: 0; }

/* The conversation header: always visible, large enough to hit. */
.messages-page .rooms-head {
  position: sticky;
  top: 0;
  z-index: 5;
  flex: 0 0 auto;
  gap: 12px;
  padding: 10px 12px;
  border-bottom: 1px solid var(--color-border, rgba(127, 140, 140, 0.25));
  background: var(--color-surface, #223a41);
}
.messages-page .rooms-head > .btn,
.messages-page .rooms-menu > .btn {
  min-width: 44px;
  min-height: 44px;
  padding: 0 14px;
  border-radius: 12px;
  font-size: 20px;
  line-height: 1;
}
.messages-page .rooms-head__title { font-size: 17px; }
.messages-page .rooms-menu__items { min-width: 260px; border-radius: 14px; border: 1px solid var(--color-border, rgba(127, 140, 140, 0.25)); }
.messages-page .rooms-menu__item { padding: 10px 12px; font-size: 14.5px; }

.messages-page .thread { flex: 1 1 auto; min-height: 0; }
.messages-page .thread__messages { padding: 16px; gap: 8px; }
.messages-page .bubble { max-width: 75%; padding: 9px 13px; font-size: 15px; line-height: 1.45; }
.messages-page .thread__composer { padding: 12px; background: rgba(127, 140, 140, 0.08); }
.messages-page .thread__composer input { padding: 11px 16px; font-size: 15px; }
.messages-page .thread__composer .btn { min-height: 44px; padding: 0 18px; border-radius: 999px; }
.messages-page .rooms-status { padding: 6px 14px; }

/* New message */
.msg-new {
  flex: 0 0 auto; display: grid; gap: 10px; padding: 16px; border-radius: 18px;
  border: 1px solid var(--color-border, rgba(127, 140, 140, 0.25)); background: var(--color-surface, #223a41);
  box-shadow: 0 18px 40px -28px rgba(0, 0, 0, 0.5);
  animation: msg-in 0.35s cubic-bezier(0.16, 1, 0.3, 1) both;
}
@keyframes msg-in { from { opacity: 0; transform: translateY(-6px); } to { opacity: 1; transform: none; } }
.msg-new__head { display: flex; align-items: center; justify-content: space-between; }
.msg-new__title { margin: 0; font-weight: 700; font-size: 16px; }
.msg-iconbtn { width: 40px; height: 40px; border: 0; border-radius: 12px; background: transparent; color: inherit; font-size: 24px; cursor: pointer; }
.msg-iconbtn:hover { background: rgba(127, 140, 140, 0.16); }
.msg-new__search {
  width: 100%; box-sizing: border-box; padding: 12px 14px; border-radius: 12px; font: inherit; font-size: 15px;
  border: 1px solid var(--color-border, rgba(127, 140, 140, 0.3)); background: var(--color-surface-2, rgba(127, 140, 140, 0.1)); color: inherit;
}
.msg-new__hint { margin: 0; font-size: 13.5px; color: var(--color-muted, #a8bcb9); }
.msg-new__error { margin: 0; font-size: 14px; color: #ef6b6f; }
.msg-new__results { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; max-height: 280px; overflow-y: auto; }
.msg-new__results button { width: 100%; display: flex; align-items: center; gap: 12px; padding: 8px 10px; border: 0; border-radius: 12px; background: transparent; color: inherit; font: inherit; font-size: 15px; text-align: left; cursor: pointer; }
.msg-new__results button:hover, .msg-new__results button:focus-visible { background: rgba(127, 140, 140, 0.14); }
.msg-new__avatar { width: 36px; height: 36px; border-radius: 50%; overflow: hidden; display: grid; place-items: center; background: rgba(90, 123, 242, 0.22); font-weight: 700; flex: 0 0 auto; }
.msg-new__avatar img { width: 100%; height: 100%; object-fit: cover; }

@media (max-width: 620px) {
  .messages-page { height: calc(100dvh - 120px); }
  .messages-page .bubble { max-width: 85%; }
}
@media (prefers-reduced-motion: reduce) { .msg-new { animation: none; } }

/* Wide screens: the list and the conversation side by side. */
.messages-split { flex: 1 1 auto; min-height: 0; display: grid; grid-template-columns: minmax(280px, 360px) minmax(0, 1fr); gap: 14px; }
.messages-split > .messages-page__panel { min-height: 0; }
.messages-split__list .rooms-list { padding: 8px; }
/* Beside the list, "back to the list" has nowhere to go. */
.messages-split__chat .rooms-head > .btn:first-child { display: none; }
.messages-split__chat .rooms-head { padding-left: 18px; }
.messages-page .rooms-row--active { background: rgba(90, 123, 242, 0.14); box-shadow: inset 3px 0 0 var(--color-accent, #5a7bf2); }
.messages-page .rooms-row--active:hover { background: rgba(90, 123, 242, 0.18); }
.messages-split__empty { flex: 1; display: grid; place-content: center; justify-items: center; gap: 6px; padding: 24px; text-align: center; }
.messages-split__empty span { font-size: 40px; }
.messages-split__empty p { margin: 0; }
.messages-split__title { font-weight: 700; font-size: 17px; }
__LOOK_EOF__
echo "wrote apps/web/src/components/Chat/messages.css"

mkdir -p apps/web/src/components/Hub
cat > apps/web/src/components/Hub/hub.css <<'__LOOK_EOF__'
/* Community — see pages/CommunityPage.jsx. Light theme since the Files update.
   Uses the app's colour variables (theme.css), so it follows the app's look,
   and adds the community's own structure: a rail, rows, posts, a composer. */

.hb { display: grid; grid-template-columns: 260px minmax(0, 1fr); gap: 32px; align-items: start; max-width: 1180px; margin: 0 auto; }
.hb-main { min-width: 0; animation: hb-in 0.5s cubic-bezier(0.16, 1, 0.3, 1) both; }
@keyframes hb-in { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
@media (max-width: 900px) { .hb { grid-template-columns: minmax(0, 1fr); gap: 16px; } }
@media (prefers-reduced-motion: reduce) { .hb-main { animation: none; } }

.hb-muted { color: var(--color-muted, #a8bcb9); font-size: 14px; }
.hb-error { color: #c93636; font-size: 14px; margin: 4px 0 0; }
.hb-label { display: block; font-weight: 700; font-size: 15px; }
.hb-inline { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.hb-note { padding: 12px 14px; border-radius: 12px; background: rgba(255, 213, 74, 0.1); color: #7a5600; font-size: 14.5px; }
.hb-link { border: 0; padding: 0; background: none; color: #2f63d6; font: inherit; font-size: 14px; cursor: pointer; text-decoration: none; }
.hb-link:hover { text-decoration: underline; text-underline-offset: 3px; }
.hb-link--quiet { color: var(--color-muted, #a8bcb9); }
.hb-link--danger { color: #c93636; }
.hb-link:disabled { opacity: 0.5; cursor: default; }
.hb-anon { font-style: italic; color: var(--color-muted, #a8bcb9); }
.hb :where(p, h1, h2, span) a:not([class]) { color: #2f63d6; text-underline-offset: 3px; }
.hb .page, .hb { min-width: 0; }

.hb-input { width: 100%; box-sizing: border-box; padding: 10px 12px; border-radius: 12px; border: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface-2, #2f4f57); color: inherit; font: inherit; font-size: 15px; }
.hb-input--title { font-size: 17px; font-weight: 700; }
.hb-input--small { width: auto; padding: 6px 8px; font-size: 13px; }
textarea.hb-input { resize: vertical; line-height: 1.5; }

.hb-head { margin-bottom: 18px; }
.hb-head h1 { margin: 0 0 4px; font-size: clamp(26px, 3vw, 34px); }
.hb-head .hb-muted { margin: 0; font-size: 15px; }

/* ---------------- rail */
.hb-rail { position: sticky; top: 86px; display: flex; flex-direction: column; gap: 6px; }
.hb-rail__places { display: flex; flex-direction: column; gap: 2px; }
.hb-place { display: flex; justify-content: space-between; align-items: center; padding: 10px 14px; border-radius: 12px; color: var(--color-muted, #a8bcb9); text-decoration: none; font-weight: 700; transition: background-color 0.3s ease, color 0.2s ease; }
.hb-place:hover { background: rgba(20, 38, 43, 0.06); color: var(--color-text, #eef4f2); }
.hb-place.is-on { background: rgba(20, 38, 43, 0.11); color: var(--color-text, #eef4f2); }
.hb-place--new { color: #ffd54a; }
.hb-count { min-width: 22px; padding: 1px 7px; border-radius: 999px; background: #ffd54a; color: #2a2206; font-size: 12px; text-align: center; }
.hb-rail__head { margin: 18px 14px 4px; font-size: 13px; font-weight: 700; color: var(--color-muted, #a8bcb9); }
.hb-rail__empty { margin: 4px 14px; }
.hb-rail__spaces { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.hb-spacelink { display: flex; align-items: center; gap: 10px; padding: 7px 10px; border-radius: 12px; color: var(--color-text, #eef4f2); text-decoration: none; transition: background-color 0.3s ease; }
.hb-spacelink:hover { background: rgba(20, 38, 43, 0.06); }
.hb-spacelink.is-on { background: rgba(20, 38, 43, 0.11); }
.hb-spacelink__name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14.5px; }
.hb-dot { width: 8px; height: 8px; border-radius: 50%; background: #ffd54a; flex: 0 0 auto; }
@media (max-width: 900px) {
  .hb-rail { position: static; }
  .hb-rail__places { flex-direction: row; overflow-x: auto; }
  .hb-place { white-space: nowrap; }
  .hb-rail__head, .hb-rail__spaces, .hb-rail__empty { display: none; }
}

.hb-mark { display: inline-grid; place-items: center; width: 30px; height: 30px; border-radius: 9px; flex: 0 0 auto; font-weight: 800; font-size: 15px; color: #13262b; }
.hb-mark--topic { background: #8cc8ff; }
.hb-mark--study { background: #ffd54a; }
.hb-mark--class { background: #7fd6b4; }
.hb-mark--big { width: 44px; height: 44px; border-radius: 13px; font-size: 20px; }
.hb-mark--huge { width: 64px; height: 64px; border-radius: 18px; font-size: 30px; }

/* ---------------- home */
.hb-tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 12px; margin: 8px 0 28px; }
.hb-tile { display: flex; flex-direction: column; gap: 6px; padding: 16px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); color: inherit; text-decoration: none; transition: transform 0.35s cubic-bezier(0.16, 1, 0.3, 1), border-color 0.25s ease; }
.hb-tile:hover { transform: translateY(-2px); border-color: #c3d0cc; }
.hb-tile__name { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hb-block { margin-top: 26px; }
.hb-block__title { margin: 0 0 10px; font-size: 18px; }
.hb-empty { max-width: 560px; padding: 32px; border-radius: 20px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); display: grid; gap: 12px; }
.hb-empty__title { margin: 0; font: 780 26px/1.15 'Bricolage Grotesque', var(--font-sans, system-ui); }

/* ---------------- lists of threads */
.hb-list { display: flex; flex-direction: column; gap: 8px; }
.hb-row { display: flex; gap: 16px; justify-content: space-between; padding: 16px 18px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); color: inherit; text-decoration: none; transition: border-color 0.25s ease, transform 0.35s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-row:hover { border-color: #c3d0cc; transform: translateY(-1px); }
.hb-row.is-pinned { border-color: rgba(255, 213, 74, 0.35); }
.hb-row__main { min-width: 0; }
.hb-row__meta { margin: 0 0 4px; display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.hb-row__space { font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-row__title { margin: 0; font-weight: 700; font-size: 16.5px; line-height: 1.35; }
.hb-row__excerpt { margin: 4px 0 0; color: var(--color-muted, #a8bcb9); font-size: 14.5px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.hb-row__by { margin: 8px 0 0; font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-row__stats { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; flex: 0 0 auto; font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-stat strong { color: var(--color-text, #eef4f2); font-size: 15px; }
.hb-stat.is-mine strong { color: #ffd54a; }

.hb-badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; font-weight: 700; background: rgba(20, 38, 43, 0.1); color: var(--color-text, #eef4f2); margin-left: 6px; }
.hb-row__meta .hb-badge, .hb-post__head .hb-badge { margin-left: 0; }
.hb-badge--open { background: rgba(140, 200, 255, 0.18); color: #1f4fb8; }
.hb-badge--done { background: rgba(127, 214, 180, 0.18); color: #13734f; }
.hb-badge--pin { background: rgba(255, 213, 74, 0.16); color: #7a5600; }
.hb-badge--warn { background: rgba(255, 155, 145, 0.16); color: #a12a2a; }

/* ---------------- toolbars */
.hb-toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; margin: 6px 0 14px; }
.hb-segment { display: inline-flex; gap: 2px; padding: 3px; border-radius: 999px; background: rgba(20, 38, 43, 0.07); }
.hb-segment button { padding: 7px 14px; border: 0; border-radius: 999px; background: transparent; color: var(--color-muted, #a8bcb9); font: inherit; font-size: 14px; cursor: pointer; transition: background-color 0.3s ease, color 0.2s ease; }
.hb-segment button.is-on { background: rgba(20, 38, 43, 0.14); color: var(--color-text, #eef4f2); font-weight: 700; }
.hb-sort { display: inline-flex; align-items: center; gap: 8px; font-size: 14px; color: var(--color-muted, #a8bcb9); }
.hb-sort .hb-input { width: auto; }
.hb-search { flex: 1 1 260px; }
.hb-toolbar > select.hb-input { width: auto; }

/* ---------------- discover */
.hb-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 14px; }
.hb-card { display: flex; flex-direction: column; gap: 10px; padding: 18px; border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); }
.hb-card__top { display: flex; gap: 12px; align-items: center; }
.hb-card__top p { margin: 0; }
.hb-card__name { font-weight: 800; font-size: 17px; }
.hb-card__text { margin: 0; font-size: 14.5px; }
.hb-card__foot { margin-top: auto; display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; }
.hb-tags { margin: 0; display: flex; flex-wrap: wrap; gap: 6px; }
.hb-tag { padding: 3px 10px; border: 0; border-radius: 999px; background: rgba(20, 38, 43, 0.08); color: var(--color-muted, #a8bcb9); font: inherit; font-size: 13px; cursor: pointer; }
.hb-tag:hover { color: var(--color-text, #eef4f2); }
.hb-ask { display: grid; gap: 8px; width: 100%; }

/* ---------------- forms */
.hb-form { display: grid; gap: 18px; max-width: 680px; }
.hb-fieldset { margin: 0; padding: 18px; border-radius: 18px; border: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface, #27434a); display: grid; gap: 14px; }
.hb-fieldset legend { padding: 0 6px; font-weight: 800; }
.hb-field { display: grid; gap: 6px; }
.hb-row2 { display: grid; grid-template-columns: 90px 1fr; gap: 12px; }
.hb-field--emoji .hb-input { text-align: center; font-size: 22px; }
.hb-options { display: grid; gap: 8px; }
.hb-option { display: flex; gap: 12px; align-items: flex-start; padding: 12px 14px; border-radius: 14px; border: 1px solid var(--color-border, #dbe4e1); cursor: pointer; transition: border-color 0.25s ease, background-color 0.25s ease; }
.hb-option.is-on { border-color: rgba(255, 213, 74, 0.6); background: rgba(255, 213, 74, 0.06); }
.hb-option input { margin-top: 4px; accent-color: #ffd54a; }
.hb-option .hb-muted { display: block; }
.hb-check { display: flex; gap: 12px; align-items: flex-start; cursor: pointer; }
.hb-check input { margin-top: 4px; width: 18px; height: 18px; accent-color: #ffd54a; }
.hb-check .hb-muted { display: block; }

/* ---------------- a space */
.hb-space__head { display: flex; gap: 16px; align-items: center; margin-bottom: 14px; }
.hb-space__title { flex: 1; min-width: 0; }
.hb-space__title h1 { margin: 0; font-size: clamp(26px, 3vw, 34px); overflow-wrap: anywhere; }
.hb-space__title p { margin: 2px 0 0; }
.hb-joinbox { display: grid; gap: 8px; padding: 16px; border-radius: 16px; background: rgba(140, 200, 255, 0.08); margin-bottom: 16px; }
.hb-joinbox .hb-inline .hb-input { flex: 1 1 240px; width: auto; }
.hb-tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--color-border, #dbe4e1); margin-bottom: 18px; overflow-x: auto; }
.hb-tab { padding: 10px 11px; border: 0; border-bottom: 2px solid transparent; background: none; color: var(--color-muted, #a8bcb9); font: inherit; font-weight: 700; font-size: 14.5px; cursor: pointer; white-space: nowrap; transition: color 0.2s ease, border-color 0.3s ease; }
.hb-tab.is-on { color: var(--color-text, #eef4f2); border-bottom-color: #ffd54a; }
.hb-panel { animation: hb-in 0.45s cubic-bezier(0.16, 1, 0.3, 1) both; }

.hb-starter { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 14px; }
.hb-starter__button { padding: 16px; border-radius: 16px; border: 1px dashed #c3d0cc; background: transparent; color: var(--color-text, #eef4f2); font: inherit; font-weight: 700; cursor: pointer; transition: border-color 0.25s ease, background-color 0.25s ease; }
.hb-starter__button:hover { border-color: rgba(255, 213, 74, 0.6); background: rgba(255, 213, 74, 0.05); }
.hb-composer { display: grid; gap: 10px; padding: 16px; border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); margin-bottom: 16px; animation: hb-in 0.4s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-composer .hb-segment { justify-self: start; }

.hb-members { list-style: none; margin: 10px 0 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.hb-member { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 14px; background: var(--color-surface, #27434a); }
.hb-member__name { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; font-weight: 700; }
.hb-member__name .hb-badge { align-self: flex-start; margin-left: 0; }
.hb-member__actions { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.hb-avatar { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 50%; background: rgba(20, 38, 43, 0.12); font-weight: 800; flex: 0 0 auto; }

.hb-reports { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
.hb-reportcard { display: grid; gap: 6px; padding: 14px; border-radius: 14px; background: var(--color-surface, #27434a); border-left: 3px solid #c93636; }
.hb-reportcard p { margin: 0; }
.hb-report { display: grid; gap: 8px; padding: 10px; border-radius: 12px; background: var(--color-surface-2, #f1f5f4); min-width: 240px; }

.hb-about { display: grid; gap: 16px; max-width: 640px; }
.hb-facts { margin: 0; display: grid; gap: 10px; }
.hb-facts div { display: grid; grid-template-columns: 140px 1fr; gap: 12px; }
.hb-facts dt { color: var(--color-muted, #a8bcb9); }
.hb-facts dd { margin: 0; }

/* ---------------- a thread */
.hb-thread { max-width: 820px; }
.hb-crumbs { margin: 0 0 12px; }
.hb-crumbs a { display: inline-flex; align-items: center; gap: 8px; color: var(--color-muted, #a8bcb9); text-decoration: none; font-weight: 700; }
.hb-crumbs a:hover { color: var(--color-text, #eef4f2); }
.hb-crumbs .hb-mark { width: 24px; height: 24px; border-radius: 7px; font-size: 13px; }
.hb-thread__title { margin: 4px 0 10px; font-size: clamp(24px, 3vw, 32px); line-height: 1.15; overflow-wrap: anywhere; }
.hb-thread__count { margin: 26px 0 10px; font-size: 16px; color: var(--color-muted, #a8bcb9); }
.hb-post { padding: 18px 20px; border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); margin-bottom: 10px; }
.hb-post--first { background: linear-gradient(180deg, rgba(20, 38, 43, 0.04), transparent 50%), var(--color-surface, #27434a); }
.hb-post.is-answer { border-color: rgba(127, 214, 180, 0.55); box-shadow: 0 0 0 3px rgba(127, 214, 180, 0.08); }
.hb-post__head { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; font-size: 14px; }
.hb-post__author { font-weight: 700; display: inline-flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.hb-post__body { margin-top: 10px; font-size: 16px; line-height: 1.65; overflow-wrap: anywhere; }
.hb-post__body p { margin: 0 0 10px; white-space: pre-wrap; }
.hb-post__body p:last-child { margin-bottom: 0; }
.hb-post__foot { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; margin-top: 12px; }
.hb-metoo { display: inline-flex; align-items: center; gap: 10px; padding: 7px 8px 7px 14px; border-radius: 999px; border: 1px solid #c3d0cc; background: transparent; color: var(--color-text, #eef4f2); font: inherit; font-size: 14px; font-weight: 700; cursor: pointer; transition: background-color 0.3s ease, border-color 0.3s ease, transform 0.3s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-metoo:hover:not(:disabled) { border-color: rgba(255, 213, 74, 0.6); }
.hb-metoo:active:not(:disabled) { transform: scale(0.97); }
.hb-metoo.is-on { background: rgba(255, 213, 74, 0.14); border-color: rgba(255, 213, 74, 0.6); }
.hb-metoo:disabled { cursor: default; opacity: 0.8; }
.hb-metoo__count { min-width: 26px; padding: 2px 8px; border-radius: 999px; background: rgba(20, 38, 43, 0.12); text-align: center; }
.hb-metoo.is-on .hb-metoo__count { background: #ffd54a; color: #2a2206; }
.hb-composer--reply { margin-top: 18px; }

@media (max-width: 620px) {
  .hb-row { flex-direction: column; gap: 8px; }
  .hb-row__stats { flex-direction: row; align-items: center; gap: 12px; }
  .hb-starter { grid-template-columns: 1fr; }
  .hb-facts div { grid-template-columns: 1fr; gap: 2px; }
  .hb-space__head { flex-wrap: wrap; }
}
@media (prefers-reduced-motion: reduce) {
  .hb-panel, .hb-composer { animation: none; }
  .hb-row, .hb-tile, .hb-metoo { transition: none; }
}

/* ================================================================ part 2 */

/* Live now */
.hb-livebar { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 12px 16px; margin-bottom: 14px; border-radius: 14px; background: rgba(255, 107, 94, 0.12); border: 1px solid rgba(255, 107, 94, 0.3); }
.hb-livebar > span:nth-child(2) { flex: 1; min-width: 200px; }
.hb-livebar .btn { margin-left: auto; }
.hb-livedot { width: 10px; height: 10px; border-radius: 50%; background: #ff6b5e; box-shadow: 0 0 0 0 rgba(255, 107, 94, 0.6); animation: hb-pulse 1.8s ease-out infinite; flex: 0 0 auto; }
.hb-livedot.is-off { background: rgba(20, 38, 43, 0.3); animation: none; }
@keyframes hb-pulse { 0% { box-shadow: 0 0 0 0 rgba(255, 107, 94, 0.55); } 70% { box-shadow: 0 0 0 9px rgba(255, 107, 94, 0); } 100% { box-shadow: 0 0 0 0 rgba(255, 107, 94, 0); } }
.hb-block--live { margin-top: 0; }

/* Rooms */
.hb-dropin { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 16px; padding: 18px; margin-bottom: 16px; border-radius: 18px; background: linear-gradient(135deg, rgba(255, 213, 74, 0.1), rgba(140, 200, 255, 0.08)); border: 1px solid rgba(255, 213, 74, 0.25); }
.hb-dropin p { margin: 0; }
.hb-dropin .hb-muted { margin-top: 4px; max-width: 44em; }
.hb-roomlist { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.hb-roomitem { display: flex; align-items: center; gap: 14px; padding: 14px 16px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); }
.hb-roomitem.is-live { border-color: rgba(255, 107, 94, 0.35); }
.hb-roomitem__text { flex: 1; min-width: 0; display: grid; gap: 2px; }
.app a.btn.btn--tiny, .hb a.btn--tiny { padding: 5px 12px; font-size: 13px; }

/* Chat */
.hb-chat { display: flex; flex-direction: column; height: clamp(420px, calc(100vh - 360px), 720px); border-radius: 18px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); overflow: hidden; }
.hb-chat__list { flex: 1; overflow-y: auto; padding: 16px 16px 8px; display: flex; flex-direction: column; gap: 10px; }
.hb-chat__empty { margin: auto; color: var(--color-muted, #a8bcb9); }
.hb-chat__day { align-self: center; margin: 6px 0; padding: 3px 12px; border-radius: 999px; background: rgba(20, 38, 43, 0.07); font-size: 12.5px; color: var(--color-muted, #a8bcb9); }
.hb-msggroup { display: flex; gap: 10px; align-items: flex-start; animation: hb-in 0.35s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-msggroup.is-mine { flex-direction: row-reverse; }
.hb-msggroup__body { display: flex; flex-direction: column; gap: 3px; max-width: min(78%, 560px); }
.hb-msggroup.is-mine .hb-msggroup__body { align-items: flex-end; }
.hb-msggroup__who { margin: 0 4px 2px; font-size: 13px; font-weight: 700; display: flex; gap: 8px; align-items: baseline; }
.hb-msggroup__who .hb-muted { font-size: 12px; font-weight: 400; }
.hb-msg { position: relative; display: flex; align-items: center; gap: 4px; }
.hb-msggroup.is-mine .hb-msg { flex-direction: row-reverse; }
.hb-msg__text { margin: 0; padding: 8px 12px; border-radius: 16px; background: rgba(20, 38, 43, 0.09); white-space: pre-wrap; overflow-wrap: anywhere; font-size: 15px; line-height: 1.45; }
.hb-msggroup.is-mine .hb-msg__text { background: var(--color-accent, #5a7bf2); color: #fff; }
.hb-msg__remove { opacity: 0; border: 0; background: none; color: var(--color-muted, #a8bcb9); font-size: 16px; cursor: pointer; padding: 2px 6px; border-radius: 6px; transition: opacity 0.2s ease; }
.hb-msg:hover .hb-msg__remove, .hb-msg__remove:focus-visible { opacity: 1; }
.hb-avatar--small { width: 28px; height: 28px; font-size: 13px; margin-top: 20px; }
.hb-chat__composer { display: flex; gap: 8px; align-items: flex-end; padding: 10px; border-top: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface-2, #f1f5f4); }
.hb-chat__composer .hb-input { flex: 1; resize: none; max-height: 140px; border-radius: 18px; }
.hb-chat > .hb-note, .hb-chat > .hb-error { margin: 8px 12px; }

/* Knowledge cards */
.hb-cardlist { display: grid; gap: 8px; }
.hb-kcard { border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); overflow: hidden; }
.hb-kcard.is-open { border-color: rgba(127, 214, 180, 0.4); }
.hb-kcard__head { width: 100%; display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 16px 18px; border: 0; background: none; color: inherit; font: inherit; text-align: start; cursor: pointer; }
.hb-kcard__title { font-weight: 700; font-size: 16.5px; }
.hb-kcard__title::before { content: '💡 '; }
.hb-kcard__chev { width: 10px; height: 10px; border-right: 2px solid currentColor; border-bottom: 2px solid currentColor; transform: rotate(45deg); transition: transform 0.45s cubic-bezier(0.16, 1, 0.3, 1); opacity: 0.6; flex: 0 0 auto; }
.hb-kcard.is-open .hb-kcard__chev { transform: rotate(-135deg); }
.hb-kcard__body { display: grid; grid-template-rows: 0fr; transition: grid-template-rows 0.5s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-kcard__body > div { overflow: hidden; padding: 0 18px; }
.hb-kcard.is-open .hb-kcard__body { grid-template-rows: 1fr; }
.hb-kcard.is-open .hb-kcard__body > div { padding-bottom: 16px; }
.hb-kcard__body p { margin: 0 0 10px; white-space: pre-wrap; line-height: 1.6; }
.hb-kcard__meta { font-size: 13px; color: var(--color-muted, #a8bcb9); }

/* Materials */
.hb-materials { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.hb-material { display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 16px; background: var(--color-surface, #27434a); border: 1px solid var(--color-border, #dbe4e1); }
.hb-material.is-pinned { border-color: rgba(255, 213, 74, 0.35); }
.hb-material__link { flex: 1; min-width: 0; display: flex; align-items: center; gap: 12px; color: inherit; text-decoration: none; }
.hb-material__link:hover .hb-material__title { text-decoration: underline; text-underline-offset: 3px; }
.hb-material__icon { display: grid; place-items: center; width: 38px; height: 38px; border-radius: 12px; background: rgba(20, 38, 43, 0.08); flex: 0 0 auto; }
.hb-material__text { min-width: 0; display: grid; gap: 2px; }
.hb-material__title { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hb-material__text .hb-muted { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hb-row2--even { grid-template-columns: 1fr 1fr; }
@media (max-width: 620px) { .hb-row2--even { grid-template-columns: 1fr; } }

/* Hidden solutions */
.hb-folded { position: relative; margin-top: 10px; border-radius: 14px; overflow: hidden; min-height: 132px; }
.hb-folded__veil { filter: blur(9px); opacity: 0.5; user-select: none; pointer-events: none; min-height: 132px; max-height: 160px; overflow: hidden; }
.hb-folded__cover { position: absolute; inset: 0; display: grid; place-content: center; justify-items: center; gap: 6px; text-align: center; background: rgba(255, 255, 255, 0.72); }
.hb-folded__cover p { margin: 0; }
.hb-savecard { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.hb-savecard .hb-input { min-width: 220px; }

@media (prefers-reduced-motion: reduce) {
  .hb-livedot, .hb-msggroup { animation: none; }
  .hb-kcard__body, .hb-kcard__chev { transition: none; }
}

/* Many tabs: they scroll sideways, and fade at the edge instead of being cut. */
.hb-tabs { scrollbar-width: none; mask-image: linear-gradient(90deg, #000 calc(100% - 28px), transparent); -webkit-mask-image: linear-gradient(90deg, #000 calc(100% - 28px), transparent); }
.hb-tabs::-webkit-scrollbar { display: none; }
.hb-tabs::after { content: ''; flex: 0 0 24px; }

/* ================================================================ part 3 */

/* Late-night nudge */
.hb-nudge { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 14px; background: rgba(140, 160, 255, 0.1); border: 1px solid rgba(140, 160, 255, 0.25); font-size: 14px; animation: hb-in 0.5s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-nudge__text { flex: 1; min-width: 200px; color: #2c3f8f; }
.hb-nudge.is-done { margin: 0; color: #2c3f8f; }
.hb-chat__nudge { padding: 0 10px 10px; }
.hb-chat__nudge:empty { display: none; }

/* Calm mode */
.hb-calm { display: flex; align-items: center; gap: 8px; margin: 10px 0; padding: 10px 14px; border-radius: 14px; background: rgba(127, 214, 180, 0.1); border: 1px solid rgba(127, 214, 180, 0.28); color: #13734f; font-size: 14.5px; }
.hb-calm--inline { margin: 0; padding: 4px 10px; font-size: 13px; }
.hb-chat__bar { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--color-border, #dbe4e1); background: var(--color-surface-2, #f1f5f4); }

/* Badges and notifications */
.hb-badge--helper { background: rgba(255, 213, 74, 0.16); color: #7a5600; }
.hb-badge--helper::before { content: '★ '; }
.hb-space__action { display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 10px; }
.hb-notify { display: inline-flex; align-items: center; gap: 6px; }

/* Log */
.hb-log { list-style: none; margin: 10px 0 0; padding: 0; display: grid; gap: 2px; }
.hb-log li { display: flex; justify-content: space-between; gap: 16px; padding: 10px 12px; border-radius: 12px; background: var(--color-surface, #27434a); font-size: 14.5px; }
.hb-log li .hb-muted { flex: 0 0 auto; }

/* Waiting until morning */
.hb-waiting { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.hb-waiting li { display: flex; align-items: center; gap: 12px; padding: 10px 14px; border-radius: 14px; background: rgba(140, 160, 255, 0.08); }
.hb-waiting__text { flex: 1; min-width: 0; display: grid; gap: 2px; }
.hb-waiting__text > span:first-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Study partners */
.hb-partners .hb-fieldset { margin-bottom: 18px; }
.hb-profile-line { margin: 0 0 18px; }
.hb-slots { display: grid; grid-template-columns: 86px repeat(7, minmax(30px, 1fr)); gap: 6px; align-items: center; max-width: 520px; }
.hb-slots__head { text-align: center; font-size: 12.5px; color: var(--color-muted, #a8bcb9); }
.hb-slots__row { font-size: 13px; color: var(--color-muted, #a8bcb9); }
.hb-slot { height: 30px; border-radius: 9px; border: 1px solid var(--color-border, #dbe4e1); background: rgba(20, 38, 43, 0.04); cursor: pointer; transition: background-color 0.25s ease, border-color 0.25s ease, transform 0.3s cubic-bezier(0.16, 1, 0.3, 1); }
.hb-slot:hover { border-color: rgba(255, 213, 74, 0.5); }
.hb-slot.is-on { background: #ffd54a; border-color: #ffd54a; }
.hb-slot:active { transform: scale(0.94); }
.hb-avatar--big { width: 44px; height: 44px; font-size: 18px; }
.hb-avatar--partner { background: rgba(255, 213, 74, 0.25); }
.hb-reasons { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; font-size: 14px; }
.hb-reasons li { position: relative; padding-left: 22px; }
.hb-reasons li::before { content: '✓'; position: absolute; left: 2px; color: #7fd6b4; font-weight: 800; }
.hb-outgoing { margin-top: 18px; }

@media (prefers-reduced-motion: reduce) { .hb-nudge { animation: none; } .hb-slot { transition: none; } }
.hb-member__name .hb-muted { font-weight: 400; }
.hb-partners .hb-block + .hb-profile-line, .hb-partners .hb-block + .hb-fieldset { margin-top: 22px; }

/* ================================================================ light theme (Files update) */

.hb-place--new { color: #8a6100; }
.hb-tab.is-on { border-bottom-color: var(--color-accent, #2f63d6); }
.hb-segment { background: var(--color-surface-sunken, #eaf0ee); }
.hb-segment button.is-on { background: #fff; box-shadow: 0 1px 3px rgba(20, 38, 43, 0.12); }
.hb-option.is-on { border-color: var(--color-accent, #2f63d6); background: #f3f6ff; }
.hb-option input, .hb-check input { accent-color: var(--color-accent, #2f63d6); }
.hb-row, .hb-tile, .hb-card, .hb-post, .hb-member, .hb-kcard, .hb-material, .hb-roomitem, .hb-reportcard, .hb-log li { box-shadow: 0 1px 2px rgba(20, 38, 43, 0.04); }
.hb-input { background: #fff; }
.hb-badge--pin { background: #fff3c4; }
.hb-badge--helper { background: #fff3c4; color: #7a5600; }
.hb-note { background: #fff7db; color: #6b4c00; }
.hb-nudge { background: #eef1ff; border-color: #cfd8ff; }
.hb-calm { background: #e9f7f1; border-color: #bfe6d5; }
.hb-livebar { background: #fff0ee; border-color: #f6c7c1; }
.hb-dropin { border-color: #f2dc8f; }
.hb-folded__veil { opacity: 0.35; }
.hb-msg__text { background: var(--color-surface-2, #f1f5f4); }
.hb-msggroup.is-mine .hb-msg__text { background: var(--color-accent, #2f63d6); }
.hb-chat__day { background: var(--color-surface-2, #f1f5f4); }
.hb-error { color: #c93636; }

/* Materials: adding, picking, opening */
.hb-matadd { display: grid; gap: 12px; padding: 16px; margin-bottom: 16px; border-radius: 18px; background: #fff; border: 1px solid #dbe4e1; }
.hb-matadd .hb-segment { justify-self: start; }
.hb-matadd__form { display: grid; gap: 10px; animation: hb-in 0.35s cubic-bezier(0.16, 1, 0.3, 1) both; }
.hb-pick { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; max-height: 260px; overflow-y: auto; }
.hb-pick button { width: 100%; display: grid; grid-template-columns: 26px minmax(0, 1fr) auto; align-items: center; gap: 10px; padding: 8px 10px; border: 0; border-radius: 10px; background: transparent; color: inherit; font: inherit; font-size: 14.5px; text-align: left; cursor: pointer; }
.hb-pick button:hover, .hb-pick button:focus-visible { background: var(--color-surface-2, #f1f5f4); }
.hb-pick__name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 700; }
.hb-material__open { margin-left: auto; color: var(--color-muted, #5d6f73); font-size: 16px; }
.hb-material__icon--document { background: #eef3ff; }
.hb-material__icon--image { background: #ecf7f2; }
.hb-material__icon--video { background: #f3eefe; }
.hb-material__icon--audio { background: #fff3dc; }
.hb-material__link.is-missing { opacity: 0.7; cursor: default; }
.hb-material__icon--text { background: #ecf7f2; }
.hb-material__link:hover .hb-material__open { transform: translate(2px, -2px); }
.hb-material__open { transition: transform 0.3s cubic-bezier(0.16, 1, 0.3, 1); }
@media (prefers-reduced-motion: reduce) { .hb-material__open { transition: none; } }
__LOOK_EOF__
echo "wrote apps/web/src/components/Hub/hub.css"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/AppHeader.jsx <<'__LOOK_EOF__'
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, NavLink } from 'react-router-dom';
import { createUsernameApi, useCore } from '@classroom/core-client';
import { markSignOutIntent } from '../../lib/signOutIntent.js';
import UsernameDialog from './UsernameDialog.jsx';

/**
 * The app's top bar  (Design)
 *
 * Dashboard, Community, Messages and Media in the middle. Your picture (or
 * initial) on the right opens a menu with your name, Profile, Settings,
 * Privacy, the homepage and Sign out — Settings is where people look for it
 * in most apps, under their own picture, not as a fifth place to go. It also
 * shows your username and lets you choose or change it (you can sign in with
 * it instead of your email).
 *
 * The menu closes on a click outside, on Escape (focus returns to the
 * button), and after choosing; arrow keys move between items.
 */

const ICONS = {
  home: 'M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z',
  community: 'M8 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm8 0a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM2 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5M14.5 15c.5-.3 1-.5 1.5-.5 3.3 0 6 2.2 6 5.5',
  messages: 'M4 5h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9l-5 4V6a1 1 0 0 1 1-1z',
  media: 'M4 5h16v14H4zM4 15l5-5 4 4 3-3 4 4',
  user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 13a7.6 7.6 0 0 0 0-2l2-1.6-2-3.4-2.4 1a7.7 7.7 0 0 0-1.7-1L15 3h-4l-.4 2.6a7.7 7.7 0 0 0-1.7 1l-2.4-1-2 3.4 2 1.6a7.6 7.6 0 0 0 0 2l-2 1.6 2 3.4 2.4-1a7.7 7.7 0 0 0 1.7 1L11 21h4l.4-2.6a7.7 7.7 0 0 0 1.7-1l2.4 1 2-3.4z',
  shield: 'M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6z',
  globe: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z',
  out: 'M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 16l4-4-4-4M14 12H4',
  at: 'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.5 7.1',
  caret: 'M6 9l6 6 6-6',
};

const LINKS = [
  { to: '/', label: 'Dashboard', icon: 'home', end: true },
  { to: '/community', label: 'Community', icon: 'community' },
  { to: '/messages', label: 'Messages', icon: 'messages' },
  { to: '/media', label: 'Media', icon: 'media' },
];

function Icon({ name, className = 'app__icon' }) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      <path d={ICONS[name]} />
    </svg>
  );
}

function Avatar({ session }) {
  const name = session?.displayName ?? '';
  return (
    <span className="app__avatar" aria-hidden="true">
      {session?.avatarUrl ? <img src={session.avatarUrl} alt="" /> : name.trim().charAt(0).toUpperCase() || '·'}
    </span>
  );
}

function ProfileMenu({ session, onSignOut }) {
  const { http } = useCore();
  const usernames = useMemo(() => createUsernameApi(http), [http]);
  const [open, setOpen] = useState(false);
  const [username, setUsername] = useState(undefined);
  const [choosing, setChoosing] = useState(false);

  // Asked once, the first time the menu opens.
  useEffect(() => {
    if (!open || username !== undefined) return;
    usernames
      .mine()
      .then((result) => setUsername(result.username))
      .catch(() => setUsername(null));
  }, [open, username, usernames]);
  const wrapRef = useRef(null);
  const buttonRef = useRef(null);
  const menuRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const onPointer = (event) => {
      if (!wrapRef.current?.contains(event.target)) setOpen(false);
    };
    const onKey = (event) => {
      if (event.key === 'Escape') {
        setOpen(false);
        buttonRef.current?.focus();
      }
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        const items = [...(menuRef.current?.querySelectorAll('[role="menuitem"]') ?? [])];
        const index = items.indexOf(document.activeElement);
        const next = event.key === 'ArrowDown' ? (index + 1) % items.length : (index - 1 + items.length) % items.length;
        items[next]?.focus();
      }
    };
    document.addEventListener('pointerdown', onPointer);
    document.addEventListener('keydown', onKey);
    menuRef.current?.querySelector('[role="menuitem"]')?.focus();
    return () => {
      document.removeEventListener('pointerdown', onPointer);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const close = () => setOpen(false);
  const name = session?.displayName ?? '';

  return (
    <div className="app__me-wrap" ref={wrapRef}>
      <button
        ref={buttonRef}
        type="button"
        className="app__me"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Your account"
        onClick={() => setOpen((value) => !value)}
      >
        <Avatar session={session} />
        <span className="app__me-name">{name}</span>
        <Icon name="caret" className="app__caret" />
      </button>
      {open ? (
        <div className="app__menu" role="menu" ref={menuRef} aria-label="Your account">
          <div className="app__menu-head">
            <Avatar session={session} />
            <div>
              <strong>{name || 'You'}</strong>
              {username ? <span>@{username}</span> : null}
              {session?.email ? <span>{session.email}</span> : null}
            </div>
          </div>
          <Link role="menuitem" to="/settings/profile" onClick={close}>
            <Icon name="user" /> Profile
          </Link>
          <button
            type="button"
            role="menuitem"
            className="app__menu-item"
            onClick={() => {
              close();
              setChoosing(true);
            }}
          >
            <Icon name="at" /> {username ? 'Change username' : 'Choose a username'}
          </button>
          <Link role="menuitem" to="/settings" onClick={close}>
            <Icon name="settings" /> Settings
          </Link>
          <Link role="menuitem" to="/settings/privacy" onClick={close}>
            <Icon name="shield" /> Privacy
          </Link>
          <Link role="menuitem" to="/welcome" onClick={close}>
            <Icon name="globe" /> Homepage
          </Link>
          <hr />
          <button
            type="button"
            role="menuitem"
            className="app__menu-item app__menu-item--danger"
            onClick={() => {
              close();
              onSignOut();
            }}
          >
            <Icon name="out" /> Sign out
          </button>
        </div>
      ) : null}
      {choosing ? (
        <UsernameDialog
          current={username ?? null}
          onClose={() => setChoosing(false)}
          onSaved={(saved) => {
            setUsername(saved);
            setChoosing(false);
          }}
        />
      ) : null}
    </div>
  );
}

export default function AppHeader() {
  const { session, signOut } = useCore();

  // SessionWatch (AppLayout) takes it from here: on purpose → the homepage.
  const handleSignOut = () => {
    markSignOutIntent();
    signOut().catch(() => undefined);
  };

  return (
    <header className="app__bar">
      <Link to="/" className="app__brand" aria-label="Classroom, dashboard">
        <svg className="app__mark" viewBox="0 0 32 32" aria-hidden="true">
          <rect x="3" y="6" width="26" height="18" rx="4" />
          <path d="M11 29h10M16 24v5" />
          <circle cx="23" cy="11" r="2.4" />
        </svg>
        <span className="app__brand-text">Classroom</span>
      </Link>

      <nav className="app__nav" aria-label="Main">
        {LINKS.map((link) => (
          <NavLink key={link.to} to={link.to} end={link.end}>
            <Icon name={link.icon} />
            <span className="app__nav-label">{link.label}</span>
          </NavLink>
        ))}
      </nav>

      <ProfileMenu session={session} onSignOut={handleSignOut} />
    </header>
  );
}
__LOOK_EOF__
echo "wrote apps/web/src/components/system/AppHeader.jsx"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/UsernameDialog.jsx <<'__LOOK_EOF__'
import { useEffect, useMemo, useRef, useState } from 'react';
import { createUsernameApi, useCore } from '@classroom/core-client';
import { usernameProblem } from '../Auth/authModel.js';

/**
 * Choose or change your username  (Sign in with a username)
 *
 * Opened from the profile menu. Checks while typing whether the name is free;
 * once saved, the name works on the sign-in page instead of the email.
 */
export default function UsernameDialog({ current, onClose, onSaved }) {
  const { http } = useCore();
  const api = useMemo(() => createUsernameApi(http), [http]);
  const [value, setValue] = useState(current ?? '');
  const [check, setCheck] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const dialogRef = useRef(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    dialog?.showModal?.();
    return () => dialog?.close?.();
  }, []);

  const name = value.trim().toLowerCase();
  const local = name ? usernameProblem(name) : null;

  useEffect(() => {
    if (!name || local || name === current) {
      setCheck(null);
      return undefined;
    }
    setCheck('checking');
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      api
        .available(name, controller.signal)
        .then(setCheck)
        .catch(() => !controller.signal.aborted && setCheck(null));
    }, 300);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [api, name, local, current]);

  const save = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const result = await api.set(name || null);
      onSaved(result.username);
    } catch (cause) {
      setError(cause?.detail ?? 'Not saved.');
      setBusy(false);
    }
  };

  const blocked = Boolean(local) || check === 'checking' || (check && !check.available) || name === (current ?? '');

  return (
    <dialog ref={dialogRef} className="app-dialog" onCancel={onClose} aria-labelledby="app-username-title">
      <form onSubmit={save} className="app-dialog__body">
        <h2 id="app-username-title">{current ? 'Change your username' : 'Choose a username'}</h2>
        <p className="muted">Sign in with it instead of your email. Letters a–z, digits, dot, hyphen and underscore; 3 to 30 characters.</p>
        <label className="app-dialog__field">
          <span>Username</span>
          <input
            value={value}
            onChange={(event) => setValue(event.target.value)}
            maxLength={30}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            autoFocus
            placeholder="e.g. anna.b"
            aria-invalid={Boolean(local || (check && check !== 'checking' && !check.available))}
          />
        </label>
        <p className="app-dialog__hint" aria-live="polite">
          {!name
            ? current
              ? 'Leave it empty and save to remove your username.'
              : ' '
            : local ??
              (check === 'checking' ? 'Checking…' : check ? (check.available ? `✓ ${name} is free` : check.problem) : name === current ? 'This is your current username.' : ' ')}
        </p>
        {error ? <p className="app-dialog__error" role="alert">{error}</p> : null}
        <div className="app-dialog__actions">
          <button type="button" className="btn" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className="btn btn--primary" disabled={busy || (name ? blocked : !current)}>
            {busy ? 'Saving…' : name ? 'Save' : 'Remove username'}
          </button>
        </div>
      </form>
    </dialog>
  );
}
__LOOK_EOF__
echo "wrote apps/web/src/components/system/UsernameDialog.jsx"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/signOutIntent.js <<'__LOOK_EOF__'
/**
 * "I signed out on purpose"  (Design)
 *
 * SessionWatch (AppLayout) sends anyone who loses their session to the
 * sign-in page with a notice. Someone who chose "Sign out" in the profile menu
 * should land on the homepage instead. The menu marks the intent here just
 * before signing out; SessionWatch reads it once.
 */

let intendedAt = 0;

export const markSignOutIntent = () => {
  intendedAt = Date.now();
};

/** true once, within a few seconds of markSignOutIntent(). */
export const consumeSignOutIntent = () => {
  const recent = Date.now() - intendedAt < 5_000;
  intendedAt = 0;
  return recent;
};
__LOOK_EOF__
echo "wrote apps/web/src/lib/signOutIntent.js"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/LoginPage.jsx <<'__LOOK_EOF__'
import { useState } from 'react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import AuthShell from '../components/Auth/AuthShell.jsx';
import { destinationOf, withNext } from '../components/Auth/authModel.js';
import { passkeysSupported, signWithPasskey } from '../lib/webauthn.js';

/**
 * Sign in  (F5 · Settings Phase C · Landing)
 *
 * CoreProvider owns the session; this is one of the two screens that asks it
 * to start one (the other is sign-up). The access token never reaches this
 * component.
 *
 * The second step (Phase C) is unchanged: for an account with two-step
 * sign-in, signIn() throws SecondFactorRequired and this page asks for a code
 * from the authenticator app, a recovery code, or a passkey. "Sign in with a
 * passkey" skips the password entirely.
 *
 * Afterwards it returns to ?next=, to where the visitor was sent from, or to
 * the dashboard — only ever to a path inside the app.
 *
 * The first field takes an email address or a username; the server tells
 * them apart by the "@" (identity/Usernames.js).
 */
export default function LoginPage() {
  const { signIn, completeSignIn, passkeyOptions, signInWithPasskey, status } = useCore();
  const navigate = useNavigate();
  const location = useLocation();

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [reveal, setReveal] = useState(false);
  const [challenge, setChallenge] = useState(null);
  const [code, setCode] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  const destination = destinationOf({ search: location.search, state: location.state });
  const reason = location.state?.reason;

  if (status === 'authenticated') {
    return <Navigate to={destination} replace />;
  }

  const finish = () => navigate(destination, { replace: true });

  const run = async (action) => {
    setBusy(true);
    setError(null);
    try {
      await action();
    } finally {
      setBusy(false);
    }
  };

  const handlePassword = (event) => {
    event.preventDefault();
    run(async () => {
      try {
        await signIn({ email: email.trim(), password });
        finish();
      } catch (cause) {
        if (cause?.secondFactorRequired) {
          setChallenge({ id: cause.challengeId, methods: cause.methods });
          setUseRecovery(!cause.methods.includes('totp') && !cause.methods.includes('passkey'));
          setPassword('');
          return;
        }
        // The server deliberately does not say which half was wrong.
        setError(cause?.detail ?? 'The email, username or password is not right.');
      }
    });
  };

  const handleCode = (event) => {
    event.preventDefault();
    run(async () => {
      try {
        await completeSignIn({ challengeId: challenge.id, code });
        finish();
      } catch (cause) {
        setCode('');
        const detail = cause?.detail ?? 'That code is not right.';
        setError(detail);
        // Too many wrong codes or too slow: the password has to be entered again.
        if (/password again|took too long/i.test(detail)) setChallenge(null);
      }
    });
  };

  const handlePasskey = (challengeId = null) =>
    run(async () => {
      try {
        const { optionsId, options } = await passkeyOptions({ challengeId });
        const response = await signWithPasskey(options);
        await signInWithPasskey({ challengeId, optionsId, response });
        finish();
      } catch (cause) {
        setError(cause?.detail ?? cause?.message ?? 'The passkey was not accepted.');
      }
    });

  const canUsePasskeys = passkeysSupported();

  if (challenge) {
    const hasApp = challenge.methods.includes('totp');
    const hasRecovery = challenge.methods.includes('recovery');
    const hasPasskey = challenge.methods.includes('passkey') && canUsePasskeys;
    const recoveryMode = useRecovery || !hasApp;

    return (
      <AuthShell
        title="Two-step sign-in"
        lead={hasPasskey ? 'Confirm with the passkey on this device, or enter a code.' : 'Enter the code from your authenticator app.'}
        footer={
          <button type="button" className="au-textbutton" onClick={() => { setChallenge(null); setError(null); setCode(''); }}>
            Use a different account
          </button>
        }
      >
        <form className="au-form" onSubmit={handleCode}>
          {hasPasskey ? (
            <>
              <button type="button" className="au-button au-button--primary" disabled={busy} onClick={() => handlePasskey(challenge.id)}>
                Use a passkey
              </button>
              {hasApp || hasRecovery ? <p className="au-or">or</p> : null}
            </>
          ) : null}

          {hasApp || hasRecovery ? (
            <>
              <label className="au-field">
                <span className="au-label">{recoveryMode ? 'Recovery code' : 'Code from your authenticator app'}</span>
                <input
                  className="au-input au-input--code"
                  inputMode={recoveryMode ? 'text' : 'numeric'}
                  autoComplete="one-time-code"
                  placeholder={recoveryMode ? 'abcd-efgh' : '123456'}
                  value={code}
                  onChange={(event) => setCode(event.target.value)}
                  maxLength={20}
                  required
                  autoFocus={!hasPasskey}
                />
              </label>
              <button type="submit" className={hasPasskey ? 'au-button au-button--ghost' : 'au-button au-button--primary'} disabled={busy || code.trim().length < 6}>
                {busy ? 'Checking…' : 'Continue'}
              </button>
            </>
          ) : null}

          {error ? (
            <p className="au-alert au-alert--error" role="alert">
              {error}
            </p>
          ) : null}

          {hasApp && hasRecovery ? (
            <button type="button" className="au-textbutton" onClick={() => { setUseRecovery((v) => !v); setCode(''); }}>
              {useRecovery ? 'Use the authenticator app instead' : 'Lost your phone? Use a recovery code'}
            </button>
          ) : null}
        </form>
      </AuthShell>
    );
  }

  return (
    <AuthShell
      title="Welcome back"
      lead="Sign in to your lessons, rooms and messages."
      footer={
        <>
          <p>
            New here? <Link to={withNext('/signup', destination)}>Create an account</Link>
          </p>
          <p>
            <Link to="/">Back to the homepage</Link>
          </p>
        </>
      }
    >
      <form className="au-form" onSubmit={handlePassword}>
        {reason === 'signed-out-remotely' ? (
          <p className="au-alert au-alert--info" role="status">
            This device was signed out from another device.
          </p>
        ) : null}

        <label className="au-field">
          <span className="au-label">Email or username</span>
          <input
            className="au-input"
            type="text"
            inputMode="email"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            autoComplete="username webauthn"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            required
            autoFocus
          />
        </label>

        <label className="au-field">
          <span className="au-label">Password</span>
          <span className="au-input-wrap">
            <input
              className="au-input"
              type={reveal ? 'text' : 'password'}
              autoComplete="current-password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              required
            />
            <button type="button" className="au-reveal" onClick={() => setReveal((v) => !v)} aria-pressed={reveal}>
              {reveal ? 'Hide' : 'Show'}
            </button>
          </span>
        </label>

        {error ? (
          <p className="au-alert au-alert--error" role="alert">
            {error}
          </p>
        ) : null}

        <button type="submit" className="au-button au-button--primary" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>

        {canUsePasskeys ? (
          <>
            <p className="au-or">or</p>
            <button type="button" className="au-button au-button--ghost" disabled={busy} onClick={() => handlePasskey(null)}>
              Sign in with a passkey
            </button>
          </>
        ) : null}
      </form>
    </AuthShell>
  );
}
__LOOK_EOF__
echo "wrote apps/web/src/pages/LoginPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/MessagesPage.jsx <<'__LOOK_EOF__'
import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createChatApi, createProfileApi, useConversations, useCore } from '@classroom/core-client';
import ChatRooms from '../components/Chat/ChatRooms.jsx';
import '../components/Chat/chatRooms.css';
import '../components/Chat/messages.css';

/**
 * Messages  (F6 · Design)
 *
 * Your conversations with people — only the ones that are really yours: chats
 * someone wrote in, and the one you have open. A chat that was opened by
 * accident and never used does not clutter the list. "New message" finds a
 * person in your organisation (people who blocked you, or whom you blocked,
 * never appear) and opens the chat with them; whether you may write to them
 * follows their privacy settings, as everywhere.
 *
 * The everyone-chat ("General") is not here: it belongs to live rooms, where
 * it is shown during the session.
 *
 * The page has a fixed height and the conversation scrolls inside it, so the
 * back button and the ⋯ menu stay in view however long a chat gets.
 *
 * Wide screens show the list and the open conversation side by side, like a
 * messenger on the web; narrow screens show one at a time, with a back button.
 */

const WIDE = '(min-width: 960px)';

function useWide() {
  const [wide, setWide] = useState(() => typeof window !== 'undefined' && window.matchMedia?.(WIDE).matches);
  useEffect(() => {
    const query = window.matchMedia?.(WIDE);
    if (!query) return undefined;
    const onChange = () => setWide(query.matches);
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }, []);
  return Boolean(wide);
}

function NewMessage({ onOpen, onClose }) {
  const { http } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const [q, setQ] = useState('');
  const [results, setResults] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const inputRef = useRef(null);

  useEffect(() => {
    inputRef.current?.focus();
    const onKey = (event) => event.key === 'Escape' && onClose();
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);

  useEffect(() => {
    if (q.trim().length < 2) {
      setResults([]);
      return undefined;
    }
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      try {
        const { items } = await profiles.search({ q: q.trim(), limit: 8 }, controller.signal);
        setResults(items);
      } catch {
        if (!controller.signal.aborted) setResults([]);
      }
    }, 200);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [q, profiles]);

  const open = async (person) => {
    setBusy(true);
    setError(null);
    try {
      await onOpen(person);
    } catch (cause) {
      setError(cause?.detail ?? `You cannot write to ${person.displayName} right now.`);
      setBusy(false);
    }
  };

  return (
    <div className="msg-new" role="dialog" aria-label="New message">
      <div className="msg-new__head">
        <p className="msg-new__title">New message</p>
        <button type="button" className="msg-iconbtn" aria-label="Close" onClick={onClose}>
          ×
        </button>
      </div>
      <input
        ref={inputRef}
        className="msg-new__search"
        type="search"
        placeholder="Search for a person by name"
        value={q}
        onChange={(event) => setQ(event.target.value)}
        aria-label="Search for a person"
      />
      {q.trim().length >= 2 && results.length === 0 ? <p className="msg-new__hint">Nobody found.</p> : null}
      {q.trim().length < 2 ? <p className="msg-new__hint">Type at least two letters.</p> : null}
      <ul className="msg-new__results">
        {results.map((person) => (
          <li key={person.userId}>
            <button type="button" disabled={busy} onClick={() => open(person)}>
              <span className="msg-new__avatar" aria-hidden="true">
                {person.avatarUrl ? <img src={person.avatarUrl} alt="" /> : person.displayName.charAt(0).toUpperCase()}
              </span>
              <span>{person.displayName}</span>
            </button>
          </li>
        ))}
      </ul>
      {error ? <p className="msg-new__error" role="alert">{error}</p> : null}
    </div>
  );
}

export default function MessagesPage() {
  const { http, chatSocket, session } = useCore();
  const { conversationId } = useParams();
  const navigate = useNavigate();
  const [composing, setComposing] = useState(false);
  const wide = useWide();

  const api = useMemo(() => createChatApi(http), [http]);
  const self = useMemo(
    () => ({
      userId: session?.userId ?? '',
      displayName: session?.displayName ?? 'You',
      avatarUrl: session?.avatarUrl ?? null,
    }),
    [session],
  );

  const rooms = useConversations({
    api,
    socket: chatSocket ?? undefined,
    selfUserId: self.userId,
    enabled: Boolean(self.userId),
  });

  const [view, setView] = useState(conversationId ? { type: 'conversation', id: conversationId } : { type: 'list' });

  useEffect(() => {
    setView(conversationId ? { type: 'conversation', id: conversationId } : { type: 'list' });
  }, [conversationId]);

  const onViewChange = (next) => {
    // The everyone-chat lives in rooms, not here.
    if (next.type === 'lobby') return;
    setView(next);
    if (next.type === 'conversation') navigate(`/messages/${next.id}`);
    else if (conversationId) navigate('/messages');
  };

  const openWith = async (person) => {
    const conversation = await api.openDirect(person.userId);
    await rooms.refresh?.();
    setComposing(false);
    onViewChange({ type: 'conversation', id: conversation.conversationId });
  };

  // Unread from your conversations only — not from the everyone-chat.
  const unread = rooms.conversations.reduce((sum, item) => sum + (item.unreadCount || 0), 0);
  const inChat = view.type === 'conversation';
  const shared = { rooms, api, socket: chatSocket, self, showLobby: false, hideEmpty: true };

  return (
    <section className={`page messages-page${inChat ? ' is-chat' : ''}${wide ? ' is-wide' : ''}`}>
      <header className="messages-page__head">
        <h1>
          Messages {unread > 0 ? <span className="rooms-badge">{unread}</span> : null}
        </h1>
        {!inChat || wide ? (
          <button type="button" className="btn btn--primary" onClick={() => setComposing((value) => !value)} aria-expanded={composing}>
            New message
          </button>
        ) : null}
      </header>
      {composing && (!inChat || wide) ? <NewMessage onOpen={openWith} onClose={() => setComposing(false)} /> : null}
      {wide ? (
        <div className="messages-split">
          {/* The list first: of the two, the open chat must be the last to tell `rooms` what is open. */}
          <div className="messages-page__panel messages-split__list">
            <ChatRooms {...shared} view={{ type: 'list' }} onViewChange={onViewChange} activeId={inChat ? view.id : null} />
          </div>
          <div className="messages-page__panel messages-split__chat">
            {inChat ? (
              <ChatRooms {...shared} view={view} onViewChange={onViewChange} />
            ) : (
              <div className="messages-split__empty">
                <span aria-hidden="true">💬</span>
                <p className="messages-split__title">Choose a conversation</p>
                <p className="muted">Or start one with “New message”.</p>
              </div>
            )}
          </div>
        </div>
      ) : (
        <div className="messages-page__panel">
          <ChatRooms {...shared} view={view} onViewChange={onViewChange} />
        </div>
      )}
    </section>
  );
}
__LOOK_EOF__
echo "wrote apps/web/src/pages/MessagesPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/SignupPage.jsx <<'__LOOK_EOF__'
import { useEffect, useMemo, useState } from 'react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { createUsernameApi, useCore } from '@classroom/core-client';
import AuthShell from '../components/Auth/AuthShell.jsx';
import { STRENGTH_WORDS, destinationOf, passwordStrength, usernameProblem, validateSignup, withNext } from '../components/Auth/authModel.js';

/**
 * Create an account  (Landing)
 *
 * Three fields, and you are in: the account starts signed in (a verification
 * email is sent alongside), with your time zone and language taken from this
 * browser — both can be changed in Settings. After that it continues to
 * ?next= (for example the room editor from "Create this room" on the
 * homepage), or to the dashboard.
 *
 * A username is optional: with one, people can sign in with it instead of
 * their email. Whether it is free is checked while typing.
 */
export default function SignupPage() {
  const { signUp, status, http } = useCore();
  const usernames = useMemo(() => createUsernameApi(http), [http]);
  const navigate = useNavigate();
  const location = useLocation();

  const [form, setForm] = useState({ displayName: '', username: '', email: '', password: '' });
  const [nameCheck, setNameCheck] = useState(null); // null · checking · { available, problem }

  useEffect(() => {
    const name = form.username.trim();
    if (!name || usernameProblem(name)) {
      setNameCheck(null);
      return undefined;
    }
    setNameCheck('checking');
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      usernames
        .available(name, controller.signal)
        .then(setNameCheck)
        .catch(() => !controller.signal.aborted && setNameCheck(null));
    }, 350);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
  }, [form.username, usernames]);
  const [reveal, setReveal] = useState(false);
  const [touched, setTouched] = useState(false);
  const [error, setError] = useState(null);
  const [exists, setExists] = useState(false);
  const [busy, setBusy] = useState(false);

  const destination = destinationOf({ search: location.search, state: location.state });

  if (status === 'authenticated') {
    return <Navigate to={destination} replace />;
  }

  const errors = validateSignup(form);
  const shown = touched ? errors : {};
  const strength = passwordStrength(form.password);
  const set = (field) => (event) => setForm((current) => ({ ...current, [field]: event.target.value }));

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length > 0) return;
    if (nameCheck && nameCheck !== 'checking' && !nameCheck.available) return;
    setBusy(true);
    setError(null);
    setExists(false);
    try {
      await signUp({
        displayName: form.displayName.trim(),
        username: form.username.trim() || null,
        email: form.email.trim(),
        password: form.password,
      });
      navigate(destination, { replace: true });
    } catch (cause) {
      if (cause?.status === 409 || cause?.code === 'conflict') setExists(true);
      setError(cause?.detail ?? cause?.message ?? 'The account could not be created. Try again.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthShell
      title="Create your account"
      lead="Plan rooms, join lessons and meet your class. It takes a minute."
      footer={
        <>
          <p>
            Already have an account? <Link to={withNext('/login', destination)}>Sign in</Link>
          </p>
          <p>
            <Link to="/">Back to the homepage</Link>
          </p>
        </>
      }
    >
      <form className="au-form" onSubmit={submit} noValidate>
        <label className="au-field">
          <span className="au-label">Your name</span>
          <input
            className="au-input"
            autoComplete="name"
            value={form.displayName}
            onChange={set('displayName')}
            maxLength={80}
            aria-invalid={Boolean(shown.displayName)}
            autoFocus
          />
          {shown.displayName ? <span className="au-hint">{shown.displayName}</span> : <span className="au-hint">How others see you in lessons and chats.</span>}
        </label>

        <label className="au-field">
          <span className="au-label">
            Username <span className="au-optional">optional</span>
          </span>
          <input
            className="au-input"
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            maxLength={30}
            value={form.username}
            onChange={set('username')}
            aria-invalid={Boolean(shown.username || (nameCheck && nameCheck !== 'checking' && !nameCheck.available))}
            placeholder="e.g. anna.b"
          />
          <span className="au-hint" aria-live="polite">
            {shown.username ??
              (form.username.trim() && usernameProblem(form.username)) ??
              (nameCheck === 'checking'
                ? 'Checking…'
                : nameCheck
                  ? nameCheck.available
                    ? `✓ ${form.username.trim().toLowerCase()} is free`
                    : nameCheck.problem
                  : 'Sign in with it instead of your email.')}
          </span>
        </label>

        <label className="au-field">
          <span className="au-label">Email</span>
          <input
            className="au-input"
            type="email"
            autoComplete="email"
            value={form.email}
            onChange={set('email')}
            aria-invalid={Boolean(shown.email)}
          />
          {shown.email ? <span className="au-hint">{shown.email}</span> : null}
        </label>

        <label className="au-field">
          <span className="au-label">Password</span>
          <span className="au-input-wrap">
            <input
              className="au-input"
              type={reveal ? 'text' : 'password'}
              autoComplete="new-password"
              value={form.password}
              onChange={set('password')}
              aria-invalid={Boolean(shown.password)}
              aria-describedby="au-strength"
            />
            <button type="button" className="au-reveal" onClick={() => setReveal((v) => !v)} aria-pressed={reveal}>
              {reveal ? 'Hide' : 'Show'}
            </button>
          </span>
          <span className="au-meter" data-level={strength} aria-hidden="true">
            <i />
            <i />
            <i />
            <i />
          </span>
          <span className="au-hint" id="au-strength">
            {shown.password ?? (form.password ? STRENGTH_WORDS[strength] : 'At least 12 characters. A short sentence works well.')}
          </span>
        </label>

        {error ? (
          <p className="au-alert au-alert--error" role="alert">
            {error} {exists ? <Link to={withNext('/login', destination)}>Sign in instead</Link> : null}
          </p>
        ) : null}

        <button type="submit" className="au-button au-button--primary" disabled={busy}>
          {busy ? 'Creating your account…' : 'Create account'}
        </button>
      </form>
    </AuthShell>
  );
}
__LOOK_EOF__
echo "wrote apps/web/src/pages/SignupPage.jsx"

mkdir -p apps/web/src/styles
cat > apps/web/src/styles/theme.css <<'__LOOK_EOF__'
/* The app behind sign-in: the "daylight" theme  (Design)
 *
 * Light and calm, in the family of the homepage: a cool paper background,
 * white surfaces, slate text, one blue for actions and the highlighter yellow
 * for what is yours and what is current. The dark green of the earlier theme
 * is gone.
 *
 * Only presentation, and only inside .app (AppLayout). The classroom with its
 * video stays dark on purpose — video reads better on dark — and so do room
 * lobbies, sign-in and the homepage keep their own look.
 *
 * It works by setting the colour variables every stylesheet of the app
 * already reads (app.css, media.css, profile.css, billing.css, builder.css,
 * viewer.css, rooms.css, chat): no component changes, nothing about chat,
 * calls or data is touched.
 */

@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400&family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500..800&display=swap');

.app {
  --color-bg: #f3f6f5;
  --color-surface: #ffffff;
  --color-surface-2: #f1f5f4;
  --color-surface-raised: #ffffff;
  --color-surface-sunken: #eaf0ee;
  --color-border: #dbe4e1;
  --color-text: #15272c;
  --color-muted: #5d6f73;
  --color-text-muted: #5d6f73;
  --color-accent: #2f63d6;
  --color-danger: #c93636;
  --color-live: #1e9a77;
  --app-sun: #ffd54a;
  --app-sun-soft: #fff3c4;
  --app-sun-ink: #2a2206;
  --app-ease: cubic-bezier(0.16, 1, 0.3, 1);
  --app-radius: 16px;
  --app-shadow: 0 1px 2px rgba(20, 38, 43, 0.05), 0 10px 30px -18px rgba(20, 38, 43, 0.22);
  --font-sans: 'Atkinson Hyperlegible', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;

  position: relative;
  min-height: 100vh;
  color: var(--color-text);
  font-family: var(--font-sans);
  background:
    radial-gradient(1100px 600px at 95% -10%, rgba(47, 99, 214, 0.07), transparent 60%),
    radial-gradient(900px 500px at -10% 110%, rgba(255, 213, 74, 0.1), transparent 60%),
    var(--color-bg);
  background-attachment: fixed;
  color-scheme: light;
  -webkit-font-smoothing: antialiased;
}

.app ::selection { background: var(--app-sun); color: var(--app-sun-ink); }
.app :focus-visible { outline: 3px solid rgba(47, 99, 214, 0.45); outline-offset: 2px; border-radius: 8px; }

/* ------------------------------------------------------------ top bar */

.app .app__bar {
  position: sticky;
  top: 0;
  z-index: 40;
  display: flex;
  align-items: center;
  gap: 18px;
  padding: 10px max(20px, calc((100% - 1280px) / 2));
  border-bottom: 1px solid var(--color-border);
  background: rgba(255, 255, 255, 0.82);
  backdrop-filter: blur(16px) saturate(1.5);
  -webkit-backdrop-filter: blur(16px) saturate(1.5);
}
.app .app__brand { display: inline-flex; align-items: center; gap: 9px; color: var(--color-text); text-decoration: none; font: 780 19px/1 'Bricolage Grotesque', var(--font-sans); letter-spacing: -0.02em; }
.app .app__mark { width: 26px; height: 26px; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; }
.app .app__mark circle { fill: var(--app-sun); stroke: none; }

.app .app__nav { display: flex; gap: 4px; margin: 0 auto; padding: 4px; border-radius: 999px; background: var(--color-surface-2); font-size: 14.5px; }
.app .app__nav a {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 8px 14px; border-radius: 999px;
  color: var(--color-muted); text-decoration: none;
  transition: background-color 0.35s var(--app-ease), color 0.25s ease, box-shadow 0.35s var(--app-ease);
}
.app .app__nav a:hover { color: var(--color-text); background: rgba(20, 38, 43, 0.05); }
.app .app__nav a.active { color: var(--color-text); background: #fff; box-shadow: 0 1px 2px rgba(20, 38, 43, 0.08), 0 4px 12px -6px rgba(20, 38, 43, 0.25); font-weight: 700; }
.app .app__icon { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
.app .app__nav a.active .app__icon { stroke: var(--color-accent); }

/* The profile button and its menu */
.app .app__me-wrap { position: relative; }
.app .app__me { display: inline-flex; align-items: center; gap: 10px; padding: 4px 12px 4px 4px; border: 1px solid transparent; border-radius: 999px; background: transparent; color: var(--color-text); font: inherit; cursor: pointer; transition: background-color 0.3s var(--app-ease), border-color 0.3s var(--app-ease); }
.app .app__me:hover, .app .app__me[aria-expanded='true'] { background: var(--color-surface); border-color: var(--color-border); }
.app .app__avatar { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 50%; overflow: hidden; background: linear-gradient(135deg, #ffd54a, #f2a93b); color: var(--app-sun-ink); font-weight: 700; font-size: 14px; flex: 0 0 auto; }
.app .app__avatar img { width: 100%; height: 100%; object-fit: cover; }
.app .app__me-name { max-width: 14ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14.5px; }
.app .app__caret { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 2; opacity: 0.6; transition: transform 0.35s var(--app-ease); }
.app .app__me[aria-expanded='true'] .app__caret { transform: rotate(180deg); }

.app .app__menu {
  position: absolute; right: 0; top: calc(100% + 8px); z-index: 60; min-width: 250px;
  padding: 6px; border-radius: 16px; border: 1px solid var(--color-border);
  background: #fff; box-shadow: 0 2px 6px rgba(20, 38, 43, 0.06), 0 24px 48px -20px rgba(20, 38, 43, 0.35);
  transform-origin: top right; animation: app-menu 0.28s var(--app-ease) both;
}
@keyframes app-menu { from { opacity: 0; transform: translateY(-6px) scale(0.97); } to { opacity: 1; transform: none; } }
.app .app__menu-head { display: flex; align-items: center; gap: 10px; padding: 10px 10px 12px; border-bottom: 1px solid var(--color-border); margin-bottom: 6px; }
.app .app__menu-head strong { display: block; font-size: 15px; }
.app .app__menu-head div span { display: block; font-size: 13px; color: var(--color-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 170px; }
.app .app__menu a, .app .app__menu button.app__menu-item {
  display: flex; align-items: center; gap: 10px; width: 100%; padding: 9px 10px; border: 0; border-radius: 10px;
  background: none; color: var(--color-text); font: inherit; font-size: 14.5px; text-align: left; text-decoration: none; cursor: pointer;
}
.app .app__menu a:hover, .app .app__menu a:focus-visible, .app .app__menu button.app__menu-item:hover, .app .app__menu button.app__menu-item:focus-visible { background: var(--color-surface-2); outline: none; }
.app .app__menu .app__icon { width: 17px; height: 17px; color: var(--color-muted); }
.app .app__menu hr { border: 0; border-top: 1px solid var(--color-border); margin: 6px 4px; }
.app .app__menu .app__menu-item--danger { color: var(--color-danger); }
.app .app__menu .app__menu-item--danger .app__icon { color: var(--color-danger); }

@media (max-width: 980px) {
  .app .app__me-name, .app .app__caret { display: none; }
  .app .app__me { padding: 4px; }
}
@media (max-width: 760px) {
  .app .app__bar { gap: 10px; padding: 8px 12px; }
  .app .app__brand-text { display: none; }
  .app .app__nav { margin: 0; flex: 1; justify-content: space-between; }
  .app .app__nav-label { display: none; }
  .app .app__nav a { padding: 10px 12px; }
}

/* ------------------------------------------------------------ pages */

.app .app__content { max-width: 1280px; margin: 0 auto; padding: 28px 20px 64px; }
.app .page { animation: app-in 0.6s var(--app-ease) both; }
@keyframes app-in { from { opacity: 0; transform: translateY(14px); } to { opacity: 1; transform: none; } }

.app .app__content h1 { font-family: 'Bricolage Grotesque', var(--font-sans); font-weight: 780; letter-spacing: -0.025em; }
.app .app__content h2 { font-family: 'Bricolage Grotesque', var(--font-sans); letter-spacing: -0.015em; }

.app .card { border-radius: var(--app-radius); background: var(--color-surface); border: 1px solid var(--color-border); box-shadow: var(--app-shadow); }
.app .muted { color: var(--color-muted); }

/* Buttons: the same classes, light surfaces and a lift on hover. */
.app .btn {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  color: var(--color-text);
  transition: background-color 0.25s ease, border-color 0.25s ease, transform 0.3s var(--app-ease), box-shadow 0.3s var(--app-ease);
}
.app .btn:hover:not(:disabled) { background: var(--color-surface-2); border-color: #c8d4d0; }
.app .btn:active:not(:disabled) { transform: scale(0.98); }
.app a.btn { display: inline-flex; align-items: center; justify-content: center; text-decoration: none; color: inherit; }
.app .btn--primary, .app .btn--active { background: var(--color-accent); border-color: var(--color-accent); color: #fff; }
.app .btn--primary, .app a.btn--primary { color: #fff; box-shadow: 0 8px 20px -12px rgba(47, 99, 214, 0.9); }
.app .btn--primary:hover:not(:disabled) { background: #2553bd; border-color: #2553bd; transform: translateY(-1px); }
.app .btn--danger { background: var(--color-danger); border-color: var(--color-danger); color: #fff; }
.app .btn--danger:hover:not(:disabled) { background: #b02d2d; border-color: #b02d2d; }
.app .btn--off { background: #fff4d6; border-color: #f2d27a; color: #7a5600; }

/* Fields everywhere inside the app. */
.app input:not([type='checkbox']):not([type='radio']):not([type='range']),
.app textarea,
.app select {
  background: #fff;
  color: var(--color-text);
  border-color: var(--color-border);
}
.app input:not([type='checkbox']):not([type='radio']):not([type='range']):focus,
.app textarea:focus,
.app select:focus {
  outline: none;
  border-color: var(--color-accent);
  box-shadow: 0 0 0 3px rgba(47, 99, 214, 0.18);
}
.app ::placeholder { color: #8a9a9d; }

.app .banner { border-radius: 12px; }

/* Shared chat bubbles (lesson chat, Messages). */
.app .bubble { border-radius: 14px; background: var(--color-surface-2); color: var(--color-text); }
.app .bubble--mine { background: var(--color-accent); color: #fff; }
.app .thread__composer input { border-radius: 999px; }

.app * { scrollbar-width: thin; scrollbar-color: #c4d0cc transparent; }

@media (prefers-reduced-motion: reduce) {
  .app .page, .app .app__menu { animation: none; }
  .app .app__nav a, .app .btn, .app .app__me, .app .app__caret { transition: none; }
}

/* The last hard-coded dark colours in app.css, in daylight. */
.app .badge--joined { background: #dcf5e8; color: #13734f; }
.app .badge--reconnecting { background: #fff3c4; color: #7a5600; }
.app .badge--closed { background: #fde3e3; color: #a12a2a; }
.app .banner--warn { background: #fff3c4; color: #6b4c00; }
.app .bubble--failed { background: #fde3e3; color: var(--color-text); }

/* Dialogs opened from the top bar (choose a username). */
.app .app-dialog { border: 0; border-radius: 20px; padding: 0; width: min(440px, 92vw); color: var(--color-text); background: #fff; box-shadow: 0 30px 80px -30px rgba(20, 38, 43, 0.5); }
.app .app-dialog::backdrop { background: rgba(20, 38, 43, 0.35); backdrop-filter: blur(3px); }
.app .app-dialog[open] { animation: app-menu 0.3s var(--app-ease) both; }
.app .app-dialog__body { display: grid; gap: 12px; padding: 22px; }
.app .app-dialog__body h2 { margin: 0; font: 760 22px/1.2 'Bricolage Grotesque', var(--font-sans); }
.app .app-dialog__body p { margin: 0; }
.app .app-dialog__field { display: grid; gap: 6px; font-weight: 700; font-size: 14.5px; }
.app .app-dialog__field input { padding: 11px 14px; border-radius: 12px; border: 1px solid var(--color-border); font: inherit; font-weight: 400; font-size: 15.5px; }
.app .app-dialog__hint { min-height: 1.3em; font-size: 13.5px; color: var(--color-muted); }
.app .app-dialog__error { font-size: 14px; color: var(--color-danger); }
.app .app-dialog__actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 4px; }
.app .app__menu-head div span + span { margin-top: 1px; }
__LOOK_EOF__
echo "wrote apps/web/src/styles/theme.css"

cat > .look-patch.mjs <<'__LOOK_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Edits to files that stay otherwise untouched: staying signed in, the
 * profile menu's sign-out, signing in with a username, Messages side by side.
 * Every anchor must be found exactly once; otherwise nothing is written and
 * the installer stops.
 */

const plan = [
  {
    file: 'packages/core-client/src/CoreProvider.tsx',
    marker: 'renewViaCookie',
    edits: [
      {
        name: 'start by restoring the session',
        find:
          "  // Nothing persists across a reload, so there is no session to restore and no\n" +
          "  // reason to start in 'restoring' and make everyone wait for a call that\n" +
          "  // cannot succeed.\n" +
          "  const [status, setStatus] = useState<AuthStatus>('anonymous');\n",
        replace:
          "  // The refresh cookie (httpOnly, set by the server at sign-in and renewed with\n" +
          "  // every refresh) survives a reload: start in 'restoring' and ask once.\n" +
          "  const [status, setStatus] = useState<AuthStatus>('restoring');\n",
      },
      {
        name: 'one renewal through the cookie, serialised across tabs',
        find: '  const http = useMemo<HttpClient>(() => {\n',
        replace:
          '  /**\n' +
          '   * One renewal through the refresh cookie. A Web Lock serialises renewals\n' +
          '   * across tabs: the token rotates on every use, and two tabs presenting the\n' +
          '   * same one at once would look like theft and end the session everywhere.\n' +
          '   * Rejects when this browser has no valid session.\n' +
          '   */\n' +
          '  const renewViaCookie = async () => {\n' +
          '    const run = async () => {\n' +
          "      // A plain client: the main one would recurse, its 401 handling calls refresh().\n" +
          "      const bare = createHttpClient({ baseUrl: apiUrl, credentials: 'include' });\n" +
          "      return bare.post('/auth/refresh', {}, { anonymous: true, headers: await csrfHeaders(bare) });\n" +
          '    };\n' +
          '    const locks = (globalThis as { navigator?: { locks?: { request: (name: string, fn: () => Promise<unknown>) => Promise<unknown> } } })\n' +
          '      .navigator?.locks;\n' +
          "    return locks ? locks.request('classroom:session-refresh', run) : run();\n" +
          '  };\n' +
          '\n' +
          '  const http = useMemo<HttpClient>(() => {\n',
      },
      {
        name: 'refresh uses the cookie, not a token in memory',
        find:
          '        // No token in memory means there is nothing to refresh. Saying so here\n' +
          '        // is better than asking the server to tell us the same thing with a\n' +
          '        // 401 that then looks like a failure.\n' +
          '        if (!refreshTokenRef.current || !sessionIdRef.current) return null;\n' +
          '\n' +
          '        try {\n' +
          '          // A plain client, because using the outer one would recurse: its own\n' +
          '          // 401 handling would call this method again.\n' +
          "          const bare = createHttpClient({ baseUrl: apiUrl, credentials: 'include' });\n" +
          '\n' +
          '          const result = (await bare.post(\n' +
          "            '/auth/refresh',\n" +
          '            {\n' +
          '              refreshToken: refreshTokenRef.current,\n' +
          '              sessionId: sessionIdRef.current,\n' +
          '            },\n' +
          '            { anonymous: true, headers: await csrfHeaders(bare) },\n' +
          '          )) as TokenResponse;\n' +
          '\n' +
          '          accessTokenRef.current = result.accessToken;\n' +
          '          // Rotation: the old token is spent, and presenting it again would\n' +
          '          // look like theft.\n' +
          '          if (result.refreshToken) refreshTokenRef.current = result.refreshToken;\n' +
          '          if (result.sessionId) sessionIdRef.current = result.sessionId;\n',
        replace:
          '        // Through the httpOnly cookie only. The token used to be sent from\n' +
          '        // memory, but the route dropped its session id, so every renewal\n' +
          '        // failed and people were signed out when the first access token ran out.\n' +
          '        try {\n' +
          '          const result = (await renewViaCookie()) as TokenResponse;\n' +
          '          accessTokenRef.current = result.accessToken;\n' +
          '          refreshTokenRef.current = null;\n' +
          '          if (result.sessionId) sessionIdRef.current = result.sessionId;\n',
      },
      {
        name: 'resume the session on load',
        find: '    // eslint-disable-next-line react-hooks/exhaustive-deps\n  }, [apiUrl, release]);\n',
        replace:
          '    // eslint-disable-next-line react-hooks/exhaustive-deps\n  }, [apiUrl, release]);\n' +
          '\n' +
          '  // On load: resume the session from the refresh cookie, once. A failure only\n' +
          '  // means nobody is signed in on this browser.\n' +
          '  useEffect(() => {\n' +
          '    let cancelled = false;\n' +
          '    renewViaCookie()\n' +
          '      .then((result) => {\n' +
          '        if (cancelled) return;\n' +
          '        const tokens = result as TokenResponse;\n' +
          '        accessTokenRef.current = tokens.accessToken;\n' +
          '        if (tokens.sessionId) sessionIdRef.current = tokens.sessionId;\n' +
          '        setSession(tokens.user);\n' +
          "        setStatus('authenticated');\n" +
          '      })\n' +
          '      .catch(() => {\n' +
          "        if (!cancelled) setStatus((current) => (current === 'restoring' ? 'anonymous' : current));\n" +
          '      });\n' +
          '    return () => {\n' +
          '      cancelled = true;\n' +
          '    };\n' +
          '    // eslint-disable-next-line react-hooks/exhaustive-deps\n' +
          '  }, [apiUrl]);\n',
      },
      {
        name: 'sign out through the cookie, so the server really ends the session',
        find: '        { refreshToken: refreshTokenRef.current, sessionId: sessionIdRef.current },\n',
        replace: '        {},\n',
      },
      {
        name: 'signUp: optional username (type)',
        find: '  signUp(input: { displayName: string; email: string; password: string }): Promise<Session>;\n',
        replace: '  signUp(input: { displayName: string; email: string; password: string; username?: string | null }): Promise<Session>;\n',
      },
      {
        name: 'signUp: optional username (argument)',
        find: '    async ({ displayName, email, password }) => {\n',
        replace: '    async ({ displayName, email, password, username = null }) => {\n',
      },
      {
        name: 'signUp: optional username (sent)',
        find: '          displayName,\n          email,\n          password,\n          timeZone,\n',
        replace: '          displayName,\n          email,\n          password,\n          username: username || undefined,\n          timeZone,\n',
      },
    ],
  },
  {
    file: 'server/src/routes/auth.routes.js',
    marker: 'resolveLoginIdentifier',
    edits: [
      {
        name: 'refresh keeps the session id (mobile sends it beside the token)',
        find: "  validate({ body: z.object({ refreshToken: z.string().min(1).optional() }).default({}) }),\n",
        replace: "  validate({ body: z.object({ refreshToken: z.string().min(1).optional(), sessionId: z.string().uuid().optional() }).default({}) }),\n",
      },
      {
        name: 'sign in with email or username',
        find: '    body: z.object({\n      email: z.string().email(),\n      password: z.string().min(1).max(512),\n',
        replace: '    body: z.object({\n      // An email address, or a username (identity/Usernames.js resolves it).\n      email: z.string().trim().min(1).max(254),\n      password: z.string().min(1).max(512),\n',
      },
      {
        name: 'a username becomes its account\'s email before the usual sign-in',
        find: '    const tokens = await AuthService.login({\n      email: req.body.email,\n',
        replace: '    const tokens = await AuthService.login({\n      email: await resolveLoginIdentifier(req.body.email),\n',
      },
      {
        name: 'import the username lookup',
        find: "import * as AuthService from '../identity/AuthService.js';\n",
        replace: "import * as AuthService from '../identity/AuthService.js';\nimport { resolveLoginIdentifier } from '../identity/Usernames.js';\n",
      },
      {
        name: 'sign-up: optional username (input)',
        find: '      email: z.string().trim().email().max(254),\n',
        replace: '      email: z.string().trim().email().max(254),\n      username: z.string().trim().max(30).optional(),\n',
      },
      {
        name: 'sign-up: optional username (passed on)',
        find: '        displayName: req.body.displayName,\n        email: req.body.email,\n',
        replace: '        displayName: req.body.displayName,\n        email: req.body.email,\n        username: req.body.username || null,\n',
      },
    ],
  },
  {
    file: 'apps/web/src/pages/AppLayout.jsx',
    marker: 'consumeSignOutIntent',
    edits: [
      {
        name: 'know about deliberate sign-outs',
        find: "import AppHeader from '../components/system/AppHeader.jsx';\n",
        replace: "import AppHeader from '../components/system/AppHeader.jsx';\nimport { consumeSignOutIntent } from '../lib/signOutIntent.js';\n",
      },
      {
        name: '"Sign out" from the menu goes to the homepage',
        find:
          "    if (previous.current === 'authenticated' && SIGNED_OUT.has(status)) {\n" +
          "      navigate('/login', { replace: true, state: { reason: 'signed-out' } });\n" +
          '    }\n',
        replace:
          "    if (previous.current === 'authenticated' && SIGNED_OUT.has(status)) {\n" +
          "      if (consumeSignOutIntent()) navigate('/', { replace: true });\n" +
          "      else navigate('/login', { replace: true, state: { reason: 'signed-out' } });\n" +
          '    }\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/Chat/ChatRooms.jsx',
    marker: 'activeId',
    edits: [
      {
        name: 'split view: which conversation is open beside the list',
        find: 'roomId = null, sessionBlocks = null, showLobby = true, hideEmpty = false }) {\n',
        replace: 'roomId = null, sessionBlocks = null, showLobby = true, hideEmpty = false, activeId = null }) {\n',
      },
      {
        name: 'the open conversation stays listed even before the first message',
        find: '    ? rooms.conversations.filter((c) => c.lastMessageAt || c.unreadCount > 0 || c.conversationId === openId)\n',
        replace: '    ? rooms.conversations.filter((c) => c.lastMessageAt || c.unreadCount > 0 || c.conversationId === openId || c.conversationId === activeId)\n',
      },
      {
        name: 'mark the open conversation in the list',
        find: "              className={`rooms-row${conversation.unreadCount ? ' rooms-row--unread' : ''}`}\n",
        replace: "              className={`rooms-row${conversation.unreadCount ? ' rooms-row--unread' : ''}${conversation.conversationId === activeId ? ' rooms-row--active' : ''}`}\n              aria-current={conversation.conversationId === activeId ? 'true' : undefined}\n",
      },
    ],
  },
  {
    file: 'server/src/app.js',
    marker: 'usernameRoutes',
    edits: [
      {
        name: 'import the username routes',
        regex: /^import\s+scheduledRoomsRoutes\s+from\s+['"]([^'"]*)scheduledRooms\.routes\.js['"];?[ \t]*\r?\n/m,
        replace: (m, dir) => `${m}import usernameRoutes from '${dir}username.routes.js';\n`,
      },
      {
        name: 'mount them under /account/username',
        regex: /^([ \t]*)app\.use\(\s*['"]\/scheduled-rooms['"],\s*scheduledRoomsRoutes\s*\);[^\n]*\r?\n/m,
        replace: (m, indent) => `${m}${indent}app.use('/account/username', usernameRoutes); // Sign in with a username\n`,
      },
    ],
  },
  {
    file: 'packages/core-client/src/index.ts',
    marker: 'usernameApi',
    edits: [
      {
        name: 'export the username API',
        find: "export * from './api/hubApi.js';\n",
        replace: "export * from './api/hubApi.js';\nexport * from './api/usernameApi.js';\n",
      },
    ],
  },
];

const count = (src, edit) => {
  if (edit.regex) {
    const global = new RegExp(edit.regex.source, edit.regex.flags.includes('g') ? edit.regex.flags : `${edit.regex.flags}g`);
    return [...src.matchAll(global)].length;
  }
  return src.split(edit.find).length - 1;
};
const apply = (src, edit) => (edit.regex ? src.replace(edit.regex, edit.replace) : src.replace(edit.find, () => edit.replace));

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed in any patched file.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = count(src, edit);
    const expected = edit.count ?? 1;
    if (n !== expected) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor ${expected}×, found ${n}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = apply(src, edit);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__LOOK_EOF__
node .look-patch.mjs
rm -f .look-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.tsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.tsx=tsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo "A file did not pass its check (see above). Undo with: bash look-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs server/test/hub/*.check.mjs server/test/files/*.check.mjs server/test/identity/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs \
  apps/web/src/components/Landing/__checks__/*.check.mjs apps/web/src/components/Auth/__checks__/*.check.mjs \
  apps/web/src/components/Hub/__checks__/*.check.mjs apps/web/src/components/Files/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .look-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .look-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .look-test.log
else
  cat .look-test.log
  rm -f .look-test.log
  echo "The rule checks failed (see above). Undo with: bash look-install.sh --restore" >&2
  exit 1
fi

echo "--- database"
if SERVICE_ROLE=api npm run db:migrate; then
  touch server/src/server.js
  echo
  echo "Installed, migration 030 applied. The API restarts on its own."
  echo "Reload the browser tabs with Ctrl+Shift+R. If you were signed out before,"
  echo "sign in once more; from then on a reload keeps you signed in."
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh or npm run dev:infra), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  echo "(Until then the API refuses to start: it checks that the database matches the code.)"
  exit 1
fi