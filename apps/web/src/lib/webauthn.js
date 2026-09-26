/**
 * Passkeys in the browser  (Settings, Phase C)
 *
 * The server speaks WebAuthn as JSON with base64url strings
 * (@simplewebauthn/server); the browser API wants ArrayBuffers and returns
 * them. This converts both ways, so no extra browser library is needed.
 *
 *   createPasskey(options)  navigator.credentials.create → registration JSON
 *   signWithPasskey(options) navigator.credentials.get    → authentication JSON
 */

export const passkeysSupported = () =>
  typeof window !== 'undefined' &&
  typeof window.PublicKeyCredential === 'function' &&
  typeof navigator.credentials?.create === 'function';

export const toBase64Url = (buffer) => {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

export const fromBase64Url = (text) => {
  const base64 = String(text).replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
};

const credentialDescriptors = (list) =>
  (list ?? []).map((entry) => ({ ...entry, type: 'public-key', id: fromBase64Url(entry.id) }));

/** Registration options (JSON) → what navigator.credentials.create takes. */
export const creationOptionsFromJSON = (json) => ({
  ...json,
  challenge: fromBase64Url(json.challenge),
  user: { ...json.user, id: fromBase64Url(json.user.id) },
  excludeCredentials: credentialDescriptors(json.excludeCredentials),
});

/** Authentication options (JSON) → what navigator.credentials.get takes. */
export const requestOptionsFromJSON = (json) => {
  const options = { ...json, challenge: fromBase64Url(json.challenge) };
  if (json.allowCredentials?.length) options.allowCredentials = credentialDescriptors(json.allowCredentials);
  else delete options.allowCredentials;
  return options;
};

const friendlyError = (cause) => {
  if (cause?.name === 'NotAllowedError') return new Error('The passkey prompt was closed or timed out.');
  if (cause?.name === 'InvalidStateError') return new Error('This device already has a passkey for your account.');
  if (cause?.name === 'SecurityError') return new Error('Passkeys cannot be used on this address.');
  return cause instanceof Error ? cause : new Error('The passkey did not work.');
};

export const createPasskey = async (optionsJSON) => {
  let credential;
  try {
    credential = await navigator.credentials.create({ publicKey: creationOptionsFromJSON(optionsJSON) });
  } catch (cause) {
    throw friendlyError(cause);
  }
  const { response } = credential;
  return {
    id: credential.id,
    rawId: toBase64Url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
    clientExtensionResults: credential.getClientExtensionResults?.() ?? {},
    response: {
      clientDataJSON: toBase64Url(response.clientDataJSON),
      attestationObject: toBase64Url(response.attestationObject),
      transports: response.getTransports?.() ?? [],
    },
  };
};

export const signWithPasskey = async (optionsJSON) => {
  let credential;
  try {
    credential = await navigator.credentials.get({ publicKey: requestOptionsFromJSON(optionsJSON) });
  } catch (cause) {
    throw friendlyError(cause);
  }
  const { response } = credential;
  return {
    id: credential.id,
    rawId: toBase64Url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
    clientExtensionResults: credential.getClientExtensionResults?.() ?? {},
    response: {
      clientDataJSON: toBase64Url(response.clientDataJSON),
      authenticatorData: toBase64Url(response.authenticatorData),
      signature: toBase64Url(response.signature),
      userHandle: response.userHandle ? toBase64Url(response.userHandle) : undefined,
    },
  };
};

/** A name for a new passkey from this browser, e.g. "Chrome on Windows". */
export const suggestedPasskeyName = (userAgent = globalThis.navigator?.userAgent ?? '') => {
  const browser =
    /Edg\//.test(userAgent) ? 'Edge'
      : /Firefox\//.test(userAgent) ? 'Firefox'
        : /Chrome\//.test(userAgent) ? 'Chrome'
          : /Safari\//.test(userAgent) ? 'Safari'
            : 'Browser';
  const system =
    /iPhone|iPad/.test(userAgent) ? 'iPhone or iPad'
      : /Android/.test(userAgent) ? 'Android'
        : /Windows/.test(userAgent) ? 'Windows'
          : /Mac OS X/.test(userAgent) ? 'Mac'
            : /Linux/.test(userAgent) ? 'Linux'
              : null;
  return system ? `${browser} on ${system}` : browser;
};
