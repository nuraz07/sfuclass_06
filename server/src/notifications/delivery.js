// classroom-app/server/src/notifications/delivery.js
/**
 * Delivery channels  (Settings, Phase B)
 *
 * How a notification physically leaves the platform, once the rules
 * (settings/notifications.js) have decided that it should:
 *
 *   push    Web Push to every browser the person allowed it in (VAPID keys
 *           WEB_PUSH_*), only while the sign-in session that registered the
 *           browser is still active
 *   email   SMTP (Mailpit in development) or SES, by MAIL_TRANSPORT
 *
 * Used by the notification worker for real notifications and by the API for
 * "Send test notification", so a successful test proves the same path.
 *
 * Push never throws: one dead browser must not stop delivery to the others,
 * and a retried job would notify everyone twice. Email throws, so a caller can
 * decide whether a retry is worth it.
 */

import { deliveryConfig } from './config.js';
import { logger } from '../observability/logger.js';
import * as Subscriptions from './webPushSubscriptions.js';

const log = logger.child({ component: 'delivery' });

const truncate = (text, max) => {
  const value = String(text ?? '');
  if (value.length <= max) return value;
  const cut = value.slice(0, max - 1);
  const space = cut.lastIndexOf(' ');
  return `${space > max * 0.6 ? cut.slice(0, space) : cut}…`;
};

export const absoluteUrl = (url) => {
  const { appUrl } = deliveryConfig();
  if (!url) return appUrl;
  if (/^https?:\/\//i.test(url)) return url;
  return `${appUrl}${url.startsWith('/') ? url : `/${url}`}`;
};

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------

export const webPushConfigured = () => {
  const config = deliveryConfig();
  return Boolean(config.webPushPublicKey && config.webPushPrivateKey);
};

export const webPushPublicKey = () => (webPushConfigured() ? deliveryConfig().webPushPublicKey : null);

let webPushModule = null;
const getWebPush = async () => {
  if (!webPushModule) {
    const imported = await import('web-push');
    webPushModule = imported.default ?? imported;
  }
  return webPushModule;
};

const HIGH_URGENCY = /^(chat\.|session\.reminder\.starting_soon|lesson\.starting|security\.|system\.test)/;

const sendWebPush = async ({ userId, title, body, url, kind, tag }) => {
  const result = { delivered: 0, failed: 0, targets: 0 };
  if (!webPushConfigured()) return result;

  // A browser whose sign-in session ended (signed out, expired, signed out
  // from another device) must not keep receiving this person's notifications.
  const { liveSessionIds } = await import('../identity/deviceSessions.js');
  const live = await liveSessionIds(userId).catch(() => null);
  const subscriptions = [];
  for (const subscription of await Subscriptions.listForUser(userId)) {
    // An empty answer is treated as "unknown" rather than "signed out everywhere":
    // pruning on a wrong empty list would silently switch push off for good.
    if (live && live.size > 0 && subscription.session_id && !live.has(subscription.session_id)) {
      await Subscriptions.removeById(subscription.id).catch(() => undefined);
    } else {
      subscriptions.push(subscription);
    }
  }
  result.targets = subscriptions.length;
  if (subscriptions.length === 0) return result;

  const webpush = await getWebPush();
  const payload = JSON.stringify({
    title: truncate(title, 80) || 'Classroom',
    body: truncate(body ?? '', 180),
    url: url ?? '/',
    tag: tag ?? kind ?? null,
    kind: kind ?? null,
  });
  const config = deliveryConfig();
  const options = {
    vapidDetails: {
      subject: config.webPushSubject,
      publicKey: config.webPushPublicKey,
      privateKey: config.webPushPrivateKey,
    },
    TTL: 24 * 3_600,
    urgency: HIGH_URGENCY.test(kind ?? '') ? 'high' : 'normal',
  };

  await Promise.all(
    subscriptions.map(async (subscription) => {
      try {
        await webpush.sendNotification(
          { endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth } },
          payload,
          options,
        );
        result.delivered += 1;
        await Subscriptions.recordSuccess(subscription.id).catch(() => undefined);
      } catch (cause) {
        result.failed += 1;
        // 404 and 410: the browser dropped the subscription (site data cleared,
        // permission revoked). It will never work again.
        if (cause?.statusCode === 404 || cause?.statusCode === 410) {
          await Subscriptions.removeById(subscription.id).catch(() => undefined);
        } else {
          await Subscriptions.recordFailure(subscription.id).catch(() => undefined);
        }
        log.warn({ userId, statusCode: cause?.statusCode ?? null, message: cause?.message }, 'web push failed');
      }
    }),
  );

  return result;
};

