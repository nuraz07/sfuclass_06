import { readFileSync, writeFileSync } from 'node:fs';

const file = 'server/src/config/env.js';
let src = readFileSync(file, 'utf8');

if (src.includes('DEV_COMBINED_ROLES')) {
  console.log('already patched, nothing to do');
  process.exit(0);
}

const edits = [
  {
    name: 'declare the v6 SFU variables still read by the code',
    find: '  SFU_DRAIN_TIMEOUT_SEC: define(SFU, int(1_800, { min: 0 })),\n',
    replace:
      '  SFU_DRAIN_TIMEOUT_SEC: define(SFU, int(1_800, { min: 0 })),\n' +
      '\n' +
      '  // v6 names still read by the SFU path in this codebase (config/announcedIp.js,\n' +
      '  // config/mediasoup.config.js, classroom/RoomRegistry.js, mediasoup/index.js,\n' +
      '  // mediasoup/health.js). They belong to the v6 per-transport port model and are\n' +
      '  // removed together with it when the SFU moves to WebRtcServer (section 4.3).\n' +
      "  ANNOUNCED_IP: define(SFU, z.ipv4().default('127.0.0.1')),\n" +
      '  MEDIASOUP_MIN_PORT: define(SFU, int(40_000, { min: 1024, max: 65535 })),\n' +
      '  MEDIASOUP_MAX_PORT: define(SFU, int(40_100, { min: 1024, max: 65535 })),\n' +
      '  SFU_MAX_ROOMS_PER_NODE: define(SFU, int(40, { min: 1 })),\n' +
      '  SFU_HTTP_PORT: define(SFU, int(4_200, { min: 1, max: 65535 })),\n',
  },
  {
    name: 'combined development schema for the api process',
    find:
      'export const envSchemas = Object.freeze(\n' +
      '  Object.fromEntries(SERVICE_ROLES.map((role) => [role, envSchemaFor(role)])),\n' +
      ');\n',
    replace:
      'export const envSchemas = Object.freeze(\n' +
      '  Object.fromEntries(SERVICE_ROLES.map((role) => [role, envSchemaFor(role)])),\n' +
      ');\n' +
      '\n' +
      '/**\n' +
      ' * Development runs one process for three roles: server.js starts the\n' +
      ' * mediasoup workers and the socket gateways inside the api process. That\n' +
      ' * process therefore receives the realtime and SFU variables too; with only\n' +
      ' * the api schema they were dropped, and every setting of the other two roles\n' +
      ' * read as undefined (socket heartbeat, socket budget, node id, announced IP,\n' +
      ' * port range, room cap).\n' +
      ' *\n' +
      ' * Variables of the api role keep their exact schema. Those of the other two\n' +
      ' * are optional here, so a secret that only a separate SFU or realtime task\n' +
      ' * needs cannot stop a development boot; a value that is present is still\n' +
      ' * validated, and defaults still apply. Production is untouched: one role\n' +
      ' * per process, foreign variables rejected.\n' +
      ' */\n' +
      "const DEV_COMBINED_ROLES = Object.freeze(['api', 'realtime', 'sfu']);\n" +
      '\n' +
      'const devCombinedSchema = (() => {\n' +
      '  const shape = {};\n' +
      '  for (const [name, definition] of Object.entries(variables)) {\n' +
      "    if (definition.roles.includes('api')) {\n" +
      "      shape[name] = schemaOf(definition, 'api');\n" +
      '      continue;\n' +
      '    }\n' +
      '    const owner = DEV_COMBINED_ROLES.find((role) => definition.roles.includes(role));\n' +
      '    if (owner) shape[name] = schemaOf(definition, owner).optional();\n' +
      '  }\n' +
      "  return z.object(shape).superRefine((env, ctx) => checkRules(env, ctx, 'api'));\n" +
      '})();\n',
  },
  {
    name: 'use the combined schema for the api role outside production',
    find: '  const result = envSchemas[resolvedRole].safeParse(input);\n',
    replace:
      "  const combined = resolvedRole === 'api' && input.NODE_ENV !== 'production';\n" +
      '  const result = (combined ? devCombinedSchema : envSchemas[resolvedRole]).safeParse(input);\n',
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
