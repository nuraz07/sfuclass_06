// classroom-app/server/src/config/publicUrlRules.js
/**
 * Pure rules behind config/publicUrl.js: which address a link should use.
 * No env.js import, so the checks can run without a configured environment
 * (server/test/rooms/publicUrl.check.mjs).
 */

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '0.0.0.0', '[::1]', '::1']);

export const originOf = (value) => {
  try {
    const url = new URL(String(value));
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.origin : null;
  } catch {
    return null;
  }
};

export const isLocalOrigin = (origin) => {
  try {
    return LOCAL_HOSTS.has(new URL(origin).hostname);
  } catch {
    return false;
  }
};

const portOf = (origin) => {
  const url = new URL(origin);
  return url.port || (url.protocol === 'https:' ? '443' : '80');
};

/**
 * The forwarded address of a local port in a hosted workspace, or null.
 * Pure: takes the environment as a parameter so it can be tested.
 */
export const hostedWorkspaceUrl = ({ environment, port }) => {
  if (environment.CODESPACE_NAME) {
    const domain = environment.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN || 'app.github.dev';
    return `https://${environment.CODESPACE_NAME}-${port}.${domain}`;
  }
  if (environment.GITPOD_WORKSPACE_URL) {
    const workspace = originOf(environment.GITPOD_WORKSPACE_URL);
    if (workspace) return `https://${port}-${new URL(workspace).host}`;
  }
  return null;
};

/** Pure version of publicAppUrl(). */
export const resolvePublicAppUrl = ({ environment = {}, appUrl = null } = {}) => {
  const explicit = originOf(environment.PUBLIC_APP_URL);
  if (explicit) return explicit;

  const configured = originOf(appUrl) ?? 'http://localhost:5173';
  if (isLocalOrigin(configured)) {
    const hosted = hostedWorkspaceUrl({ environment, port: portOf(configured) });
    if (hosted) return hosted;
  }
  return configured;
};

/** Pure: which address a link for this request should use. */
export const chooseLinkOrigin = ({ candidates, fallback, trusted }) => {
  for (const candidate of candidates) {
    const origin = originOf(candidate);
    if (!origin || !trusted(origin)) continue;
    // A local address works only on this machine; a shared link must not use it.
    if (isLocalOrigin(origin) && !isLocalOrigin(fallback)) continue;
    return origin;
  }
  return fallback;
};
