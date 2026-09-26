/**
 * notificationWorker — in-app · push · email  (F2, F6 · Settings Phase B)
 *
 * Every notification in the product ends here: a thread reply, a mention, a
 * chat message to someone who is away, a lesson reminder, the digest, the
 * summary after a lesson. One worker, because the rules that decide are the
 * same every time — settings/notifications.js#decide — and they must see the
 * settings as they are at delivery, not as they were when the job was queued.
 *
 * Per person:
 *   1. settings        the type × channel matrix from Settings → Notifications
 *   2. focus           in a lesson, chat is held and summarised afterwards
 *   3. presence        someone looking at the app gets no push on top
 *   4. quiet hours     no push, unless a lesson starts and they allow it
 *   5. dedupe          three replies in two minutes are one push, not three
 *
 * Jobs (queue 'notify'):
 *   notification.fanout         one notification, many people
 *   notification.push           v6: push only (the bell entry already exists)
 *   notification.email          one email; account emails always go out
 *   notify.inApp                v6 jobs.notify()
 *   session.reminder            ReminderRules, T-24h and T-10m
 *   digest.daily                community digest by email
 *   notification.focus.flush    the summary after a lesson
 *
 * Push delivery never throws, so a retried job cannot notify everyone twice.
 * An email that fails is logged per person for the same reason; only a
 * single-recipient account email is retried.
 */

import { defineWorker, QUEUE_NAMES, PermanentJobError } from '../queues.js';
import { utilityConnection } from '../connection.js';
import * as NotificationService from '../../community/NotificationService.js';
import * as LiveState from '../../realtime/liveState.js';
import * as ScheduleService from '../../scheduling/ScheduleService.js';
import * as ReminderRules from '../../scheduling/ReminderRules.js';
import * as Rules from '../../settings/notifications.js';
import * as Delivery from '../../notifications/delivery.js';
import * as Focus from '../../notifications/focus.js';

const redis = utilityConnection('notify');

const DEDUPE_TTL_SECONDS = 120;

/* ------------------------------------------------------------------ *
 * Job types
 * ------------------------------------------------------------------ */

const handlers = {
  'notification.fanout': (job, log) => deliver(normalize(job.data), log),
  'notification.push': (job, log) => deliver(normalize({ ...job.data, channels: ['push'] }), log),
  'notification.email': emailJob,
  'notify.inApp': (job, log) =>
    deliver(
      normalize({
        kind: job.data.kind,
        recipientIds: [job.data.userId],
        title: job.data.payload?.title ?? job.data.title,
        body: job.data.payload?.body ?? job.data.body,
        url: job.data.payload?.url ?? job.data.url,
        dedupeKey: job.data.dedupeKey,
      }),
      log,
    ),
  'session.reminder': sessionReminder,
  'digest.daily': digest,
  'notification.focus.flush': focusFlush,
};

export function createNotificationWorker() {
  return defineWorker(QUEUE_NAMES.NOTIFY, async (job, log) => {
    const handler = handlers[job.name];
    if (!handler) throw new PermanentJobError(`Unknown notification job: ${job.name}`);
    return handler(job, log);
  });
}

/* ------------------------------------------------------------------ *
 * Fan-out
 * ------------------------------------------------------------------ */

/** Both payload shapes in use: v7 (kind, recipientIds, url) and v6 (type, userIds, href). */
const normalize = (data = {}) => ({
  kind: data.kind ?? data.type ?? null,
  recipientIds: [...new Set(data.recipientIds ?? data.userIds ?? (data.userId ? [data.userId] : []))],
  title: data.title ?? '',
  body: data.body ?? null,
  url: data.url ?? data.href ?? null,
  actorId: data.actorId ?? null,
  dedupeKey: data.dedupeKey ?? null,
  channels: (data.channels ?? ['in-app', 'push', 'email']).map(Rules.normalizeChannel),
  data: data.data ?? {},
  skipHold: Boolean(data.skipHold),
});

/** 'in-class', 'online' or 'offline', from the presence gateway (realtime/liveState.js). */
const presenceOf = (userId) => LiveState.stateOf(userId);

