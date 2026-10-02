#!/usr/bin/env bash
# storage-install.sh — replaces the MinIO containers, which can no longer be
# pulled, with SeaweedFS, and fixes presigned uploads for current AWS SDKs.
#
# Run from the project folder (the one with docker-compose.dev.yml):
#   bash storage-install.sh
#
# What it does
#   1. backs up docker-compose.dev.yml and server/src/config/storage.config.js
#      to .storage-backup/<timestamp>/
#   2. docker-compose.dev.yml: service `minio` now runs SeaweedFS 4.48 (same
#      name, port 9000, credentials and buckets); `minio-init` only enables
#      versioning on the delivery bucket; new volume `objectdata`
#   3. storage.config.js: presigned PUT URLs without the empty-body checksum
#      that newer AWS SDKs add (otherwise every browser upload fails)
#   4. validates the compose file (docker compose config, offline)
#
# Nothing is started, stopped or pulled: starting the containers is a separate
# step (./dev-up.sh) and only happens when you run it.
#
# Undo: bash storage-install.sh --restore
set -euo pipefail

COMPOSE_FILE=docker-compose.dev.yml
STORAGE_CONFIG=server/src/config/storage.config.js
TOUCHED=("$COMPOSE_FILE" "$STORAGE_CONFIG")
TMP=.storage-install-tmp

if [ ! -f "$COMPOSE_FILE" ] || [ ! -f "$STORAGE_CONFIG" ]; then
  echo "Run this from the project folder (the one with $COMPOSE_FILE and server/)." >&2
  exit 1
fi
command -v node >/dev/null || { echo "node is required." >&2; exit 1; }

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .storage-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then cp "$FIRST/$f" "$f"; echo "restored $f"; fi
  done
  echo "Restored from $FIRST."
  echo "Note: the MinIO images it refers to can no longer be pulled anonymously."
  exit 0
fi

BACKUP=".storage-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$f" "$BACKUP/$f"
done
echo "backup: $BACKUP"

restore_and_exit() {
  for f in "${TOUCHED[@]}"; do cp "$BACKUP/$f" "$f"; done
  rm -rf "$TMP"
  echo "$1 Both files were put back as they were." >&2
  exit 1
}

