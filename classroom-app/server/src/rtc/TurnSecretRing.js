// server/src/rtc/TurnSecretRing.js
//
// Holds the TURN REST shared secret(s) used to sign temporary TURN credentials.
// The same secret is configured on every coturn node as static-auth-secret (turn/bootstrap/render-config.sh).
//
// Source of truth: AWS Secrets Manager secret TURN_SHARED_SECRET (infra/core/secrets.tf, replicated to
// media regions by infra/media-edge/secrets-replica.tf), rotated by infra/functions/turn-secret-rotation:
//
//   Phase 1 · Accept  new version staged as AWSPENDING; TURN nodes are refreshed (deploy-turn.yml,
//                     repository_dispatch turn-node-refresh) and accept {AWSCURRENT, AWSPENDING}.
//                     The API keeps signing with AWSCURRENT.
//   Phase 2 · Sign    the rotation Lambda promotes the new version to AWSCURRENT. Every API/realtime task
//                     picks it up within refreshIntervalMs (60 s) and signs with it. The old version is
//                     now AWSPREVIOUS and still accepted by the nodes.
//   Phase 3 · Retire  after the maximum credential TTL (24 h) nodes are refreshed again and accept only
//                     the new version.
//
// This ring therefore SIGNS with AWSCURRENT only and KNOWS AWSPREVIOUS for verification (tests, the
// audited debugging tool). It never signs with AWSPENDING: that would break nodes still in phase 1.
//
// Failure model: a failed refresh keeps the last good secrets for maxStaleMs (10 min). After that,
// signing fails closed with status 503 instead of issuing credentials from a secret that may be retired.
//
// Owner: F8 Real-Time Connectivity (+ security review, see CODEOWNERS). Used by TurnCredentialIssuer.js.

const MIN_SECRET_LENGTH = 32;

/**
 * @typedef {object} SecretVersion
 * @property {Buffer} value       Secret bytes exactly as coturn uses them (UTF-8 of the string).
 * @property {string} versionId   Secrets Manager version id (or "static-current"/"static-previous").
 * @property {'AWSCURRENT'|'AWSPREVIOUS'} stage
 */

/**
 * @typedef {object} TurnSecretRingOptions
 * @property {string} [secretId]  Secrets Manager id/ARN of TURN_SHARED_SECRET. Omit when staticSecrets is set.
 * @property {(req: { secretId: string, versionStage: string }) => Promise<{ secretString: string, versionId: string } | null>} [fetchSecret]
 *           Loader; defaults to the AWS SDK. Must resolve null when the stage does not exist.
 * @property {{ current: string, previous?: string }} [staticSecrets]  Local development only (docker-compose.dev.yml).
 * @property {number} [refreshIntervalMs=60000]
 * @property {number} [maxStaleMs=600000]
 * @property {{ info: Function, warn: Function, error: Function }} [logger]
 * @property {() => number} [now]
 */

export class TurnSecretRing {
  /** @param {TurnSecretRingOptions} options */
  constructor({
    secretId,
    fetchSecret,
    staticSecrets,
    refreshIntervalMs = 60_000,
    maxStaleMs = 600_000,
    logger = console,
    now = Date.now,
  } = {}) {
    if (!staticSecrets && !secretId) {
      throw new TypeError('TurnSecretRing: secretId is required unless staticSecrets is provided');
    }
    this.#secretId = secretId;
    this.#fetchSecret = fetchSecret ?? defaultFetchSecret;
    this.#static = staticSecrets ?? null;
    this.#refreshIntervalMs = refreshIntervalMs;
    this.#maxStaleMs = maxStaleMs;
    this.#logger = logger;
    this.#now = now;
  }

  #secretId;
  #fetchSecret;
  #static;
  #refreshIntervalMs;
  #maxStaleMs;
  #logger;
  #now;
  /** @type {SecretVersion | null} */ #current = null;
  /** @type {SecretVersion | null} */ #previous = null;
  #loadedAt = 0;
  #timer = null;