const heldItem = (n, category) => ({
  type: category === 'mentions' ? 'mention' : 'message',
  from: n.data.from ?? n.title ?? null,
  conversationId: n.data.conversationId ?? null,
  channelId: n.data.channelId ?? null,
});

async function deliver(n, log) {
  if (!n.kind || n.recipientIds.length === 0) {
    throw new PermanentJobError('a notification needs a kind and recipients', { kind: n.kind });
  }

  const result = { delivered: 0, suppressed: 0, held: 0, byChannel: { inApp: 0, push: 0, email: 0 } };

  for (const recipientId of n.recipientIds) {
    // Never tell someone about their own action.
    if (recipientId === n.actorId) continue;

    const context = await NotificationService.getDeliveryContext(recipientId);
    if (!context?.active) {
      result.suppressed += 1;
      continue;
    }

    const presence = await presenceOf(recipientId);
    let decision = Rules.decide({
      kind: n.kind,
      settings: context.settings,
      presence,
      requested: n.channels,
      timeZone: context.timeZone,
    });

    if (decision.hold) {
      if (!n.skipHold) {
        await Focus.hold(recipientId, heldItem(n, decision.category));
        result.held += 1;
        continue;
      }
      decision = Rules.decide({
        kind: n.kind,
        settings: context.settings,
        presence: 'online',
        requested: n.channels,
        timeZone: context.timeZone,
      });
    }

    let { channels } = decision;

    if (n.dedupeKey && channels.some((channel) => channel !== 'inApp')) {
      const fresh = await redis.set(`notify:dedupe:${recipientId}:${n.dedupeKey}`, '1', 'EX', DEDUPE_TTL_SECONDS, 'NX');
      if (!fresh) channels = channels.filter((channel) => channel === 'inApp');
    }

    if (channels.length === 0) {
      result.suppressed += 1;
      continue;
    }

    // "Show message text" off: lock screens and inboxes say who, not what.
    const hideText = Rules.CHAT_CATEGORIES.has(decision.category) && !context.settings.showPreviews;
    const outsideBody = hideText ? 'Open Classroom to read it.' : n.body;

    if (channels.includes('inApp')) {
      await NotificationService.createInApp({
        userId: recipientId,
        kind: n.kind,
        title: n.title,
        body: n.body,
        url: n.url,
        actorId: n.actorId,
        data: n.data,
      });
      result.byChannel.inApp += 1;
    }

    if (channels.includes('push')) {
      const sent = await Delivery.sendPush({ userId: recipientId, title: n.title, body: outsideBody, url: n.url, kind: n.kind });
      result.byChannel.push += sent.delivered;
    }

    if (channels.includes('email') && context.email && !context.emailSuppressed) {
      try {
        const rendered = Delivery.renderEmail({
          title: n.title,
          body: outsideBody,
          url: n.url,
          recipientName: context.displayName,
        });
        await Delivery.sendEmail({ to: context.email, ...rendered, kind: n.kind });
        result.byChannel.email += 1;
      } catch (cause) {
        log.error({ err: cause, recipientId, kind: n.kind }, 'notify: email not sent');
      }
    }

    result.delivered += 1;
  }

  log.info({ kind: n.kind, ...result }, 'notify: delivered');
  return result;
}

/* ------------------------------------------------------------------ *
 * Email
 * ------------------------------------------------------------------ */

const ACCOUNT_EMAIL = {
  'email.verify': { actionLabel: 'Confirm email address', body: 'Confirm that this address is yours. The link works for 24 hours.' },
  'password.reset': { actionLabel: 'Choose a new password', body: 'Someone asked to reset your password. If that was not you, ignore this email. The link works for one hour.' },
};

/**
 * One email. Account emails (confirm address, reset password) go out whatever
 * the settings say, and are retried when the mail server is unavailable.
 * Anything else follows the settings like every other notification.
 */
