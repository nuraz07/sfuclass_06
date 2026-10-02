#!/usr/bin/env bash
# auth-retry-install.sh — stay signed in when the API is briefly away.
#
# Before: a reload while the API was restarting showed the sign-in page,
# although the session was still valid. Now:
#   - server unreachable / 5xx while resuming  → "Reconnecting to the server…",
#     retries by itself (1 s, 2 s, 4 s … every 30 s, at once when back online),
#     signs you in the moment the API answers; buttons: Try now · Go to sign-in
#   - server says the session is over (401)     → sign-in page, as before
#   - a stale CSRF token (403)                  → fresh token, one more try
#   - during use: an expired access token while the API is down fails that
#     one request instead of signing you out
#
# Run from the project folder:   bash auth-retry-install.sh
# Only files change; nothing is started or stopped. Vite reloads by itself.
# Undo: bash auth-retry-install.sh --restore
set -euo pipefail

NEW=(
  packages/core-client/src/auth/restorePolicy.ts
)
PATCHED=(
  packages/core-client/src/http/httpClient.ts
  packages/core-client/src/CoreProvider.tsx
  apps/web/src/components/system/AuthGate.jsx
)
TOUCHED=("${NEW[@]}" "${PATCHED[@]}")
for f in "${PATCHED[@]}"; do
  [ -f "$f" ] || { echo "$f is missing. Run this from the project folder." >&2; exit 1; }
done
command -v node >/dev/null || { echo "node is required." >&2; exit 1; }

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .auth-retry-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  rmdir packages/core-client/src/auth 2>/dev/null || true
  echo "Restored from $FIRST."
  exit 0
fi

BACKUP=".auth-retry-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

restore_and_exit() {
  for f in "${TOUCHED[@]}"; do
    if [ -f "$BACKUP/$f" ]; then cp "$BACKUP/$f" "$f"; elif [ -f "$f" ]; then rm "$f"; fi
  done
  rm -f .auth-retry-patch.mjs
  echo "$1 Every file was put back as it was." >&2
  exit 1
}

