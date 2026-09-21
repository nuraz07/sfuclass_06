// sfuclass_06/check-imports.mjs  (v2)
//
// Finds every broken relative import in server/src in one run, instead of one
// crash per restart:
//
//   file not found        the imported file does not exist
//   name not exported     `import { x }`, `import X` (default), `export { x } from`
//                         or `const { x } = await import(...)` asks for a name
//                         the target does not export (export * is followed)
//
// For every missing name it prints what the target DOES export, which is
// usually enough to see the rename.
//
//   node check-imports.mjs              # checks server/src
//   node check-imports.mjs turn/agent   # any other folder
//
// Static analysis with regular expressions: comments are ignored, but exports
// built dynamically at runtime are invisible to it.
import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.argv[2] ?? 'server/src');
const IDENT = /^[A-Za-z_$][\w$]*$/;
const SPEC = String.raw`['"](\.{1,2}\/[^'"]+)['"]`;

// Blank out comments but keep every character offset, so line numbers stay right.
// `//` preceded by ':' or a quote is left alone (URLs inside strings).
const stripComments = (src) =>
  src
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/(^|[^:\\'"`])\/\/[^\n]*/g, (m, lead) => lead + ' '.repeat(m.length - lead.length));

/** "a, b as c" → imported side ['a','b'] or exported side ['a','c']. */
const splitNames = (list, side) =>
  list
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const [left, right] = part.split(/\s+as\s+/);
      return (side === 'imported' ? left : right ?? left).trim();
    })
    .filter((name) => IDENT.test(name));

/** "a, b: c, d = 1, ...rest" in a destructuring pattern → source keys ['a','b','d']. */
const destructuredKeys = (list) =>
  list
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part && !part.startsWith('...'))
    .map((part) => part.split(':')[0].split('=')[0].trim())
    .filter((name) => IDENT.test(name));

const exportCache = new Map();

async function exportsOf(file, seen = new Set()) {
  if (exportCache.has(file)) return exportCache.get(file);
  const names = new Set();
  if (seen.has(file)) return names;
  seen.add(file);

  let src;
  try {
    src = stripComments(await readFile(file, 'utf8'));
  } catch {
    return names;
  }

  const add = (name) => IDENT.test(name) && names.add(name);

  for (const m of src.matchAll(/\bexport\s+(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/g)) add(m[1]);
  for (const m of src.matchAll(/\bexport\s+class\s+([A-Za-z_$][\w$]*)/g)) add(m[1]);
  for (const m of src.matchAll(/\bexport\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) add(m[1]);
  for (const m of src.matchAll(/\bexport\s+(?:const|let|var)\s*\{([^}]*)\}\s*=/g)) {
    for (const part of m[1].split(',')) add((part.includes(':') ? part.split(':')[1] : part).split('=')[0].trim());
  }
  if (/\bexport\s+default\b/.test(src)) names.add('default');
  for (const m of src.matchAll(/\bexport\s*\{([^}]*)\}/g)) splitNames(m[1], 'exported').forEach(add);
  for (const m of src.matchAll(/\bexport\s*\*\s*as\s+([A-Za-z_$][\w$]*)\s+from/g)) add(m[1]);
  for (const m of src.matchAll(new RegExp(String.raw`\bexport\s*\*\s*from\s*${SPEC}`, 'g'))) {
    const target = path.resolve(path.dirname(file), m[1]);
    for (const name of await exportsOf(target, seen)) if (name !== 'default') names.add(name);
  }

  exportCache.set(file, names);
  return names;
}

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (/\.m?js$/.test(entry.name)) yield full;
  }
}

const problems = new Set();

for await (const file of walk(root)) {
  const src = stripComments(await readFile(file, 'utf8'));
  const dir = path.dirname(file);
  const where = (index) => `${path.relative(process.cwd(), file)}:${src.slice(0, index).split('\n').length}`;

  const check = async (spec, index, needed) => {
    const target = path.resolve(dir, spec);
    if (!existsSync(target)) {
      problems.add(`${where(index)}  -> ${spec}  file not found`);
      return;
    }
    if (needed.length === 0) return;
    const available = await exportsOf(target);
    for (const name of needed) {
      if (!available.has(name)) {
        const list = [...available].sort().join(', ') || '(nothing)';
        problems.add(`${where(index)}  -> ${spec}  '${name}' not exported  [exports: ${list}]`);
      }
    }
  };

  // import X, { a, b as c } from './x'   ·   import * as ns from './x'
  for (const m of src.matchAll(new RegExp(String.raw`\bimport\s+([^'";]+?)\s+from\s*${SPEC}`, 'g'))) {
    const clause = m[1];
    const needed = [];
    const braces = /\{([^}]*)\}/.exec(clause);
    if (braces) needed.push(...splitNames(braces[1], 'imported'));
    const head = clause.split(/[{*]/)[0].replace(/,\s*$/, '').trim();
    if (IDENT.test(head)) needed.push('default');
    await check(m[2], m.index, needed);
  }

  // export { a, b as c } from './x'
  for (const m of src.matchAll(new RegExp(String.raw`\bexport\s*\{([^}]*)\}\s*from\s*${SPEC}`, 'g'))) {
    await check(m[2], m.index, splitNames(m[1], 'imported'));
  }

  // export * from './x'   ·   export * as ns from './x'
  for (const m of src.matchAll(new RegExp(String.raw`\bexport\s*\*\s*(?:as\s+[\w$]+\s*)?from\s*${SPEC}`, 'g'))) {
    await check(m[1], m.index, []);
  }

  // const { a, b: c } = await import('./x')
  for (const m of src.matchAll(new RegExp(String.raw`\{([^{}]*)\}\s*=\s*await\s+import\(\s*${SPEC}\s*\)`, 'g'))) {
    await check(m[2], m.index, destructuredKeys(m[1]));
  }

  // await import('./x')   ·   import './x'
  for (const m of src.matchAll(new RegExp(String.raw`\bimport\(\s*${SPEC}\s*\)`, 'g'))) await check(m[1], m.index, []);
  for (const m of src.matchAll(new RegExp(String.raw`^\s*import\s*${SPEC}`, 'gm'))) await check(m[1], m.index, []);
}

for (const line of problems) console.log(line);
console.log(problems.size ? `\n${problems.size} problem(s)` : 'all relative imports and names resolve');
process.exitCode = problems.size ? 1 : 0;