rm -rf "$TMP" && mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/storage-block.yml" <<'__STORAGE_EOF__'
  # ---------------------------------------------------------------------------
  # Object storage — SeaweedFS stands in for S3 (raw · quarantine · delivery)
  #
  # MinIO no longer publishes images: Docker Hub removed them and Quay now
  # answers 401 to anonymous pulls. SeaweedFS is Apache-2.0, S3-compatible and
  # runs as one process (`weed mini`). The service keeps the name `minio`, port
  # 9000 and the MINIO_ROOT_* credentials, so S3_ENDPOINT, .env, the Vite /s3
  # proxy and every depends_on entry keep working unchanged.
  #
  #   raw · quarantine   private: signed requests only
  #   delivery           anonymous read (like `mc anonymous set download`)
  #   CORS               any origin, so presigned browser PUTs work in dev
  # ---------------------------------------------------------------------------
  minio:
    image: chrislusf/seaweedfs:4.48
    <<: *logging
    restart: unless-stopped
    environment:
      S3_ACCESS_KEY: ${MINIO_ROOT_USER:-classroom-dev}
      S3_SECRET_KEY: ${MINIO_ROOT_PASSWORD:-classroom-dev-secret}
    # Writes the S3 identities from the environment, then hands over to the
    # image's own entrypoint (fixes /data ownership, drops root, runs weed).
    entrypoint:
      - /bin/sh
      - -c
      - |
        set -eu
        umask 022
        cat > /etc/seaweedfs/s3.json <<JSON
        {
          "identities": [
            {
              "name": "classroom-dev",
              "credentials": [{ "accessKey": "$${S3_ACCESS_KEY}", "secretKey": "$${S3_SECRET_KEY}" }],
              "actions": ["Admin", "Read", "List", "Tagging", "Write"]
            },
            { "name": "anonymous", "actions": ["Read:classroom-dev-delivery"] }
          ]
        }
        JSON
        exec /entrypoint.sh mini \
          -ip.bind=0.0.0.0 \
          -s3.port=9000 \
          -s3.config=/etc/seaweedfs/s3.json \
          -s3.allowedOrigins='*' \
          -bucket=classroom-dev-raw,classroom-dev-quarantine,classroom-dev-delivery
    ports:
      - '9000:9000' # S3 API
      - '9001:8888' # file browser (SeaweedFS Filer UI)
    volumes:
      - objectdata:/data
    # Healthy only once all three buckets exist (they are created a moment
    # after the S3 port opens), checked with a signed request.
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          for b in classroom-dev-raw classroom-dev-quarantine classroom-dev-delivery;
          do curl -fsSI -o /dev/null --aws-sigv4 aws:amz:eu-central-1:s3
          --user "$$S3_ACCESS_KEY:$$S3_SECRET_KEY" "http://127.0.0.1:9000/$$b" || exit 1;
          done
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 10s
    networks: [classroom]

  # Same posture media.tf applies in AWS: versioning on the delivery bucket.
  # Runs once and exits; buckets, privacy and anonymous read are set above.
  minio-init:
    image: chrislusf/seaweedfs:4.48
    <<: *logging
    depends_on:
      minio: { condition: service_healthy }
    environment:
      S3_ACCESS_KEY: ${MINIO_ROOT_USER:-classroom-dev}
      S3_SECRET_KEY: ${MINIO_ROOT_PASSWORD:-classroom-dev-secret}
    entrypoint:
      - /bin/sh
      - -c
      - |
        set -eu
        curl -fsS -X PUT --aws-sigv4 aws:amz:eu-central-1:s3 \
          --user "$${S3_ACCESS_KEY}:$${S3_SECRET_KEY}" \
          -H 'Content-Type: application/xml' \
          --data '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>' \
          'http://minio:9000/classroom-dev-delivery?versioning'
        echo 'buckets ready'
    restart: 'no'
    networks: [classroom]
__STORAGE_EOF__

cat > "$TMP/patch.mjs" <<'__STORAGE_EOF__'
// Applies the storage fix to docker-compose.dev.yml and
// server/src/config/storage.config.js. Every anchor is checked before any file
// is written; a second run changes nothing.
import { readFileSync, writeFileSync } from 'node:fs';

const [composePath, storagePath, blockPath] = process.argv.slice(2);
const done = [];

// --- docker-compose.dev.yml ------------------------------------------------
let compose = readFileSync(composePath, 'utf8');
const eol = compose.includes('\r\n') ? '\r\n' : '\n';
let composeNext = null;

