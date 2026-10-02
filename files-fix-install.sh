#!/usr/bin/env bash
# files-fix-install.sh — fixes uploads and opening files.
#
#   1. Upload refused by storage (403): the /s3 dev proxy in apps/web/vite.config.ts
#      now drops the X-Forwarded-* headers Codespaces adds; with them the storage
#      checked the signature against the Codespace's public address.
#   2. Opening a file answered 500: a file whose bytes are not in storage (for
#      example uploaded before the storage was replaced) now answers 404 with a
#      clear message and leaves the library and the quota; storage that does not
#      answer gives 503. Pictures that do not load show their icon in Media.
#
# Run from the project folder:   bash files-fix-install.sh
# Only files change. Nothing is started, stopped or pulled; a running API
# (node --watch) and Vite reload by themselves.
# Undo: bash files-fix-install.sh --restore
set -euo pipefail

TOUCHED=(
  apps/web/vite.config.ts
  server/src/files/FileService.js
  server/src/routes/files.routes.js
  apps/web/src/components/Library/LibraryItem.jsx
)
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || { echo "$f is missing. Run this from the project folder, after media-install.sh." >&2; exit 1; }
done
command -v node >/dev/null || { echo "node is required." >&2; exit 1; }

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .files-fix-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do cp "$FIRST/$f" "$f"; echo "restored $f"; done
  echo "Restored from $FIRST."
  exit 0
fi

BACKUP=".files-fix-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; done
echo "backup: $BACKUP"

restore_and_exit() {
  for f in "${TOUCHED[@]}"; do cp "$BACKUP/$f" "$f"; done
  rm -f .files-fix-patch.mjs
  echo "$1 Every file was put back as it was." >&2
  exit 1
}