/**
 * @returns {Promise<{ delivered: number, failed: number, targets: number }>}
 */
export const sendPush = async (input) => {
  try {
    return await sendWebPush(input);
  } catch (cause) {
    log.warn({ err: cause, userId: input.userId }, 'web push unavailable');
    return { delivered: 0, failed: 0, targets: 0 };
  }
};

// ---------------------------------------------------------------------------
// Email
// ---------------------------------------------------------------------------

const escapeHtml = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/**
 * Subject, HTML and text for one notification. Plain on purpose: it has to
 * read the same in every mail client, including the ones that block images.
 */
export const renderEmail = ({ title, body = null, url = null, recipientName = null, actionLabel = 'Open in Classroom', footer = null }) => {
  const link = absoluteUrl(url);
  const settingsLink = absoluteUrl('/settings/notifications');
  const greeting = recipientName ? `Hi ${recipientName},` : 'Hi,';
  const note = footer ?? `You get this email because of your notification settings: ${settingsLink}`;

  const text = [greeting, '', title, body ? `\n${body}` : '', '', `${actionLabel}: ${link}`, '', '—', note]
    .filter((line) => line !== null)
    .join('\n');

  const html = `<!doctype html>
<html><body style="margin:0;padding:24px;background:#f4f5f7;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#1f2933">
  <div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;padding:28px">
    <p style="margin:0 0 16px">${escapeHtml(greeting)}</p>
    <p style="margin:0 0 8px;font-size:18px;font-weight:700">${escapeHtml(title)}</p>
    ${body ? `<p style="margin:0 0 20px;line-height:1.5;white-space:pre-wrap">${escapeHtml(body)}</p>` : ''}
    <p style="margin:0 0 24px"><a href="${escapeHtml(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#2563eb;color:#ffffff;text-decoration:none;font-weight:600">${escapeHtml(actionLabel)}</a></p>
    <p style="margin:0;font-size:12px;color:#6b7280">${escapeHtml(note)}</p>
  </div>
</body></html>`;

  return { subject: truncate(title, 120), html, text };
};

let smtpTransport = null;
const getSmtp = async () => {
  if (!smtpTransport) {
    const imported = await import('nodemailer');
    const nodemailer = imported.default ?? imported;
    const config = deliveryConfig();
    smtpTransport = nodemailer.createTransport({
      host: config.smtpHost,
      port: config.smtpPort,
      secure: false,
      connectionTimeout: 10_000,
    });
  }
  return smtpTransport;
};

let sesClient = null;
const getSes = async () => {
  if (!sesClient) {
    const { SESv2Client } = await import('@aws-sdk/client-sesv2');
    sesClient = new SESv2Client({ region: deliveryConfig().sesRegion });
  }
  return sesClient;
};

/**
 * @param {{ to: string, subject: string, html: string, text: string, kind?: string }} message
 * @returns {Promise<{ delivered: number, transport: string }>}
 */
export const sendEmail = async ({ to, subject, html, text, kind = 'notification' }) => {
  if (!to) return { delivered: 0, transport: null };
  const config = deliveryConfig();
  const from = config.mailFrom;

  if (config.mailTransport === 'ses') {
    const { SendEmailCommand } = await import('@aws-sdk/client-sesv2');
    const ses = await getSes();
    await ses.send(
      new SendEmailCommand({
        FromEmailAddress: from,
        Destination: { ToAddresses: [to] },
        Content: { Simple: { Subject: { Data: subject }, Body: { Html: { Data: html }, Text: { Data: text } } } },
        EmailTags: [{ Name: 'kind', Value: String(kind).replace(/[^\w-]/g, '_') }],
      }),
    );
    return { delivered: 1, transport: 'ses' };
  }

  const smtp = await getSmtp();
  await smtp.sendMail({ from, to, subject, html, text, headers: { 'X-Classroom-Kind': String(kind) } });
  return { delivered: 1, transport: 'smtp' };
};

export default { webPushConfigured, webPushPublicKey, sendPush, sendEmail, renderEmail, absoluteUrl };