if (compose.includes('chrislusf/seaweedfs')) {
  console.log(`${composePath}: already uses SeaweedFS, nothing to do`);
} else {
  const lines = compose.split(/\r?\n/);
  const block = readFileSync(blockPath, 'utf8').replace(/\n+$/, '').split('\n');

  // A service block: from its key line to the next line indented 0 or 2,
  // without trailing blank lines, together with the comment lines right above it.
  const findService = (name) => {
    const key = lines.findIndex((line) => line.replace(/\s+$/, '') === `  ${name}:`);
    if (key === -1) return null;
    let end = key + 1;
    while (end < lines.length && !/^(\S| {2}\S)/.test(lines[end])) end += 1;
    while (end > key + 1 && lines[end - 1].trim() === '') end -= 1;
    let start = key;
    while (start > 0 && /^ {2}#/.test(lines[start - 1])) start -= 1;
    return { start, end };
  };

  const storage = findService('minio');
  if (!storage) {
    console.error(`${composePath}: no "minio:" service found. Nothing was changed.`);
    process.exit(2);
  }
  const init = findService('minio-init');

  const ranges = [{ ...storage, insert: block }];
  if (init) ranges.push({ ...init, insert: [] });
  ranges.sort((a, b) => b.start - a.start);
  for (const r of ranges) {
    // Removing minio-init also removes the blank line that separated it.
    const removeEnd = r.insert.length === 0 && lines[r.end]?.trim() === '' ? r.end + 1 : r.end;
    lines.splice(r.start, removeEnd - r.start, ...r.insert);
  }

  // New volume for SeaweedFS; miniodata stays declared so old data is kept.
  const volumes = lines.findIndex((line) => /^volumes:\s*$/.test(line));
  if (volumes === -1) {
    lines.push('', 'volumes:', '  objectdata:');
  } else if (!lines.some((line) => /^ {2}objectdata:\s*$/.test(line))) {
    const mini = lines.findIndex((line, i) => i > volumes && /^ {2}miniodata:\s*$/.test(line));
    lines.splice(mini === -1 ? volumes + 1 : mini + 1, 0, '  objectdata:');
  }

  composeNext = lines.join(eol);
  done.push(`${composePath}: minio → SeaweedFS 4.48, minio-init → versioning only, volume objectdata`);
}

// --- server/src/config/storage.config.js ----------------------------------
let storageNext = null;
const storageSrc = readFileSync(storagePath, 'utf8');
if (storageSrc.includes('requestChecksumCalculation')) {
  console.log(`${storagePath}: checksum setting already present, nothing to do`);
} else {
  const comment = [
    '// AWS SDK v3.729+ signs a CRC32 of the *empty* body into presigned PUT',
    '// URLs; the store then refuses the real upload (BadDigest). Checksums only',
    '// where an operation requires them — the same setting works on AWS S3.',
    "requestChecksumCalculation: 'WHEN_REQUIRED',",
    "responseChecksumValidation: 'WHEN_REQUIRED',",
  ];
  const after = (regex) => {
    const match = storageSrc.match(regex);
    if (!match) return null;
    const indent = match[1];
    const at = match.index + match[0].length;
    return storageSrc.slice(0, at) + comment.map((l) => `${indent}${l}`).join('\n') + '\n' + storageSrc.slice(at);
  };
  storageNext =
    after(/^([ \t]*)forcePathStyle:[^\n]*,[ \t]*\r?\n/m) ??
    after(/^export const s3ClientOptions = \{\r?\n(?=([ \t]+))/m);
  if (!storageNext) {
    console.error(`${storagePath}: s3ClientOptions not found. Nothing was changed.`);
    process.exit(3);
  }
  done.push(`${storagePath}: presigned uploads without the empty-body checksum`);
}

if (composeNext) writeFileSync(composePath, composeNext);
if (storageNext) writeFileSync(storagePath, storageNext);
for (const line of done) console.log('patched', line);
__STORAGE_EOF__


echo "--- files"
set +e
node "$TMP/patch.mjs" "$COMPOSE_FILE" "$STORAGE_CONFIG" "$TMP/storage-block.yml"
PATCH_EXIT=$?
set -e
if [ "$PATCH_EXIT" -ne 0 ]; then
  echo "Please send the output of: grep -n -A3 'minio\\|s3ClientOptions' $COMPOSE_FILE $STORAGE_CONFIG" >&2
  exit 1
fi
node --check "$STORAGE_CONFIG" || restore_and_exit "storage.config.js did not pass node --check."
echo "ok  $STORAGE_CONFIG"

if ! docker compose version >/dev/null 2>&1; then
  echo
  echo "Files are updated; docker compose is not available here, so the compose file was not validated."
  exit 0
fi
compose config -q || restore_and_exit "The new $COMPOSE_FILE did not validate."
echo "ok  $COMPOSE_FILE"

OTHERS=$(grep -rIlE 'quay\.io/minio|minio/minio:|minio/mc:' . \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.storage-backup \
  --exclude-dir='.*-backup' --exclude=storage-install.sh 2>/dev/null || true)
if [ -n "$OTHERS" ]; then
  echo
  echo "note: these files still name MinIO images (not changed by this script):"
  echo "$OTHERS" | sed 's/^/  /'
fi

echo
echo "Done. Only files were changed; no container was started or stopped."
echo "When you want the services running: ./dev-up.sh"