/**
 * public.routes — what the public homepage may call without an account  (Landing)
 *
 * Mounted under /public (app.js). Nothing here reads or changes an account.
 *
 *   POST /contact   the homepage's contact form
 *
 * A message is always stored (contact_messages, 025). When CONTACT_EMAIL is
 * set it is also forwarded there (the sender's address is in the text), through the
 * same mail transport as every other email (SMTP/Mailpit in development).
 * Forwarding happens after the answer, so a slow mail server never makes the
 * form wait. A hidden field catches robots: when it is filled, the answer is
 * the same, but nothing is stored.
 */

import { Router } from 'express';
import { z } from 'zod';

import { pool } from '../db/pool.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { logger } from '../observability/logger.js';
import { route, validate } from './_helpers.js';

const log = logger.child({ component: 'contact' });
const router = Router();

const TOPICS = ['school', 'question', 'support', 'privacy', 'other'];
const TOPIC_LABELS = {
  school: 'Bringing Classroom to a school or team',
  question: 'A question about the product',
  support: 'Help with an account',
  privacy: 'Privacy or data',
  other: 'Something else',
};

const escapeHtml = (text) =>
  String(text).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const forward = async ({ id, name, email, topic, message }) => {
  const to = process.env.CONTACT_EMAIL?.trim();
  if (!to) return;
  try {
    const { sendEmail } = await import('../notifications/delivery.js');
    const subject = `Contact: ${TOPIC_LABELS[topic]} (${name})`;
    const text = `${name} <${email}> wrote:\n\n${message}\n\nTopic: ${TOPIC_LABELS[topic]}\nReference: ${id}`;
    const html = `<p><strong>${escapeHtml(name)}</strong> &lt;${escapeHtml(email)}&gt; wrote:</p>
<p style="white-space:pre-wrap">${escapeHtml(message)}</p>
<p style="color:#666">Topic: ${escapeHtml(TOPIC_LABELS[topic])}<br>Reference: ${escapeHtml(id)}</p>`;
    await sendEmail({ to, subject, text, html, kind: 'contact' });
    await pool.query(`UPDATE contact_messages SET forwarded_at = now() WHERE id = $1`, [id]);
  } catch (cause) {
    log.warn({ err: cause, id }, 'contact message stored but not forwarded');
  }
};

router.post(
  '/contact',
  rateLimit({ key: 'public:contact', points: 5, durationSec: 3600, by: ['ip'] }),
  validate({
    body: z.object({
      name: z.string().trim().min(1).max(100),
      email: z.string().trim().email().max(254),
      topic: z.enum(TOPICS),
      message: z.string().trim().min(10).max(4000),
      website: z.string().max(200).optional(),
    }),
  }),
  route(async (req, res) => {
    res.status(202);
    // Robots fill the hidden field: same answer, nothing kept.
    if (req.body.website) return { received: true };

    const { rows } = await pool.query(
      `INSERT INTO contact_messages (name, email, topic, message, ip, user_agent, user_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
      [
        req.body.name,
        req.body.email,
        req.body.topic,
        req.body.message,
        req.ip ?? null,
        String(req.get('user-agent') ?? '').slice(0, 500) || null,
        req.user?.id ?? null,
      ],
    );
    const id = rows[0].id;
    log.info({ id, topic: req.body.topic }, 'contact message received');
    setImmediate(() => void forward({ id, ...req.body }));
    return { received: true, reference: id };
  }),
);

export default router;