echo "--- updating"
cat > .auth-retry-patch.mjs <<'__AUTH_EOF__'
// Staying signed in through a brief API outage. Every anchor is checked in
// every file before anything is written; a second run changes nothing.
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'packages/core-client/src/http/httpClient.ts',
    marker: 'refresh did not get an answer',
    edits: [
      {
        name: 'a refresh that got no answer fails the request, it does not end the session',
        find: '    refreshInFlight ??= auth\n      .refresh()\n      .catch(() => null)\n',
        replace:
          '    refreshInFlight ??= auth\n' +
          '      .refresh()\n' +
          '      .catch((error) => {\n' +
          '        // The refresh did not get an answer (server restarting, network gone):\n' +
          '        // the request fails, the session stays. Only a "no" from the server\n' +
          '        // (refresh() resolving null) ends it.\n' +
          '        if (ApiError.is(error) && isRetryable(error.code)) throw error;\n' +
          '        return null;\n' +
          '      })\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/CoreProvider.tsx',
    marker: 'classifyRefreshFailure',
    edits: [
      {
        name: 'import the policy',
        find: "import { createNodeResolver, type NodeResolver } from './rtc/nodeResolver.js';\n",
        replace:
          "import { createNodeResolver, type NodeResolver } from './rtc/nodeResolver.js';\n" +
          "import { classifyRefreshFailure, restoreDelayMs } from './auth/restorePolicy.js';\n",
      },
      {
        name: 'context: the restore state',
        find: '  status: AuthStatus;\n  release: string;\n',
        replace:
          '  status: AuthStatus;\n' +
          '  /**\n' +
          '   * While status is "restoring": whether the server could not be reached\n' +
          '   * yet, and when the next try is. retryNow() tries at once; signInInstead()\n' +
          '   * gives up and shows the sign-in page.\n' +
          '   */\n' +
          '  restore: RestoreState;\n' +
          '  release: string;\n',
      },
      {
        name: 'the RestoreState type',
        find: 'const CoreContext = createContext<CoreContextValue | null>(null);\n',
        replace:
          'export interface RestoreState {\n' +
          '  reconnecting: boolean;\n' +
          '  attempt: number;\n' +
          '  nextRetryAt: number | null;\n' +
          '  retryNow(): void;\n' +
          '  signInInstead(): void;\n' +
          '}\n' +
          '\n' +
          'const CoreContext = createContext<CoreContextValue | null>(null);\n',
      },
      {
        name: 'refresh during a session: no answer is not a "no"',
        find:
          '          setSession(result.user);\n' +
          "          setStatus('authenticated');\n" +
          '          return result.accessToken;\n' +
          '        } catch {\n' +
          '          return null;\n' +
          '        }\n',
        replace:
          '          setSession(result.user);\n' +
          "          setStatus('authenticated');\n" +
          '          return result.accessToken;\n' +
          '        } catch (error) {\n' +
          '          const verdict = classifyRefreshFailure(error);\n' +
          "          if (verdict === 'csrf') csrfTokenRef.current = null;\n" +
          '          // No answer from the server: keep the session, let the request fail.\n' +
          "          if (verdict === 'transient') throw error;\n" +
          '          return null;\n' +
          '        }\n',
      },
      {
        name: 'on load: retry until the server answers',
        find:
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
        replace:
          '  // On load: resume the session from the refresh cookie. "No session" from\n' +
          '  // the server means nobody is signed in here. No answer at all (the API is\n' +
          '  // restarting, the network is gone) says nothing about the session: stay in\n' +
          "  // 'restoring', show that the server is being reached, and try again —\n" +
          '  // 1 s, 2 s, 4 s … every 30 s, at once when the browser comes back online.\n' +
          '  const [restoreInfo, setRestoreInfo] = useState({ reconnecting: false, attempt: 0, nextRetryAt: null as number | null });\n' +
          '  const restoreControl = useRef({ retryNow: () => {}, signInInstead: () => {} });\n' +
          '\n' +
          '  useEffect(() => {\n' +
          '    let cancelled = false;\n' +
          '    let timer: ReturnType<typeof setTimeout> | undefined;\n' +
          '    let attempt = 0;\n' +
          '    let csrfRetried = false;\n' +
          '\n' +
          '    const finish = (next: AuthStatus) => {\n' +
          '      clearTimeout(timer);\n' +
          '      setRestoreInfo({ reconnecting: false, attempt: 0, nextRetryAt: null });\n' +
          "      setStatus((current) => (current === 'restoring' ? next : current));\n" +
          '    };\n' +
          '\n' +
          '    const tryOnce = async (): Promise<void> => {\n' +
          '      clearTimeout(timer);\n' +
          '      attempt += 1;\n' +
          '      try {\n' +
          '        const tokens = (await renewViaCookie()) as TokenResponse;\n' +
          '        if (cancelled) return;\n' +
          '        accessTokenRef.current = tokens.accessToken;\n' +
          '        if (tokens.sessionId) sessionIdRef.current = tokens.sessionId;\n' +
          '        setSession(tokens.user);\n' +
          "        finish('authenticated');\n" +
          '      } catch (error) {\n' +
          '        if (cancelled) return;\n' +
          '        const verdict = classifyRefreshFailure(error);\n' +
          "        if (verdict === 'csrf' && !csrfRetried) {\n" +
          '          // A stale CSRF token (the API restarted): fetch a fresh one, once.\n' +
          '          csrfRetried = true;\n' +
          '          csrfTokenRef.current = null;\n' +
          '          return tryOnce();\n' +
          '        }\n' +
          "        if (verdict !== 'transient') return finish('anonymous');\n" +
          '        csrfTokenRef.current = null;\n' +
          '        const delay = restoreDelayMs(attempt);\n' +
          '        setRestoreInfo({ reconnecting: true, attempt, nextRetryAt: Date.now() + delay });\n' +
          '        timer = setTimeout(() => void tryOnce(), delay);\n' +
          '      }\n' +
          '    };\n' +
          '\n' +
          '    restoreControl.current = {\n' +
          '      retryNow: () => {\n' +
          '        if (!cancelled) void tryOnce();\n' +
          '      },\n' +
          "      signInInstead: () => finish('anonymous'),\n" +
          '    };\n' +
          '    const onOnline = () => restoreControl.current.retryNow();\n' +
          "    globalThis.addEventListener?.('online', onOnline);\n" +
          '\n' +
          '    void tryOnce();\n' +
          '    return () => {\n' +
          '      cancelled = true;\n' +
          '      clearTimeout(timer);\n' +
          "      globalThis.removeEventListener?.('online', onOnline);\n" +
          '    };\n' +
          '    // eslint-disable-next-line react-hooks/exhaustive-deps\n' +
          '  }, [apiUrl]);\n' +
          '\n' +
          '  const retryNow = useCallback(() => restoreControl.current.retryNow(), []);\n' +
          '  const signInInstead = useCallback(() => restoreControl.current.signInInstead(), []);\n' +
          '  const restore = useMemo<RestoreState>(\n' +
          '    () => ({ ...restoreInfo, retryNow, signInInstead }),\n' +
          '    [restoreInfo, retryNow, signInInstead],\n' +
          '  );\n',
      },
      {
        name: 'context value: restore',
        find: '      session,\n      status,\n      release,\n      apiUrl,\n      wsUrl,\n      getAccessToken,\n      signIn,\n      signUp,\n      completeSignIn,\n      passkeyOptions,\n      signInWithPasskey,\n      signOut,\n    }),\n    [\n      http,\n      nodeResolver,\n      chatSocket,\n      session,\n      status,\n',
        replace: '      session,\n      status,\n      restore,\n      release,\n      apiUrl,\n      wsUrl,\n      getAccessToken,\n      signIn,\n      signUp,\n      completeSignIn,\n      passkeyOptions,\n      signInWithPasskey,\n      signOut,\n    }),\n    [\n      http,\n      nodeResolver,\n      chatSocket,\n      session,\n      status,\n      restore,\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/system/AuthGate.jsx',
    marker: 'ReconnectNotice',
    edits: [
      {
        name: 'imports',
        find: "import { Suspense, lazy } from 'react';\n",
        replace: "import { Suspense, lazy, useEffect, useState } from 'react';\n",
      },
      {
        name: 'restoring: say so when the server is being reached',
        find: "  const { status } = useCore();\n  const location = useLocation();\n\n  if (status === 'authenticated') return <Outlet />;\n  if (status === 'restoring') return <p className=\"app app-empty\">Loading…</p>;\n",
        replace:
          "  const { status, restore } = useCore();\n" +
          '  const location = useLocation();\n' +
          '\n' +
          "  if (status === 'authenticated') return <Outlet />;\n" +
          "  if (status === 'restoring') return restore?.reconnecting ? <ReconnectNotice restore={restore} /> : <p className=\"app app-empty\">Loading…</p>;\n",
      },
      {
        name: 'the notice',
        find: '/**\n * The line between the homepage and the product  (Landing)\n',
        replace:
          '/**\n' +
          ' * The server did not answer while your session was being resumed (it may be\n' +
          ' * restarting). The session is kept; this retries by itself and signs you in\n' +
          ' * the moment the server is back.\n' +
          ' */\n' +
          'function ReconnectNotice({ restore }) {\n' +
          '  const [now, setNow] = useState(() => Date.now());\n' +
          '  useEffect(() => {\n' +
          '    const timer = window.setInterval(() => setNow(Date.now()), 1000);\n' +
          '    return () => window.clearInterval(timer);\n' +
          '  }, []);\n' +
          '  const seconds = restore.nextRetryAt ? Math.max(0, Math.ceil((restore.nextRetryAt - now) / 1000)) : 0;\n' +
          '  return (\n' +
          '    <div className="app app-empty" role="status" aria-live="polite" style={{ display: \'grid\', placeItems: \'center\', minHeight: \'60vh\', textAlign: \'center\', gap: 12, padding: 24 }}>\n' +
          '      <div style={{ display: \'grid\', gap: 10, maxWidth: 420 }}>\n' +
          '        <strong style={{ fontSize: 18 }}>Reconnecting to the server…</strong>\n' +
          '        <span>You are still signed in. As soon as the server answers, you are back where you were.</span>\n' +
          '        <span style={{ opacity: 0.7, fontSize: 14 }}>{seconds > 0 ? `Next try in ${seconds} s` : \'Trying now…\'}</span>\n' +
          '        <span style={{ display: \'flex\', gap: 10, justifyContent: \'center\', flexWrap: \'wrap\', marginTop: 4 }}>\n' +
          '          <button type="button" className="btn btn--primary" onClick={restore.retryNow}>\n' +
          '            Try now\n' +
          '          </button>\n' +
          '          <button type="button" className="btn" onClick={restore.signInInstead}>\n' +
          '            Go to sign-in\n' +
          '          </button>\n' +
          '        </span>\n' +
          '      </div>\n' +
          '    </div>\n' +
          '  );\n' +
          '}\n' +
          '\n' +
          '/**\n * The line between the homepage and the product  (Landing)\n',
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
    console.log(`${entry.file}: already updated, nothing to do`);
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
  console.log('updated', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__AUTH_EOF__
node .auth-retry-patch.mjs || { rm -f .auth-retry-patch.mjs; exit 1; }
rm -f .auth-retry-patch.mjs
mkdir -p packages/core-client/src/auth
cat > packages/core-client/src/auth/restorePolicy.ts <<'__AUTH_EOF__'
/**
 * Staying signed in when the server is briefly away  (Auth)
 *
 * Resuming a session (on load, or when an access token runs out) can fail for
 * two very different reasons:
 *
 *   the server said no     401 / revoked / reused — the session is over:
 *                          show the sign-in page
 *   the server did not     network error, timeout, 5xx (a restarting API, a
 *   answer properly        dev proxy with nothing behind it), 429 — nothing is
 *                          known about the session: keep it and try again
 *
 * A 403 on the refresh route is almost always a stale CSRF token (the API
 * restarted, the cookie rotated): fetch a fresh one and try once more.
 *
 * Pure: no React, no network.
 */

export type RestoreVerdict = 'signed-out' | 'csrf' | 'transient';

const TRANSIENT_CODES = new Set(['dependency_unavailable', 'rate_limited', 'internal_error', 'timeout', 'service_unavailable']);

/** What a failed refresh means. Anything that is not an answer from the API is transient. */
export const classifyRefreshFailure = (error: unknown): RestoreVerdict => {
  const code = (error as { code?: unknown } | null)?.code;
  if (typeof code !== 'string') return 'transient';
  if (code === 'forbidden') return 'csrf';
  if (TRANSIENT_CODES.has(code)) return 'transient';
  return 'signed-out';
};

/** 1 s, 2 s, 4 s, 8 s, 16 s, then every 30 s — with a little jitter so tabs do not line up. */
export const restoreDelayMs = (attempt: number, random: () => number = Math.random): number => {
  const base = Math.min(1_000 * 2 ** Math.max(0, attempt - 1), 30_000);
  return Math.round(base * (0.85 + random() * 0.3));
};

export default { classifyRefreshFailure, restoreDelayMs };
__AUTH_EOF__
echo "wrote packages/core-client/src/auth/restorePolicy.ts"

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  if [ -z "$ESBUILD" ]; then echo "--  $f (no esbuild to check)"; continue; fi
  case "$f" in
    *.tsx) LOADER="--loader:.tsx=tsx" ;;
    *.ts) LOADER="--loader:.ts=ts" ;;
    *.jsx) LOADER="--loader:.jsx=jsx" ;;
  esac
  if "$ESBUILD" "$f" $LOADER --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi
done
[ "$FAILED" -eq 0 ] || restore_and_exit "A file did not pass its check (see above)."

echo "--- rule tests (node --test)"
CHECKS=$(find server/test apps/web/src -name '*.check.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
if node --test $CHECKS > .auth-retry-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .auth-retry-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .auth-retry-test.log
else
  cat .auth-retry-test.log
  rm -f .auth-retry-test.log
  restore_and_exit "The rule tests failed (see above)."
fi

echo
echo "Done. Nothing was started; Vite reloads by itself. Reload the browser with Ctrl+Shift+R."