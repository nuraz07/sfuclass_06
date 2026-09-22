import { readFileSync, writeFileSync } from 'node:fs';

const file = 'server/src/messaging/models/Channel.js';
let src = readFileSync(file, 'utf8');

if (src.includes('conflictTargetFor')) {
  console.log('already patched, nothing to do');
  process.exit(0);
}

const edits = [
  {
    name: 'the lobby lookup ignores archived lobbies',
    find: "    `SELECT ${SELECT} FROM channels ch WHERE ch.tenant_id = $1 AND ch.scope = 'public' LIMIT 1`,\n",
    replace:
      '    `SELECT ${SELECT} FROM channels ch\n' +
      "      WHERE ch.tenant_id = $1 AND ch.scope = 'public' AND ch.archived_at IS NULL\n" +
      '      ORDER BY ch.created_at LIMIT 1`,\n',
  },
  {
    name: 'one ON CONFLICT target per scope, matching its partial unique index',
    find:
      '/**\n' +
      ' * Idempotent by design: SpaceService and CourseService both call this on\n' +
      ' * publish, and a republish must not create a second channel.\n' +
      ' */\n',
    replace:
      `/**
 * The ON CONFLICT target for each scope. PostgreSQL only uses a partial unique
 * index for ON CONFLICT when the statement repeats the index's predicate, so
 * each target names its index's WHERE clause:
 *
 *   public          one active lobby per tenant   channels_public_lobby_key (019)
 *   space, course   one channel per target        channels_scope_ref_key (015)
 */
const conflictTargetFor = (scope) =>
  scope === 'public'
    ? \`ON CONFLICT (tenant_id) WHERE scope = 'public' AND archived_at IS NULL\`
    : \`ON CONFLICT (scope, scope_ref_id) WHERE scope_ref_id IS NOT NULL\`;

/**
 * Idempotent by design: SpaceService and CourseService both call this on
 * publish, and a republish must not create a second channel.
 */
`,
  },
  {
    name: 'ensureForScope uses that target; the lobby never carries a scope_ref_id',
    find:
      '     VALUES ($1, $2, $3, $4, $5, now(), now())\n' +
      '     ON CONFLICT (scope, scope_ref_id) DO UPDATE SET name = EXCLUDED.name, updated_at = now()\n' +
      '     RETURNING channel_id`,\n' +
      '    [channelId, tenantId, scope, scopeRefId, name],\n',
    replace:
      '     VALUES (COALESCE($1::uuid, gen_random_uuid()), $2, $3, $4, $5, now(), now())\n' +
      '     ${conflictTargetFor(scope)} DO UPDATE SET name = EXCLUDED.name, updated_at = now()\n' +
      '     RETURNING channel_id`,\n' +
      "    [channelId ?? null, tenantId, scope, scope === 'public' ? null : scopeRefId, name],\n",
  },
];

for (const edit of edits) {
  const count = src.split(edit.find).length - 1;
  if (count !== 1) {
    console.error(`"${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed.`);
    process.exit(1);
  }
}
for (const edit of edits) src = src.replace(edit.find, edit.replace);

writeFileSync(file, src);
console.log('patched', file);
for (const edit of edits) console.log('  -', edit.name);