echo "--- fixing"
cat > .files-fix-patch.mjs <<'__FIX_EOF__'
// Fixes for uploads in development and for files whose bytes are gone.
// Every anchor is checked in every file before anything is written; a second
// run changes nothing.
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'apps/web/vite.config.ts',
    marker: 'x-forwarded-host',
    edits: [
      {
        name: '/s3 proxy: drop the X-Forwarded-* headers Codespaces adds',
        find: "          rewrite: (path) => path.replace(/^\\/s3(?=\\/|$)/, '') || '/',\n",
        replace:
          "          rewrite: (path) => path.replace(/^\\/s3(?=\\/|$)/, '') || '/',\n" +
          '          // Codespaces (and any port forwarder) adds X-Forwarded-Host with the\n' +
          '          // public address. The storage would then check the signature against\n' +
          '          // that host instead of the one the API signed for (S3_ENDPOINT) and\n' +
          '          // answer 403. For storage this proxy is the client, so they go.\n' +
          '          configure: (proxy) => {\n' +
          "            proxy.on('proxyReq', (proxyReq) => {\n" +
          "              for (const header of ['x-forwarded-host', 'x-forwarded-port', 'x-forwarded-proto', 'x-forwarded-for', 'x-forwarded-prefix', 'forwarded']) {\n" +
          '                proxyReq.removeHeader(header);\n' +
          '              }\n' +
          '            });\n' +
          '          },\n',
      },
    ],
  },
  {
    file: 'server/src/files/FileService.js',
    marker: 'markMissing',
    edits: [
      {
        name: 'helpers: a missing object, a missing file',
        find: '/** For a signed link: the file\'s headers and a stream (or a range of it). */\n',
        replace:
          '/** The storage answered that the object is not there (as opposed to not answering). */\n' +
          'const isMissingObject = (cause) =>\n' +
          "  ['NoSuchKey', 'NotFound'].includes(cause?.name) || cause?.Code === 'NoSuchKey' || cause?.$metadata?.httpStatusCode === 404;\n" +
          '\n' +
          '/**\n' +
          ' * A file whose bytes are gone from storage (for example after the storage\n' +
          ' * was replaced) leaves the library and stops counting against the quota.\n' +
          ' * The row stays, with the reason; materials pointing at it show it as gone.\n' +
          ' */\n' +
          'const markMissing = async (row) => {\n' +
          '  await pool.query(\n' +
          "    `UPDATE files SET status = 'rejected', reject_reason = 'The stored file is missing.', updated_at = now()\n" +
          "      WHERE id = $1 AND status = 'ready'`,\n" +
          '    [row.id],\n' +
          '  );\n' +
          "  log.warn({ fileId: row.id, bucket: row.bucket, key: row.object_key }, 'stored object missing; file marked unavailable');\n" +
          '};\n' +
          '\n' +
          '/** For a signed link: the file\'s headers and a stream (or a range of it). */\n',
      },
      {
        name: 'open: missing object → 404, storage down → 503',
        find:
          '  const body = await Store.stream({ bucket: row.bucket, key: row.object_key, range });\n' +
          '  return { status: range ? 206 : 200, headers, body };\n',
        replace:
          '  let body;\n' +
          '  try {\n' +
          '    body = await Store.stream({ bucket: row.bucket, key: row.object_key, range });\n' +
          '  } catch (cause) {\n' +
          '    if (isMissingObject(cause)) {\n' +
          '      await markMissing(row);\n' +
          "      fail('not_found', 'This file is no longer in storage. Upload it again.');\n" +
          '    }\n' +
          "    log.error({ err: cause, fileId: row.id }, 'storage unavailable while opening a file');\n" +
          "    fail('unavailable', 'The file storage is not reachable right now. Try again in a moment.');\n" +
          '  }\n' +
          '  return { status: range ? 206 : 200, headers, body };\n',
      },
    ],
  },
  {
    file: 'server/src/routes/files.routes.js',
    marker: 'unavailable: 503',
    edits: [
      {
        name: 'content: 403 · 404 · 503 as plain text, never a 500',
        find:
          "    if (error?.code === 'forbidden' || error?.code === 'not_found') {\n" +
          "      res.status(error.code === 'forbidden' ? 403 : 404).type('text/plain; charset=utf-8').send(error.message);\n" +
          '      return undefined;\n' +
          '    }\n',
        replace:
          "    const status = { forbidden: 403, not_found: 404, unavailable: 503 }[error?.code];\n" +
          '    if (status) {\n' +
          "      res.status(status).type('text/plain; charset=utf-8').send(error.message);\n" +
          '      return undefined;\n' +
          '    }\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/Library/LibraryItem.jsx',
    marker: 'thumbFailed',
    edits: [
      {
        name: 'import useState',
        find: "import { fileMeta, iconFor } from '../Files/filesModel.js';\n",
        replace: "import { useState } from 'react';\nimport { fileMeta, iconFor } from '../Files/filesModel.js';\n",
      },
      {
        name: 'a picture that does not load shows its icon',
        find: "  const thumb = file.kind === 'image' && file.openUrl ? fileHref(file.openUrl) : null;\n",
        replace:
          '  const [thumbFailed, setThumbFailed] = useState(false);\n' +
          "  const thumb = file.kind === 'image' && file.openUrl && !thumbFailed ? fileHref(file.openUrl) : null;\n",
      },
      {
        name: 'onError on the thumbnail',
        find: '<img src={thumb} alt="" loading="lazy" decoding="async" draggable="false" />',
        replace: '<img src={thumb} alt="" loading="lazy" decoding="async" draggable="false" onError={() => setThumbFailed(true)} />',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  let src;
  try {
    src = readFileSync(entry.file, 'utf8');
  } catch {
    console.error(`${entry.file}: not found. Nothing was changed in any file.`);
    process.exit(1);
  }
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already fixed, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const count = src.split(edit.find).length - 1;
    if (count !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed in any file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.replace(edit.find, () => edit.replace);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('fixed', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__FIX_EOF__
node .files-fix-patch.mjs || { rm -f .files-fix-patch.mjs; exit 1; }
rm -f .files-fix-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  case "$f" in
    *.js) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
  esac
done
[ "$FAILED" -eq 0 ] || restore_and_exit "A file did not pass its check (see above)."

echo "--- rule tests (node --test)"
CHECKS=$(find server/test apps/web/src -name '*.check.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
if node --test $CHECKS > .files-fix-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .files-fix-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .files-fix-test.log
else
  cat .files-fix-test.log
  rm -f .files-fix-test.log
  restore_and_exit "The rule tests failed (see above)."
fi

echo
echo "Fixed. Nothing was started. Vite restarts by itself because its config changed,"
echo "the API reloads by itself. Reload the browser with Ctrl+Shift+R and upload again."