  /** Loads the secrets once (throws if that fails) and starts background refresh. */
  async start() {
    await this.refresh();
    if (!this.#static && !this.#timer) {
      this.#timer = setInterval(() => {
        this.refresh().catch((err) => {
          this.#logger.warn({ err: { message: err.message, code: err.code } }, 'turn secret refresh failed; keeping last good version');
        });
      }, this.#refreshIntervalMs);
      this.#timer.unref?.();
    }
    return this;
  }

  stop() {
    if (this.#timer) clearInterval(this.#timer);
    this.#timer = null;
  }

  async refresh() {
    if (this.#static) {
      this.#current = toVersion(this.#static.current, 'static-current', 'AWSCURRENT');
      this.#previous = this.#static.previous ? toVersion(this.#static.previous, 'static-previous', 'AWSPREVIOUS') : null;
      this.#loadedAt = this.#now();
      return;
    }
    const [current, previous] = await Promise.all([
      this.#fetchSecret({ secretId: this.#secretId, versionStage: 'AWSCURRENT' }),
      this.#fetchSecret({ secretId: this.#secretId, versionStage: 'AWSPREVIOUS' }),
    ]);
    if (!current) throw ringError('TURN secret has no AWSCURRENT version', 'RTC_SECRET_UNAVAILABLE');

    const nextCurrent = toVersion(current.secretString, current.versionId, 'AWSCURRENT');
    if (this.#current && this.#current.versionId !== nextCurrent.versionId) {
      this.#logger.info({ from: this.#current.versionId, to: nextCurrent.versionId }, 'turn secret signing version changed');
    }
    this.#current = nextCurrent;
    this.#previous = previous ? toVersion(previous.secretString, previous.versionId, 'AWSPREVIOUS') : null;
    this.#loadedAt = this.#now();
  }

  /** @returns {SecretVersion} the version used for signing (AWSCURRENT). */
  signingSecret() {
    this.#assertFresh();
    return this.#current;
  }

  /** @returns {SecretVersion[]} versions coturn accepts in steady state: current first, then previous. */
  acceptedSecrets() {
    this.#assertFresh();
    return this.#previous ? [this.#current, this.#previous] : [this.#current];
  }

  /** For /readyz: true while a usable signing secret is loaded. */
  isHealthy() {
    return Boolean(this.#current) && (this.#static || this.#now() - this.#loadedAt <= this.#maxStaleMs);
  }

  #assertFresh() {
    if (!this.#current) throw ringError('TURN secret ring not loaded', 'RTC_SECRET_UNAVAILABLE');
    if (!this.#static && this.#now() - this.#loadedAt > this.#maxStaleMs) {
      throw ringError('TURN secret is stale; refusing to sign', 'RTC_SECRET_STALE');
    }
  }
}

function toVersion(secretString, versionId, stage) {
  let value = secretString;
  if (typeof value === 'string' && value.trimStart().startsWith('{')) {
    try {
      const parsed = JSON.parse(value);
      value = parsed.secret ?? parsed.value;
    } catch {
      /* not JSON: use the raw string */
    }
  }
  if (typeof value !== 'string' || value.length < MIN_SECRET_LENGTH) {
    throw ringError(`TURN secret ${stage} is missing or shorter than ${MIN_SECRET_LENGTH} characters`, 'RTC_SECRET_INVALID');
  }
  // coturn uses static-auth-secret as a plain string key: the HMAC key is its UTF-8 bytes.
  return Object.freeze({ value: Buffer.from(value, 'utf8'), versionId: String(versionId), stage });
}

function ringError(message, code) {
  const err = new Error(message);
  err.code = code;
  err.status = 503;
  return err;
}

let secretsClientPromise;
async function defaultFetchSecret({ secretId, versionStage }) {
  secretsClientPromise ??= import('@aws-sdk/client-secrets-manager').then((sdk) => ({
    sdk,
    client: new sdk.SecretsManagerClient({}),
  }));
  const { sdk, client } = await secretsClientPromise;
  try {
    const out = await client.send(new sdk.GetSecretValueCommand({ SecretId: secretId, VersionStage: versionStage }));
    return { secretString: out.SecretString, versionId: out.VersionId };
  } catch (err) {
    if (err?.name === 'ResourceNotFoundException' && versionStage !== 'AWSCURRENT') return null;
    throw err;
  }
}