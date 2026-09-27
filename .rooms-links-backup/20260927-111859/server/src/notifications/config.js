// classroom-app/server/src/notifications/config.js
/**
 * Delivery settings, read in one place  (Settings, Phase B)
 *
 * The API sends test notifications itself and the worker sends the rest, so
 * both need the mail and web-push settings. env.js hands some of them to the
 * worker role only, and the web-push keys are new; this reads each value from
 * the validated env first and falls back to the process environment (filled
 * from .env by `node --env-file`), then to a development default.
 *
 * For production, add WEB_PUSH_PUBLIC_KEY, WEB_PUSH_PRIVATE_KEY (secret) and
 * WEB_PUSH_SUBJECT to the api and worker roles in config/env.js.
 */

import { env } from '../config/env.js';

const read = (name, fallback = undefined) => {
  let value;
  try {
    value = env?.[name];
  } catch {
    value = undefined;
  }
  if (value === undefined || value === null || value === '') value = process.env[name];
  return value === undefined || value === null || value === '' ? fallback : value;
};

export const deliveryConfig = () => ({
  appUrl: String(read('APP_URL', 'http://localhost:5173')).replace(/\/$/, ''),
  mailTransport: read('MAIL_TRANSPORT', 'smtp'),
  smtpHost: read('SMTP_HOST', 'localhost'),
  smtpPort: Number(read('SMTP_PORT', 1025)),
  mailFrom: read('SES_FROM', 'noreply@classroom.local'),
  sesRegion: read('SES_REGION', read('AWS_REGION', 'eu-central-1')),
  webPushPublicKey: read('WEB_PUSH_PUBLIC_KEY', ''),
  webPushPrivateKey: read('WEB_PUSH_PRIVATE_KEY', ''),
  webPushSubject: read('WEB_PUSH_SUBJECT', 'mailto:admin@classroom.local'),
});

export default deliveryConfig;