async function emailJob(job, log) {
  const kind = job.data.kind ?? job.data.type ?? 'system.email';
  const userId = job.data.userId;
  if (!userId) throw new PermanentJobError('an email needs a userId');

  if (Rules.categoryOf(kind) !== 'security') {
    return deliver(normalize({ ...job.data, kind, recipientIds: [userId], channels: ['email'] }), log);
  }

  const context = await NotificationService.getDeliveryContext(userId);
  if (!context?.email) return { skipped: 'no address' };
  if (context.emailSuppressed) return { skipped: 'address suppressed after a bounce' };

  const account = ACCOUNT_EMAIL[kind] ?? { actionLabel: 'Open Classroom', body: null };
  const rendered = Delivery.renderEmail({
    title: job.data.title ?? 'Classroom',
    body: job.data.body ?? account.body,
    url: job.data.url ?? job.data.href,
    recipientName: context.displayName,
    actionLabel: account.actionLabel,
    footer: 'You get this email because of an action on your Classroom account.',
  });
  // Throws on a mail server problem: BullMQ retries with backoff.
  await Delivery.sendEmail({ to: context.email, ...rendered, kind });
  log.info({ userId, kind }, 'notify: account email sent');
  return { sent: 1 };
}

/* ------------------------------------------------------------------ *
 * Lesson reminders (F1, F3)
 * ------------------------------------------------------------------ */

/**
 * Enqueued by ReminderRules.enqueueDue(). The reminder row is the source of
 * truth, so the audience is resolved at send time.
 */
async function sessionReminder(job, log) {
  const { reminderId, sessionId, ruleKey, template } = job.data;

  const session = await ScheduleService.getSession(sessionId);
  if (!session) {
    await ReminderRules.markSent(reminderId, { recipients: 0 });
    throw new PermanentJobError('Session no longer exists', { sessionId });
  }
  if (session.status !== 'scheduled') {
    await ReminderRules.markSent(reminderId, { recipients: 0 });
    return { skipped: session.status };
  }

  const recipientIds = await ScheduleService.listAudience(sessionId);
  const when = ScheduleService.formatLocal(session);

  const result = await deliver(
    normalize({
      kind: template,
      recipientIds,
      title: session.title,
      body: ruleKey === 'T-10m' ? 'Starts in 10 minutes' : `Starts ${when}`,
      url: session.lessonId ? `/lessons/${session.lessonId}/live` : '/',
      dedupeKey: `session:${sessionId}:${ruleKey}`,
      channels: ruleKey === 'T-10m' ? ['push', 'in-app'] : ['email', 'push', 'in-app'],
      data: { sessionId, lessonId: session.lessonId ?? null },
    }),
    log,
  );

  await ReminderRules.markSent(reminderId, { recipients: result.delivered });
  return result;
}

/* ------------------------------------------------------------------ *
 * Digest (F2)
 * ------------------------------------------------------------------ */

async function digest(job, log) {
  const { userId, date } = job.data;
  const content = await NotificationService.buildDigest({ userId, date });
  if (!content || content.items.length === 0) return { skipped: 'nothing to send' };

  const context = await NotificationService.getDeliveryContext(userId);
  if (!context?.email || context.emailSuppressed) return { skipped: 'no address' };

  const rendered = Delivery.renderEmail({
    title: content.subject,
    body: content.summary,
    url: content.url,
    recipientName: context.displayName,
    actionLabel: 'Open the community',
  });
  await Delivery.sendEmail({ to: context.email, ...rendered, kind: 'digest.daily' });
  log.info({ userId, items: content.items.length }, 'notify: digest sent');
  return { sent: 1, items: content.items.length };
}

/* ------------------------------------------------------------------ *
 * Focus: the summary after a lesson
 * ------------------------------------------------------------------ */

async function focusFlush(job, log) {
  const { userId } = job.data;
  if (!userId) throw new PermanentJobError('focus flush needs a userId');

  await Focus.clearSchedule(userId);

  if (await Focus.isInLesson(userId)) {
    // Still teaching or learning: look again in a minute.
    await Focus.scheduleFlush(userId);
    return { waiting: true };
  }

  const items = await Focus.takeHeld(userId);
  const summary = Focus.summarizeHeld(items);
  if (!summary) return { empty: true };

  return deliver(
    normalize({
      kind: 'chat.focus.summary',
      recipientIds: [userId],
      title: summary.title,
      body: summary.body,
      url: summary.url,
      channels: ['in-app', 'push'],
      skipHold: true,
      data: { held: summary.count, mentions: summary.mentions },
    }),
    log,
  );
}

export default createNotificationWorker;
