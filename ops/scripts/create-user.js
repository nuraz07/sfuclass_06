#!/usr/bin/env node
/**
 * ops/scripts/create-user.js
 *
 * Creates an account by calling AuthService.register directly.
 *
 * There is no HTTP registration route — auth.routes.js exposes login, refresh,
 * logout and devices, and nothing else. In production that is correct: accounts
 * arrive through an invitation or a tenant provisioning flow, not through an
 * open endpoint. But it leaves development with no way to get a first user, and
 * a database with no users is a product you cannot sign in to.
 *
 * It also does the two things register() leaves to the provisioning flow that
 * does not exist here: seeding a tenant, and joining the new account to the
 * tenant's public channel. Both are things a real signup would have done, and
 * both are invisible until something fails much later for a reason that has
 * nothing to do with the account.
 *
 * Usage:
 *   node --env-file=.env ops/scripts/create-user.js
 *   node --env-file=.env ops/scripts/create-user.js \
 *     --email=anna@classroom.local --name='Anna Schmidt' --role=learner
 *
 * Roles: learner (default), teacher, owner. A learner joins rooms; a teacher
 * gets the moderation controls. The *room* role is decided per join by
 * ModerationControls — this is the tenant role.
 *
 * Refuses to run against production. Convenience is precisely the property you
 * do not want anywhere near real accounts.
 */

import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    email: { type: 'string' },
    password: { type: 'string' },
    name: { type: 'string' },
    role: { type: 'string', default: 'learner' },
    locale: { type: 'string', default: 'en' },
    timezone: { type: 'string', default: 'Europe/Berlin' },
    tenant: { type: 'string', default: 'Development' },
  },
});

const { env } = await import('../../server/src/config/env.js');

if (env.NODE_ENV === 'production') {
  console.error('create-user.js will not run against production.');
  process.exit(1);
}

const ROLES = ['owner', 'teacher', 'learner'];
if (!ROLES.includes(values.role)) {
  console.error(`--role must be one of: ${ROLES.join(', ')}`);
  process.exit(1);
}

const email = values.email ?? 'teacher@classroom.local';
const password = values.password ?? 'dev-password-123';
const displayName = values.name ?? 'Demo Teacher';
const role = values.role;

const { pool } = await import('../../server/src/db/pool.js');
const { stateRedis: redis, closeRedis } = await import('../../server/src/db/redis.js');
const AuthService = await import('../../server/src/identity/AuthService.js');

/**
 * Idempotent: the slug is unique, so a second run returns the existing row
 * rather than failing or creating a duplicate.
 */
const ensureTenant = async () => {
  const { rows } = await pool.query(
    `INSERT INTO tenants (name, slug, status)
          VALUES ($1, $2, 'active')
     ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
       RETURNING id, name`,
    [values.tenant, 'development'],
  );
  return rows[0];
};

/**
 * A profile row and membership of the tenant lobby.
 *
 * PublicChatService.ensureLobby would normally do the second one when a tenant
 * is provisioned through the app. A tenant created by hand never ran it, and
 * the symptom — an empty channel list and a chat tab stuck on "Opening…" — is
 * nowhere near the cause.
 */
const ensureMemberships = async (userId) => {
  await pool.query(
    `INSERT INTO profiles (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING`,
    [userId],
  );

  const { rowCount } = await pool.query(
    `INSERT INTO channel_participants (channel_id, user_id)
     SELECT id, $1 FROM channels WHERE scope = 'public' AND archived_at IS NULL
     ON CONFLICT DO NOTHING`,
    [userId],
  );
  return rowCount;
};

try {
  const tenant = await ensureTenant();
  console.log(`\nTenant ready: ${tenant.name} (${tenant.id})`);

  const result = await AuthService.register({
    tenantId: tenant.id,
    email,
    password,
    displayName,
    role,
    locale: values.locale,
    timeZone: values.timezone,
    // register() starts a session immediately, and startSession wants a device.
    device: { platform: 'web', model: 'create-user.js' },
  });

  const userId = result.user?.userId ?? result.user?.id;
  const channels = await ensureMemberships(userId);

  console.log('\nAccount created.\n');
  console.log(`  email        ${email}`);
  console.log(`  password     ${password}`);
  console.log(`  displayName  ${displayName}`);
  console.log(`  role         ${role}`);
  console.log(`  userId       ${userId ?? '(unknown)'}`);
  console.log(`  channels     joined ${channels}`);
  console.log('\nSign in at http://localhost:5173/login\n');
} catch (cause) {
  // Only a genuine conflict is "nothing to do". Matching on the message text
  // was an earlier mistake here: "relation ... does not exist" contains the
  // word "exist", so a broken schema reported itself as a duplicate account
  // and the real failure stayed hidden for several rounds.
  if (cause?.code === 'conflict' || cause?.code === '23505') {
    console.log(`\nAn account for ${email} already exists.`);

    // Still worth doing: an account created before this script seeded
    // memberships has neither.
    const { rows } = await pool.query('SELECT id FROM users WHERE email = $1', [email]);
    if (rows[0]) {
      const channels = await ensureMemberships(rows[0].id);
      console.log(`Profile and channel membership checked — joined ${channels}.\n`);
    }
  } else {
    console.error('\nCould not create the account.\n');
    console.error(`  message  ${cause?.message ?? cause}`);
    if (cause?.code) console.error(`  code     ${cause.code}`);
    // Postgres attaches these, and together they usually name the exact column
    // or constraint that rejected the row.
    if (cause?.detail) console.error(`  detail   ${cause.detail}`);
    if (cause?.table) console.error(`  table    ${cause.table}`);
    if (cause?.column) console.error(`  column   ${cause.column}`);
    if (cause?.constraint) console.error(`  constraint ${cause.constraint}`);
    if (cause?.errors) console.error(`  policy   ${cause.errors.join('\n           ')}`);
    console.error('');
    if (cause?.stack) console.error(cause.stack);
    process.exitCode = 1;
  }
} finally {
  // The pools keep the event loop alive; without this the script hangs after
  // printing its result, which looks like a failure and is not.
  await pool.end().catch(() => {});
  closeRedis?.().catch(() => {});
}