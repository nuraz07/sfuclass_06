import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const { env } = await import('./server/src/config/env.js');

const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (name === 'node_modules') continue;
    if (statSync(full).isDirectory()) walk(full);
    else if (/\.m?js$/.test(name)) files.push(full);
  }
};
walk('server/src');

const usedBy = new Map();
for (const file of files) {
  for (const [, key] of readFileSync(file, 'utf8').matchAll(/\benv\.([A-Z][A-Z0-9_]+)/g)) {
    if (!usedBy.has(key)) usedBy.set(key, new Set());
    usedBy.get(key).add(file.replace('server/src/', ''));
  }
}

const missing = [...usedBy.keys()].sort().filter((key) => env[key] === undefined);
for (const key of missing) {
  const inDotEnv = process.env[key] !== undefined ? `in .env = ${process.env[key]}` : 'NOT in .env';
  console.log(`${key.padEnd(34)} ${inDotEnv.padEnd(28)} used in: ${[...usedBy.get(key)].join(', ')}`);
}
console.log(`\n${missing.length} of ${usedBy.size} env settings are undefined in the api process`);
process.exit(0);
