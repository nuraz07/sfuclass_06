#!/usr/bin/env bash
# landing-v2-install.sh — Homepage v2 (light, more sections, contact form) and a
# calmer look for the app behind sign-in.
#
# Homepage:  light design, navigation with Features · How it works · Rooms ·
#            For schools · Security · FAQ · Contact, a longer lesson animation,
#            a scroll story, comparison, use cases, FAQ and a working contact form.
# The app:   a new top bar and the "evening" theme. Presentation only — no page,
#            chat, call or data logic is changed; the classroom itself is untouched.
#
# Needs the first homepage install (landing-install.sh).
# Run from the project folder:  bash landing-v2-install.sh
# Writes 17 files, patches 2 more, backup in .landing-v2-backup/<timestamp>/.
# Undo:                         bash landing-v2-install.sh --restore
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/025_contact_messages.sql
  server/src/routes/public.routes.js
  apps/web/src/pages/LandingPage.jsx
  apps/web/src/components/Landing/SiteNav.jsx
  apps/web/src/components/Landing/HeroDemo.jsx
  apps/web/src/components/Landing/LessonStory.jsx
  apps/web/src/components/Landing/UseCases.jsx
  apps/web/src/components/Landing/Faq.jsx
  apps/web/src/components/Landing/ContactForm.jsx
  apps/web/src/components/Landing/Reveal.jsx
  apps/web/src/components/Landing/motion.js
  apps/web/src/components/Landing/landingModel.js
  apps/web/src/components/Landing/landing.css
  apps/web/src/components/Landing/__checks__/landingModel.check.mjs
  apps/web/src/components/Auth/auth.css
  apps/web/src/components/system/AppHeader.jsx
  apps/web/src/styles/theme.css
  server/src/app.js
  apps/web/src/pages/AppLayout.jsx
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .landing-v2-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/025_contact_messages.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  echo "Restored from $FIRST. The migration file 025 stays, because the database already has it."
  exit 0
fi

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need apps/web/src/components/system/AuthGate.jsx "LandingPage" "the first homepage install (landing-install.sh)"
need apps/web/src/components/Auth/AuthShell.jsx "au-board" "the first homepage install (landing-install.sh)"
need apps/web/src/components/Landing/RoomPlanner.jsx "timelineFor" "the first homepage install (landing-install.sh)"
need apps/web/src/pages/AppLayout.jsx "DeletionBanner" "Settings Phase C"
need server/src/app.js "scheduledRoomsRoutes" "the rooms feature"
need server/src/notifications/delivery.js "export const sendEmail" "Settings Phase B"
if ls server/src/db/migrations/025_*.sql 2>/dev/null | grep -qv 025_contact_messages.sql; then
  MISSING+=("another migration 025 exists: $(ls server/src/db/migrations/025_*.sql | tr '\n' ' ')")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what this update expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".landing-v2-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/025_contact_messages.sql <<'__LP2_EOF__'
-- 025_contact_messages.sql  (Landing: the contact form)
--
-- Messages from the homepage's contact form. Kept so nothing is lost when
-- email is not configured; forwarded to CONTACT_EMAIL when it is.
-- Additive only.

create table if not exists contact_messages (
  id           uuid        primary key default gen_random_uuid(),
  name         text        not null,
  email        citext      not null,
  topic        text        not null,
  message      text        not null,
  ip           inet,
  user_agent   text,
  user_id      uuid        references users (id) on delete set null,
  forwarded_at timestamptz,
  handled_at   timestamptz,
  created_at   timestamptz not null default now(),
  constraint contact_messages_topic_check check (topic in ('school', 'question', 'support', 'privacy', 'other'))
);

create index if not exists contact_messages_open_idx on contact_messages (created_at desc) where handled_at is null;
__LP2_EOF__
echo "wrote server/src/db/migrations/025_contact_messages.sql"

mkdir -p server/src/routes
cat > server/src/routes/public.routes.js <<'__LP2_EOF__'
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
__LP2_EOF__
echo "wrote server/src/routes/public.routes.js"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/LandingPage.jsx <<'__LP2_EOF__'
import { useEffect, useRef } from 'react';
import { Link } from 'react-router-dom';
import { useCore } from '@classroom/core-client';

import SiteNav, { Brand } from '../components/Landing/SiteNav.jsx';
import HeroDemo from '../components/Landing/HeroDemo.jsx';
import LessonStory from '../components/Landing/LessonStory.jsx';
import RoomPlanner from '../components/Landing/RoomPlanner.jsx';
import UseCases from '../components/Landing/UseCases.jsx';
import Faq from '../components/Landing/Faq.jsx';
import ContactForm from '../components/Landing/ContactForm.jsx';
import Reveal from '../components/Landing/Reveal.jsx';
import { useScrollFrame } from '../components/Landing/motion.js';
import { enterProgress } from '../components/Landing/landingModel.js';
import '../components/Landing/landing.css';

/**
 * The public homepage  (Landing)
 *
 * What someone sees before they have an account: what Classroom is, why it
 * is different from a meeting link, how a lesson runs from plan to follow-up,
 * a room planner to try, who it is for, how it protects people, answers, and
 * a way to get in touch. Nothing here needs an account; only the contact form
 * talks to the server.
 *
 * Shown at "/" to anyone not signed in (AuthGate), and at /welcome to
 * everyone. Signed-in visitors get "Open Classroom" instead of sign-up.
 */

const FEATURES = [
  {
    id: 'live',
    size: 'wide',
    title: 'Live lessons',
    text: 'Video and sound tuned for teaching: screen sharing, reactions that never interrupt, raised hands, learners who join muted when you want them to.',
  },
  {
    id: 'rooms',
    size: 'tall',
    title: 'Rooms with doors',
    text: 'A start, an end and a lobby. The doors open 3 to 10 minutes early, with a countdown and a camera check.',
  },
  {
    id: 'waitlist',
    title: 'Seats and a waiting list',
    text: 'When a room is full, the next person gets the next free seat, held for them for two minutes.',
  },
  {
    id: 'courses',
    title: 'Courses',
    text: 'Lessons in order, materials in one place, progress you can see.',
  },
  {
    id: 'community',
    title: 'Community spaces',
    text: 'Threads for each class, course or group, for everything between lessons.',
  },
  {
    id: 'messages',
    size: 'wide',
    title: 'Messages that respect people',
    text: 'Private and group chats with read receipts each person controls, mutes that end when you want them to, and blocks that work everywhere.',
  },
  {
    id: 'calm',
    title: 'Quiet hours and focus',
    text: 'Nothing buzzes at night. During a lesson, messages wait and arrive as one summary.',
  },
  {
    id: 'zones',
    title: 'Every time zone',
    text: 'Invitations show each guest their own time, and add the lesson to any calendar.',
  },
];

function FeatureArt({ id }) {
  switch (id) {
    case 'live':
      return (
        <div className="lp-fa lp-fa--live">
          <i className="is-sky is-speaking" />
          <i className="is-mint" />
          <i className="is-sun" />
          <i className="is-rose" />
          <span className="lp-fa__float">👏</span>
        </div>
      );
    case 'rooms':
      return (
        <div className="lp-fa lp-fa--doors">
          <span className="lp-fa__door lp-fa__door--l" />
          <span className="lp-fa__door lp-fa__door--r" />
          <span className="lp-fa__count">4:59</span>
        </div>
      );
    case 'waitlist':
      return (
        <div className="lp-fa lp-fa--queue">
          <span className="is-seat" />
          <span className="is-seat" />
          <span className="is-seat is-free" />
          <span className="is-wait" />
          <span className="is-wait" />
        </div>
      );
    case 'courses':
      return (
        <div className="lp-fa lp-fa--course">
          <span style={{ '--w': '100%' }} />
          <span style={{ '--w': '100%' }} />
          <span style={{ '--w': '45%' }} />
        </div>
      );
    case 'community':
      return (
        <div className="lp-fa lp-fa--thread">
          <span />
          <span className="is-reply" />
          <span className="is-reply" />
        </div>
      );
    case 'messages':
      return (
        <div className="lp-fa lp-fa--chat">
          <span className="lp-fa__bubble">Can we go over question 3?</span>
          <span className="lp-fa__bubble is-mine">Of course, after class 👍</span>
          <span className="lp-fa__seen">Seen</span>
        </div>
      );
    case 'calm':
      return (
        <div className="lp-fa lp-fa--moon">
          <span className="lp-fa__moon" />
          <span className="lp-fa__z">22:00 – 07:00</span>
        </div>
      );
    default:
      return (
        <div className="lp-fa lp-fa--zones">
          <span>16:00 Berlin</span>
          <span>15:00 London</span>
          <span>10:00 New York</span>
        </div>
      );
  }
}

const COMPARISON = [
  ['Opens when you decide', 'Doors open 3 to 10 minutes before the start; a lobby with countdown until then', 'Open from the moment the link exists'],
  ['Ends on time', 'Closes at the end, with a five-minute notice and "+10 min" for the host', 'Runs until someone leaves last'],
  ['A full room', 'A waiting list, and the next free seat held for the next person', 'Whoever clicks first'],
  ['Letting people in', 'Invited only, or anyone with the link, plus a knock-and-admit lobby', 'Usually the link is the only key'],
  ['Before and after the lesson', 'Courses, materials, community spaces and messages in the same place', 'Somewhere else, in another tool'],
  ['Quiet evenings', 'Quiet hours and focus during lessons for every notification', 'Every ping, every time'],
];

const SECURITY = [
  ['Two-step sign-in', 'An authenticator app, recovery codes, or a passkey — fingerprint, face or PIN instead of a password.'],
  ['Every device in view', 'See where you are signed in and sign any device out at once; it stops immediately.'],
  ['A history you can read', 'Sign-ins, failed attempts and settings changes, with the device they came from.'],
  ['Who may reach you', 'Anyone, only people you share a class with, or nobody. Blocks work everywhere.'],
  ['What others see', 'Choose who sees your profile, your online status and your read receipts — and preview it.'],
  ['Your data, your copy', 'Download everything as one file. Delete your account, with 14 days to change your mind.'],
];

/** The hero demo settles from a slight tilt as it scrolls toward the middle of the screen. */
function TiltOnScroll({ children }) {
  const ref = useRef(null);
  useScrollFrame(ref, (rect, viewport) => {
    const progress = enterProgress({ top: rect.top + viewport * 0.35, height: rect.height, viewport });
    ref.current.style.setProperty('--lp-tilt', String(1 - progress));
  });
  return (
    <div className="lp-tilt" ref={ref}>
      {children}
    </div>
  );
}

export default function LandingPage() {
  const { status } = useCore();
  const signedIn = status === 'authenticated';

  useEffect(() => {
    const previous = document.title;
    document.title = 'Classroom: live lessons, courses and community';
    document.documentElement.classList.add('lp-root');
    return () => {
      document.title = previous;
      document.documentElement.classList.remove('lp-root');
    };
  }, []);

  const primary = signedIn ? (
    <Link className="lp-button lp-button--primary" to="/">
      Open Classroom
    </Link>
  ) : (
    <Link className="lp-button lp-button--primary" to="/signup">
      Create account
    </Link>
  );

  return (
    <div className="lp">
      <a className="lp-skip" href="#lp-main">
        Skip to content
      </a>
      <SiteNav signedIn={signedIn} />

      <main id="lp-main">
        {/* ------------------------------------------------ hero */}
        <section className="lp-hero" aria-labelledby="lp-hero-title">
          <div className="lp-hero__text">
            <h1 id="lp-hero-title" className="lp-hero__title">
              {['Live lessons', 'that start', 'the moment', 'you do.'].map((line, index) => (
                <span key={line} className="lp-line" style={{ '--i': index }}>
                  <span>{line}</span>
                </span>
              ))}
            </h1>
            <p className="lp-hero__lead lp-enter" style={{ '--i': 4 }}>
              Plan a room, share one link, and the doors open a few minutes before you begin. Video, chat, courses and
              your community come with it — calm, private and on time.
            </p>
            <div className="lp-hero__actions lp-enter" style={{ '--i': 5 }}>
              {primary}
              {signedIn ? null : (
                <Link className="lp-button lp-button--ghost" to="/login">
                  Sign in
                </Link>
              )}
              <a className="lp-button lp-button--text" href="#how">
                See how a lesson runs
              </a>
            </div>
            <ul className="lp-hero__assurances lp-enter" style={{ '--i': 6 }}>
              <li>Runs in the browser</li>
              <li>Nothing to install for your class</li>
              <li>Two-step sign-in and passkeys</li>
            </ul>
          </div>
          <div className="lp-hero__demo lp-enter" style={{ '--i': 2 }}>
            <TiltOnScroll>
              <HeroDemo />
            </TiltOnScroll>
          </div>
        </section>

        <Reveal as="section" className="lp-for" aria-label="Who uses Classroom">
          <p className="lp-for__lead">Made for</p>
          <ul className="lp-for__list">
            {['Teachers', 'Schools', 'Universities', 'Tutors', 'Coaches', 'Study groups', 'Communities'].map((who) => (
              <li key={who}>{who}</li>
            ))}
          </ul>
        </Reveal>

        {/* ------------------------------------------------ features */}
        <section id="features" className="lp-section" aria-labelledby="lp-features-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-features-title" className="lp-section__title">
              Everything a class needs, in one calm place
            </h2>
            <p className="lp-section__lead">
              Not another meeting tool with a school sticker on it. Classroom is built around how lessons actually work:
              they start at a time, have a room, a group and a follow-up.
            </p>
          </Reveal>
          <div className="lp-bento">
            {FEATURES.map((feature, index) => (
              <Reveal as="article" key={feature.id} delay={(index % 4) * 90} className={`lp-bento__item lp-bento__item--${feature.size ?? 'std'} lp-bento__item--${feature.id}`}>
                <FeatureArt id={feature.id} />
                <h3 className="lp-bento__title">{feature.title}</h3>
                <p className="lp-bento__text">{feature.text}</p>
              </Reveal>
            ))}
          </div>
        </section>

        {/* ------------------------------------------------ why */}
        <section className="lp-section lp-section--tint" aria-labelledby="lp-why-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-why-title" className="lp-section__title">
              Why teach here instead of a meeting link
            </h2>
            <p className="lp-section__lead">A meeting link is a door with no building behind it. Here is what changes.</p>
          </Reveal>
          <Reveal className="lp-compare" role="table" aria-label="Classroom compared with a typical meeting link">
            <div className="lp-compare__row lp-compare__head" role="row">
              <span role="columnheader" />
              <span role="columnheader">Classroom</span>
              <span role="columnheader">A typical meeting link</span>
            </div>
            {COMPARISON.map(([topic, ours, theirs], index) => (
              <div key={topic} className="lp-compare__row" role="row" style={{ '--i': index }}>
                <span role="rowheader" className="lp-compare__topic">
                  {topic}
                </span>
                <span role="cell" className="lp-compare__ours">
                  {ours}
                </span>
                <span role="cell" className="lp-compare__theirs">
                  {theirs}
                </span>
              </div>
            ))}
          </Reveal>
        </section>

        {/* ------------------------------------------------ how */}
        <section id="how" className="lp-section" aria-labelledby="lp-how-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-how-title" className="lp-section__title">
              A lesson, from plan to follow-up
            </h2>
            <p className="lp-section__lead">Scroll through one lesson the way it really happens.</p>
          </Reveal>
          <LessonStory />
        </section>

        {/* ------------------------------------------------ rooms */}
        <section id="rooms" className="lp-section lp-section--tint" aria-labelledby="lp-rooms-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-rooms-title" className="lp-section__title">
              Try planning a room
            </h2>
            <p className="lp-section__lead">
              Move the controls. This is how it works inside, down to the minute the doors open for your guests — in
              their own time zone.
            </p>
          </Reveal>
          <Reveal>
            <RoomPlanner signedIn={signedIn} />
          </Reveal>
        </section>

        {/* ------------------------------------------------ teams */}
        <section id="teams" className="lp-section" aria-labelledby="lp-teams-title">
          <Reveal className="lp-section__head">
            <h2 id="lp-teams-title" className="lp-section__title">
              For schools, and everyone in them
            </h2>
            <p className="lp-section__lead">The same place feels right for the person teaching, the one learning, and the school around them.</p>
          </Reveal>
          <Reveal>
            <UseCases />
          </Reveal>
        </section>

        {/* ------------------------------------------------ security */}
        <section id="security" className="lp-section lp-section--tint" aria-labelledby="lp-security-title">
          <div className="lp-split">
            <Reveal className="lp-section__head lp-split__head">
              <h2 id="lp-security-title" className="lp-section__title">
                A safe space, by design
              </h2>
              <p className="lp-section__lead">
                Privacy settings in plain language, a check-up that tells you where you stand, and protection you can see
                working.
              </p>
              <div className="lp-checkup" aria-hidden="true">
                <p className="lp-checkup__title">Privacy check-up</p>
                <p className="lp-checkup__line is-ok">People you share a class with can message you</p>
                <p className="lp-checkup__line is-ok">Two-step sign-in is on</p>
                <p className="lp-checkup__line is-ok">Signed in on 2 devices</p>
                <p className="lp-checkup__line is-ok">You have blocked nobody</p>
              </div>
            </Reveal>
            <dl className="lp-facts">
              {SECURITY.map(([title, text], index) => (
                <Reveal key={title} delay={(index % 2) * 90}>
                  <dt>{title}</dt>
                  <dd>{text}</dd>
                </Reveal>
              ))}
            </dl>
          </div>
        </section>

        {/* ------------------------------------------------ faq */}
        <section id="faq" className="lp-section" aria-labelledby="lp-faq-title">
          <div className="lp-split">
            <Reveal className="lp-section__head lp-split__head">
              <h2 id="lp-faq-title" className="lp-section__title">
                Questions, answered
              </h2>
              <p className="lp-section__lead">
                Something missing? <a href="#contact">Write to us</a>.
              </p>
            </Reveal>
            <Reveal>
              <Faq />
            </Reveal>
          </div>
        </section>

        {/* ------------------------------------------------ contact */}
        <section id="contact" className="lp-section lp-section--tint" aria-labelledby="lp-contact-title">
          <div className="lp-split">
            <Reveal className="lp-section__head lp-split__head">
              <h2 id="lp-contact-title" className="lp-section__title">
                Talk to us
              </h2>
              <p className="lp-section__lead">
                Bringing Classroom to a school or team, a question before you start, or help with your account — write,
                and a person answers.
              </p>
              <ul className="lp-contact__notes">
                <li>For schools: we help you set up classes and accounts.</li>
                <li>For privacy questions: tell us what you want to know or have removed.</li>
                <li>Already have an account? Sign in first, then write, so we can find it.</li>
              </ul>
            </Reveal>
            <Reveal className="lp-contact">
              <ContactForm />
            </Reveal>
          </div>
        </section>

        {/* ------------------------------------------------ final */}
        <Reveal as="section" className="lp-final" aria-labelledby="lp-final-title">
          <h2 id="lp-final-title" className="lp-final__title">
            Your next lesson could start in ten minutes.
          </h2>
          <p className="lp-final__lead">Create an account, plan a room, send the link.</p>
          <div className="lp-hero__actions">
            {signedIn ? (
              <Link className="lp-button lp-button--primary" to="/rooms/new">
                Plan a room
              </Link>
            ) : (
              <>
                {primary}
                <Link className="lp-button lp-button--ghost" to="/login">
                  Sign in
                </Link>
              </>
            )}
          </div>
        </Reveal>
      </main>

      <footer className="lp-footer">
        <div className="lp-footer__brand">
          <Brand />
          <p>Live lessons, courses and community, in one calm place.</p>
        </div>
        <nav className="lp-footer__cols" aria-label="Footer">
          <div>
            <p className="lp-footer__head">Product</p>
            <a href="#features">Features</a>
            <a href="#how">How it works</a>
            <a href="#rooms">Rooms</a>
          </div>
          <div>
            <p className="lp-footer__head">For</p>
            <a href="#teams">Teachers</a>
            <a href="#teams">Schools</a>
            <a href="#teams">Tutors and coaches</a>
          </div>
          <div>
            <p className="lp-footer__head">Trust</p>
            <a href="#security">Security</a>
            <a href="#security">Privacy</a>
            <a href="#faq">FAQ</a>
          </div>
          <div>
            <p className="lp-footer__head">Get in touch</p>
            <a href="#contact">Contact</a>
            {signedIn ? <Link to="/">Open Classroom</Link> : <Link to="/login">Sign in</Link>}
            {signedIn ? null : <Link to="/signup">Create account</Link>}
          </div>
        </nav>
        <p className="lp-footer__small">© {new Date().getFullYear()} Classroom</p>
      </footer>
    </div>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/pages/LandingPage.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/SiteNav.jsx <<'__LP2_EOF__'
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';

/**
 * The homepage's navigation  (Landing)
 *
 * Condenses once the page scrolls, and a highlighter mark slides to the
 * section you are reading. On small screens the links move into a sheet that
 * opens from the top. Links are in-page anchors; Sign in and Create account
 * lead into the app.
 */

export const NAV_LINKS = [
  { id: 'features', label: 'Features' },
  { id: 'how', label: 'How it works' },
  { id: 'rooms', label: 'Rooms' },
  { id: 'teams', label: 'For schools' },
  { id: 'security', label: 'Security' },
  { id: 'faq', label: 'FAQ' },
  { id: 'contact', label: 'Contact' },
];

export function Brand({ small = false }) {
  return (
    <span className={small ? 'lp-brand lp-brand--small' : 'lp-brand'}>
      <svg className="lp-brand__mark" viewBox="0 0 32 32" aria-hidden="true">
        <rect x="3" y="6" width="26" height="18" rx="4" />
        <path d="M11 29h10M16 24v5" />
        <circle cx="23" cy="11" r="2.4" />
      </svg>
      Classroom
    </span>
  );
}

export default function SiteNav({ signedIn }) {
  const [condensed, setCondensed] = useState(false);
  const [active, setActive] = useState(null);
  const [open, setOpen] = useState(false);
  const [mark, setMark] = useState(null);
  const linksRef = useRef(null);

  // Condense after the first bit of scrolling.
  useEffect(() => {
    const onScroll = () => setCondensed(window.scrollY > 24);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  // Which section is being read: the last one whose top passed a third of the screen.
  useEffect(() => {
    const sections = NAV_LINKS.map((link) => document.getElementById(link.id)).filter(Boolean);
    if (sections.length === 0) return undefined;
    let frame = 0;
    const measure = () => {
      frame = 0;
      const line = window.innerHeight / 3;
      let current = null;
      for (const section of sections) if (section.getBoundingClientRect().top <= line) current = section.id;
      setActive(current);
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', schedule);
    };
  }, []);

  // The highlighter mark follows the active link.
  useLayoutEffect(() => {
    const list = linksRef.current;
    const link = active && list?.querySelector(`[data-section="${active}"]`);
    if (!list || !link) {
      setMark(null);
      return;
    }
    const a = list.getBoundingClientRect();
    const b = link.getBoundingClientRect();
    setMark({ left: b.left - a.left, width: b.width });
  }, [active, condensed]);

  // The sheet closes with Escape, and the page behind it does not scroll.
  useEffect(() => {
    if (!open) return undefined;
    const onKey = (event) => event.key === 'Escape' && setOpen(false);
    document.addEventListener('keydown', onKey);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', onKey);
      document.body.style.overflow = overflow;
    };
  }, [open]);

  return (
    <header className={`lp-nav${condensed ? ' is-condensed' : ''}${open ? ' is-open' : ''}`}>
      <div className="lp-nav__inner">
        <Link to={signedIn ? '/' : '/welcome'} className="lp-nav__home" aria-label="Classroom home" onClick={() => setOpen(false)}>
          <Brand />
        </Link>

        <nav className="lp-nav__links" aria-label="Sections" ref={linksRef}>
          {mark ? <span className="lp-nav__mark" style={{ transform: `translateX(${mark.left}px)`, width: mark.width }} aria-hidden="true" /> : null}
          {NAV_LINKS.map((link) => (
            <a key={link.id} href={`#${link.id}`} data-section={link.id} aria-current={active === link.id ? 'true' : undefined}>
              {link.label}
            </a>
          ))}
        </nav>

        <div className="lp-nav__actions">
          {signedIn ? (
            <Link className="lp-button lp-button--dark lp-button--small" to="/">
              Open Classroom
            </Link>
          ) : (
            <>
              <Link className="lp-nav__signin" to="/login">
                Sign in
              </Link>
              <Link className="lp-button lp-button--dark lp-button--small" to="/signup">
                Create account
              </Link>
            </>
          )}
          <button
            type="button"
            className="lp-nav__menu"
            aria-expanded={open}
            aria-controls="lp-sheet"
            aria-label={open ? 'Close menu' : 'Open menu'}
            onClick={() => setOpen((value) => !value)}
          >
            <span />
            <span />
          </button>
        </div>
      </div>

      <div id="lp-sheet" className="lp-sheet" hidden={!open}>
        <nav aria-label="Sections">
          {NAV_LINKS.map((link, index) => (
            <a key={link.id} href={`#${link.id}`} style={{ '--i': index }} onClick={() => setOpen(false)}>
              {link.label}
            </a>
          ))}
        </nav>
        {signedIn ? null : (
          <div className="lp-sheet__actions">
            <Link className="lp-button lp-button--ghost" to="/login">
              Sign in
            </Link>
            <Link className="lp-button lp-button--primary" to="/signup">
              Create account
            </Link>
          </div>
        )}
      </div>
    </header>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/SiteNav.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/HeroDemo.jsx <<'__LP2_EOF__'
import { useEffect, useRef, useState } from 'react';
import { mmss } from './landingModel.js';
import { prefersReducedMotion } from './motion.js';

/**
 * The homepage's moving picture  (Landing)
 *
 * A miniature of a real lesson, about 22 seconds long:
 *
 *   lobby      the doors count down while three people wait
 *   doors      the doors open
 *   arrivals   four people come in, one after another
 *   teaching   the host speaks
 *   sharing    the host shares slides; the others move to a strip
 *   hand       a learner raises a hand, a question arrives in the chat
 *   reaction   applause floats up
 *   closing    "5 minutes left" with the host's "+10 min"
 *
 * Drawn with HTML and CSS — sharp at every size, nothing to download. Plays
 * only while on screen and while the tab is visible; anyone who prefers
 * reduced motion sees the finished lesson as a still.
 */

const PEOPLE = [
  { name: 'Ms Okafor', initial: 'O', hue: 'sky', host: true },
  { name: 'Jonas', initial: 'J', hue: 'mint' },
  { name: 'Amira', initial: 'A', hue: 'sun' },
  { name: 'Lea', initial: 'L', hue: 'rose' },
];

const SCRIPT = [
  { at: 0, scene: 'lobby' },
  { at: 3800, scene: 'doors' },
  { at: 4800, scene: 'room', joined: 1 },
  { at: 5300, scene: 'room', joined: 2 },
  { at: 5800, scene: 'room', joined: 3 },
  { at: 6300, scene: 'room', joined: 4, speaking: 0 },
  { at: 8200, scene: 'share', joined: 4, speaking: 0, slide: 1 },
  { at: 10400, scene: 'share', joined: 4, speaking: 0, slide: 2 },
  { at: 12400, scene: 'share', joined: 4, speaking: 0, slide: 2, hand: 2 },
  { at: 13600, scene: 'share', joined: 4, speaking: 2, slide: 2, hand: 2, chat: true },
  { at: 15600, scene: 'room', joined: 4, speaking: 2, chat: true, reaction: true },
  { at: 17800, scene: 'room', joined: 4, speaking: 0, chat: true, ending: true },
];
const LOOP_MS = 22000;
const LOBBY_MS = 3800;
const STILL = { scene: 'share', joined: 4, speaking: 0, slide: 2, hand: 2, chat: true };

function Figure() {
  return (
    <div className="lp-tile__figure" aria-hidden="true">
      <span className="lp-tile__head" />
      <span className="lp-tile__body" />
    </div>
  );
}

function Tile({ person, index, speaking, hand, small = false }) {
  return (
    <div
      className={`lp-tile lp-tile--${person.hue}${speaking ? ' is-speaking' : ''}${small ? ' is-small' : ''}`}
      style={{ '--i': index }}
    >
      <Figure />
      {hand ? (
        <span className="lp-tile__hand" aria-hidden="true">
          ✋
        </span>
      ) : null}
      <span className="lp-tile__name">
        {small ? person.name.split(' ').pop() : person.name}
        {person.host && !small ? <span className="lp-tile__role">host</span> : null}
      </span>
    </div>
  );
}

function Slide({ slide }) {
  return (
    <div className="lp-slide" key={slide}>
      {slide === 1 ? (
        <>
          <p className="lp-slide__kicker">Fractions</p>
          <p className="lp-slide__big">½ + ¼ = ?</p>
          <div className="lp-slide__bars" aria-hidden="true">
            <span style={{ width: '50%' }} />
            <span style={{ width: '25%' }} />
          </div>
        </>
      ) : (
        <>
          <p className="lp-slide__kicker">Fractions</p>
          <p className="lp-slide__big">½ + ¼ = ¾</p>
          <div className="lp-slide__bars is-done" aria-hidden="true">
            <span style={{ width: '75%' }} />
          </div>
        </>
      )}
    </div>
  );
}

export default function HeroDemo() {
  const reduced = useRef(prefersReducedMotion());
  const [state, setState] = useState(() => (reduced.current ? STILL : SCRIPT[0]));
  const [countdown, setCountdown] = useState(LOBBY_MS);
  const rootRef = useRef(null);

  useEffect(() => {
    if (reduced.current) return undefined;
    let timers = [];
    let tick = 0;
    let visible = true;
    let running = false;

    const stop = () => {
      timers.forEach((timer) => window.clearTimeout(timer));
      timers = [];
      window.clearInterval(tick);
      running = false;
    };

    const play = () => {
      if (running || !visible || document.hidden) return;
      running = true;
      const began = performance.now();
      setState(SCRIPT[0]);
      SCRIPT.forEach((step) => timers.push(window.setTimeout(() => setState(step), step.at)));
      tick = window.setInterval(() => setCountdown(Math.max(0, LOBBY_MS - (performance.now() - began))), 200);
      timers.push(
        window.setTimeout(() => {
          stop();
          setCountdown(LOBBY_MS);
          play();
        }, LOOP_MS),
      );
    };

    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        if (visible) play();
        else stop();
      },
      { threshold: 0.2 },
    );
    if (rootRef.current) observer.observe(rootRef.current);
    const onVisibility = () => (document.hidden ? stop() : play());
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      stop();
      observer.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, []);

  const inRoom = state.scene === 'room' || state.scene === 'share';
  const joined = state.joined ?? 0;
  const people = PEOPLE.slice(0, joined);

  return (
    <figure
      className="lp-demo"
      ref={rootRef}
      aria-label="A lesson: the doors open, four people join, the teacher shares slides, a learner asks a question."
    >
      <div className="lp-demo__window">
        <div className="lp-demo__bar">
          <span className="lp-demo__dots" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <span className="lp-demo__title">Maths revision</span>
          {inRoom ? (
            <span className={state.ending ? 'lp-demo__clock is-warn' : 'lp-demo__clock'}>
              {state.ending ? 'Closes in 5 min' : 'Live'}
            </span>
          ) : (
            <span className="lp-demo__clock is-quiet">Lobby</span>
          )}
        </div>

        <div className={`lp-demo__stage lp-demo__stage--${state.scene}`}>
          {!inRoom ? (
            <div className="lp-lobby" key="lobby">
              <p className="lp-lobby__label">{state.scene === 'doors' ? 'The doors are open' : 'Doors open in'}</p>
              <p className="lp-lobby__count">{state.scene === 'doors' ? 'Come in' : mmss(countdown)}</p>
              <div className="lp-lobby__waiting" aria-hidden="true">
                {PEOPLE.slice(1).map((person) => (
                  <span key={person.name} className={`lp-dot lp-dot--${person.hue}`}>
                    {person.initial}
                  </span>
                ))}
                <span className="lp-lobby__hint">3 waiting, cameras checked</span>
              </div>
              <span className={state.scene === 'doors' ? 'lp-lobby__button is-ready' : 'lp-lobby__button'}>Enter room</span>
            </div>
          ) : state.scene === 'share' ? (
            <div className="lp-share" key="share">
              <div className="lp-share__main">
                <Slide slide={state.slide} />
                <span className="lp-share__label">Ms Okafor is sharing</span>
              </div>
              <div className="lp-share__strip">
                {people.map((person, index) => (
                  <Tile key={person.name} person={person} index={index} speaking={state.speaking === index} hand={state.hand === index} small />
                ))}
              </div>
            </div>
          ) : (
            <div className="lp-grid" key="grid">
              {people.map((person, index) => (
                <Tile key={person.name} person={person} index={index} speaking={state.speaking === index} hand={state.hand === index} />
              ))}
              {state.reaction ? (
                <span className="lp-reaction" aria-hidden="true">
                  <i>👏</i>
                  <i>👏</i>
                  <i>🎉</i>
                </span>
              ) : null}
            </div>
          )}
        </div>

        <div className="lp-demo__foot">
          <div className={state.chat ? 'lp-chat is-shown' : 'lp-chat'} aria-hidden={!state.chat}>
            <span className="lp-dot lp-dot--sun">A</span>
            <span className="lp-chat__bubble">Why is it ¾ and not ⅔?</span>
          </div>
          <div className="lp-controls" aria-hidden="true">
            <span className="lp-control">Mic</span>
            <span className="lp-control">Camera</span>
            <span className={state.scene === 'share' ? 'lp-control is-on' : 'lp-control'}>Share</span>
            <span className="lp-control lp-control--end">Leave</span>
          </div>
        </div>
      </div>
      {state.ending ? (
        <p className="lp-demo__toast">
          5 minutes left <span className="lp-demo__toast-action">+10 min</span>
        </p>
      ) : null}
      {state.hand !== undefined && state.scene === 'share' ? (
        <p className="lp-demo__note" aria-hidden="true">
          Amira raised her hand
        </p>
      ) : null}
    </figure>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/HeroDemo.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/LessonStory.jsx <<'__LP2_EOF__'
import { useEffect, useRef, useState } from 'react';
import { activeStep } from './landingModel.js';
import { prefersReducedMotion } from './motion.js';

/**
 * "A lesson, start to finish" — the homepage's second big moment  (Landing)
 *
 * The steps scroll past on the left; on the right one screen stays in place
 * and changes with them, the way a product page walks you through a device.
 * Each screen is a small drawing of the real one. On phones the screens sit
 * between the steps instead of beside them.
 */

export const STEPS = [
  {
    id: 'plan',
    title: 'Plan it in a minute',
    text: 'Name, time, how long, how many seats. Pick when the doors open — 3 to 10 minutes before the start — and whether you let people in yourself.',
  },
  {
    id: 'invite',
    title: 'Send one link',
    text: 'Invitations arrive in the app and by email, with reminders a day and ten minutes before. Everyone sees the time in their own time zone, and can add it to their calendar.',
  },
  {
    id: 'doors',
    title: 'The doors open on time',
    text: 'Early arrivals wait in a lobby with a countdown and a camera check. When the room is full, they join a waiting list and get the next free seat.',
  },
  {
    id: 'teach',
    title: 'Teach, and see who needs you',
    text: 'Share your screen, see who is speaking, notice a raised hand. Learners join muted if you want them to, and reactions never interrupt.',
  },
  {
    id: 'talk',
    title: 'Questions have a place',
    text: 'A chat beside the lesson, and a private message when someone needs one — with blocks and read receipts under each person’s own control.',
  },
  {
    id: 'after',
    title: 'The class continues after the call',
    text: 'The room closes on time. Courses, materials and the community space carry on, and the next lesson is one click to plan again.',
  },
];

function Screen({ id }) {
  switch (id) {
    case 'plan':
      return (
        <div className="lp-scr lp-scr--plan">
          <p className="lp-scr__label">New room</p>
          <p className="lp-scr__field">Maths revision</p>
          <div className="lp-scr__row">
            <span className="lp-scr__chip is-on">60 min</span>
            <span className="lp-scr__chip">90 min</span>
            <span className="lp-scr__chip">12 seats</span>
          </div>
          <p className="lp-scr__small">Doors open 5 minutes before the start</p>
          <span className="lp-scr__slider" aria-hidden="true">
            <i />
          </span>
          <span className="lp-scr__cta">Create room</span>
        </div>
      );
    case 'invite':
      return (
        <div className="lp-scr lp-scr--invite">
          <div className="lp-scr__card">
            <p className="lp-scr__small">You are invited</p>
            <p className="lp-scr__title">Maths revision</p>
            <p className="lp-scr__small">Thursday, 16:00–17:00</p>
            <div className="lp-scr__row">
              <span className="lp-scr__zone is-own">16:00 your time</span>
              <span className="lp-scr__zone">15:00 London</span>
              <span className="lp-scr__zone">10:00 New York</span>
            </div>
          </div>
          <p className="lp-scr__link">classroom.app/rooms/kqz-7hfd-2mx</p>
        </div>
      );
    case 'doors':
      return (
        <div className="lp-scr lp-scr--doors">
          <p className="lp-scr__small">Doors open in</p>
          <p className="lp-scr__count">2:47</p>
          <p className="lp-scr__knock">
            <span>Jonas wants to join</span>
            <b>Admit</b>
          </p>
          <p className="lp-scr__small">Waiting list: 2 people</p>
        </div>
      );
    case 'teach':
      return (
        <div className="lp-scr lp-scr--teach">
          <div className="lp-scr__slide">½ + ¼ = ¾</div>
          <div className="lp-scr__strip">
            <i className="is-sky is-speaking" />
            <i className="is-mint" />
            <i className="is-sun has-hand" />
            <i className="is-rose" />
          </div>
        </div>
      );
    case 'talk':
      return (
        <div className="lp-scr lp-scr--talk">
          <p className="lp-scr__msg">Why is it ¾ and not ⅔?</p>
          <p className="lp-scr__msg is-mine">Great question — look at the bars 👀</p>
          <p className="lp-scr__msg is-private">Private: can I stay 5 minutes after class?</p>
          <p className="lp-scr__seen">Seen</p>
        </div>
      );
    default:
      return (
        <div className="lp-scr lp-scr--after">
          {['Fractions', 'Decimals', 'Percentages'].map((name, index) => (
            <p key={name} className={index < 2 ? 'lp-scr__lesson is-done' : 'lp-scr__lesson is-now'}>
              {name}
            </p>
          ))}
          <p className="lp-scr__thread">
            <b>Year 7 maths space</b>
            Notes from today are up 📎
          </p>
        </div>
      );
  }
}

export default function LessonStory() {
  const [active, setActive] = useState(0);
  const stepRefs = useRef([]);

  useEffect(() => {
    let frame = 0;
    const measure = () => {
      frame = 0;
      const tops = stepRefs.current.map((el) => (el ? el.getBoundingClientRect().top : Infinity));
      setActive(activeStep(tops, window.innerHeight * 0.55));
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', schedule);
    };
  }, []);

  const still = prefersReducedMotion();

  return (
    <div className="lp-story">
      <ol className="lp-story__steps">
        {STEPS.map((step, index) => (
          <li
            key={step.id}
            ref={(el) => {
              stepRefs.current[index] = el;
            }}
            className={index === active ? 'lp-story__step is-active' : 'lp-story__step'}
          >
            <span className="lp-story__num" aria-hidden="true">
              {index + 1}
            </span>
            <h3 className="lp-story__title">{step.title}</h3>
            <p className="lp-story__text">{step.text}</p>
            {/* Phones: the screen sits right under its step. */}
            <div className="lp-story__inline" aria-hidden="true">
              <div className="lp-device">
                <Screen id={step.id} />
              </div>
            </div>
          </li>
        ))}
      </ol>

      <div className="lp-story__stage" aria-hidden="true">
        <div className="lp-device lp-device--sticky">
          {STEPS.map((step, index) => (
            <div
              key={step.id}
              className={`lp-device__screen${index === active ? ' is-active' : ''}${index < active ? ' is-past' : ''}${still ? ' is-still' : ''}`}
            >
              <Screen id={step.id} />
            </div>
          ))}
          <span className="lp-device__progress">
            <i style={{ transform: `scaleX(${(active + 1) / STEPS.length})` }} />
          </span>
        </div>
      </div>
    </div>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/LessonStory.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/UseCases.jsx <<'__LP2_EOF__'
import { useLayoutEffect, useRef, useState } from 'react';

/**
 * Who it is for  (Landing)
 *
 * Tabs for four kinds of people, each with what changes for them. A
 * highlighter slides to the chosen tab and the content settles in.
 * Arrow keys move between tabs, as tabs should.
 */

const CASES = [
  {
    id: 'teachers',
    label: 'Teachers',
    title: 'Your lessons, without the admin around them',
    points: [
      'Plan a room once, repeat it weekly, and every date gets its own link',
      'Learners join muted and wait in a lobby until the doors open',
      'Your camera, microphone and sound settings follow you to every lesson',
      'Focus during lessons holds back messages; you get one summary afterwards',
    ],
  },
  {
    id: 'schools',
    label: 'Schools',
    title: 'One place for classes, staff and families',
    points: [
      'Courses, live lessons and community spaces for each class',
      'Clear rules for who may message whom, with blocks that work everywhere',
      'Two-step sign-in and passkeys for staff accounts',
      'Every sign-in and settings change visible to the account owner',
    ],
  },
  {
    id: 'tutors',
    label: 'Tutors and coaches',
    title: 'Small groups that start on time',
    points: [
      'Seat limits with a waiting list, so a full session is not a lost student',
      'Let people in yourself when privacy matters',
      'Share one link; guests see the time in their own time zone',
      'Private messages for the questions people do not ask in front of others',
    ],
  },
  {
    id: 'learners',
    label: 'Learners',
    title: 'Know where to be, and feel safe there',
    points: [
      'Reminders a day and ten minutes before, in the app, by email or push',
      'Quiet hours: nothing buzzes at night unless a lesson is about to start',
      'Decide who can message you, and see what others see of your profile',
      'Download your data, or delete your account, whenever you want',
    ],
  },
];

export default function UseCases() {
  const [active, setActive] = useState(0);
  const [mark, setMark] = useState(null);
  const listRef = useRef(null);
  const tabRefs = useRef([]);

  useLayoutEffect(() => {
    const tab = tabRefs.current[active];
    const list = listRef.current;
    if (!tab || !list) return;
    const a = list.getBoundingClientRect();
    const b = tab.getBoundingClientRect();
    setMark({ left: b.left - a.left, width: b.width });
  }, [active]);

  const onKeyDown = (event) => {
    const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
    if (!step) return;
    event.preventDefault();
    const next = (active + step + CASES.length) % CASES.length;
    setActive(next);
    tabRefs.current[next]?.focus();
  };

  const current = CASES[active];

  return (
    <div className="lp-cases">
      <div className="lp-cases__tabs" role="tablist" aria-label="Who it is for" ref={listRef} onKeyDown={onKeyDown}>
        {mark ? <span className="lp-cases__mark" style={{ transform: `translateX(${mark.left}px)`, width: mark.width }} aria-hidden="true" /> : null}
        {CASES.map((entry, index) => (
          <button
            key={entry.id}
            ref={(el) => {
              tabRefs.current[index] = el;
            }}
            type="button"
            role="tab"
            id={`lp-tab-${entry.id}`}
            aria-selected={index === active}
            aria-controls="lp-case-panel"
            tabIndex={index === active ? 0 : -1}
            className={index === active ? 'lp-cases__tab is-on' : 'lp-cases__tab'}
            onClick={() => setActive(index)}
          >
            {entry.label}
          </button>
        ))}
      </div>
      <div className="lp-cases__panel" id="lp-case-panel" role="tabpanel" aria-labelledby={`lp-tab-${current.id}`} key={current.id}>
        <h3 className="lp-cases__title">{current.title}</h3>
        <ul className="lp-cases__points">
          {current.points.map((point, index) => (
            <li key={point} style={{ '--i': index }}>
              {point}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/UseCases.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/Faq.jsx <<'__LP2_EOF__'
import { useId, useState } from 'react';

/**
 * Questions people ask before signing up  (Landing)
 * An accordion: one answer open at a time, animated open and closed.
 */

export const QUESTIONS = [
  {
    q: 'Do I or my learners need to install anything?',
    a: 'No. Classroom runs in current versions of Chrome, Edge, Firefox and Safari, on computers, tablets and phones. Learners open the link and are in the lobby.',
  },
  {
    q: 'How do the doors work?',
    a: 'Every room has a start and an end. The doors open 3 to 10 minutes before the start — you choose. Until then the link shows a countdown and a camera check. You and your co-hosts can come in 30 minutes early to prepare.',
  },
  {
    q: 'What happens when a room is full?',
    a: 'People can join a waiting list from the lobby. When someone leaves, the next person is told at once and the seat is held for them for two minutes. Hosts and co-hosts always get in.',
  },
  {
    q: 'Can I decide who comes in?',
    a: 'Yes. A room can be for invited people only, or for anyone in your organisation with the link. With “let people in myself”, everyone knocks in the lobby and you admit them one by one or all at once.',
  },
  {
    q: 'Who can send me private messages?',
    a: 'You decide: anyone in your organisation, only people you share a course, space or lesson with, or nobody. Teachers can always reach their learners. A block stops everyone, teachers included.',
  },
  {
    q: 'How is my account protected?',
    a: 'With two-step sign-in (an authenticator app or a passkey), a list of every device that is signed in, a history of sign-ins and changes, and an email whenever something important changes.',
  },
  {
    q: 'Can I take my data with me, or delete my account?',
    a: 'Yes. Settings has a download of everything we keep about you, as one file. Deleting your account gives you 14 days to change your mind; after that your personal data is removed.',
  },
  {
    q: 'Can people outside my organisation join a lesson?',
    a: 'Anyone with the link reaches the lobby and can create an account there. Whether they may enter depends on the room: invited people only, anyone in the organisation with the link, and whether you let people in yourself.',
  },
];

export default function Faq() {
  const [open, setOpen] = useState(0);
  const base = useId();

  return (
    <div className="lp-faq">
      {QUESTIONS.map((entry, index) => {
        const expanded = open === index;
        return (
          <div key={entry.q} className={expanded ? 'lp-faq__item is-open' : 'lp-faq__item'}>
            <h3 className="lp-faq__q">
              <button
                type="button"
                aria-expanded={expanded}
                aria-controls={`${base}-${index}`}
                onClick={() => setOpen(expanded ? -1 : index)}
              >
                {entry.q}
                <span className="lp-faq__icon" aria-hidden="true" />
              </button>
            </h3>
            <div className="lp-faq__a" id={`${base}-${index}`} role="region">
              <div>
                <p>{entry.a}</p>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/Faq.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/ContactForm.jsx <<'__LP2_EOF__'
import { useMemo, useState } from 'react';
import { useCore } from '@classroom/core-client';
import { CONTACT_TOPICS, validateContact } from './landingModel.js';

/**
 * Contact  (Landing)
 *
 * Sent to POST /public/contact, which stores the message and, when
 * CONTACT_EMAIL is set on the server, forwards it by email. A hidden field
 * catches form-filling robots; people never see it.
 */
export default function ContactForm() {
  const { http } = useCore();
  const [form, setForm] = useState({ name: '', email: '', topic: 'school', message: '', website: '' });
  const [touched, setTouched] = useState(false);
  const [state, setState] = useState('idle'); // idle · sending · sent · error
  const [error, setError] = useState(null);

  const errors = useMemo(() => validateContact(form), [form]);
  const shown = touched ? errors : {};
  const set = (field) => (event) => setForm((current) => ({ ...current, [field]: event.target.value }));

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length > 0) return;
    setState('sending');
    setError(null);
    try {
      await http.post(
        '/public/contact',
        { ...form, name: form.name.trim(), email: form.email.trim(), message: form.message.trim() },
        { anonymous: true, retry: { attempts: 1 } },
      );
      setState('sent');
    } catch (cause) {
      setState('error');
      setError(cause?.detail ?? 'Your message was not sent. Check your connection and try again.');
    }
  };

  if (state === 'sent') {
    return (
      <div className="lp-contact__done" role="status">
        <p className="lp-contact__done-title">Thank you, {form.name.split(' ')[0]}.</p>
        <p>Your message is with us. We will answer at {form.email}.</p>
        <button
          type="button"
          className="lp-button lp-button--ghost"
          onClick={() => {
            setForm({ name: form.name, email: form.email, topic: 'question', message: '', website: '' });
            setTouched(false);
            setState('idle');
          }}
        >
          Write another message
        </button>
      </div>
    );
  }

  return (
    <form className="lp-contact__form" onSubmit={submit} noValidate>
      <div className="lp-contact__row">
        <label className="lp-field">
          <span className="lp-field__label">Name</span>
          <input className="lp-input" autoComplete="name" value={form.name} onChange={set('name')} maxLength={100} aria-invalid={Boolean(shown.name)} />
          {shown.name ? <span className="lp-field__error">{shown.name}</span> : null}
        </label>
        <label className="lp-field">
          <span className="lp-field__label">Email</span>
          <input className="lp-input" type="email" autoComplete="email" value={form.email} onChange={set('email')} maxLength={254} aria-invalid={Boolean(shown.email)} />
          {shown.email ? <span className="lp-field__error">{shown.email}</span> : null}
        </label>
      </div>
      <label className="lp-field">
        <span className="lp-field__label">What is it about?</span>
        <select className="lp-input" value={form.topic} onChange={set('topic')}>
          {CONTACT_TOPICS.map((topic) => (
            <option key={topic.value} value={topic.value}>
              {topic.label}
            </option>
          ))}
        </select>
      </label>
      <label className="lp-field">
        <span className="lp-field__label">Message</span>
        <textarea className="lp-input" rows={5} value={form.message} onChange={set('message')} maxLength={4000} aria-invalid={Boolean(shown.message)} />
        {shown.message ? <span className="lp-field__error">{shown.message}</span> : null}
      </label>
      {/* Robots fill every field; people never see this one. */}
      <label className="lp-honeypot" aria-hidden="true">
        Website
        <input tabIndex={-1} autoComplete="off" value={form.website} onChange={set('website')} />
      </label>
      {error ? (
        <p className="lp-field__error" role="alert">
          {error}
        </p>
      ) : null}
      <button type="submit" className="lp-button lp-button--dark" disabled={state === 'sending'}>
        {state === 'sending' ? 'Sending…' : 'Send message'}
      </button>
    </form>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/ContactForm.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/Reveal.jsx <<'__LP2_EOF__'
import { useInView } from './motion.js';

/**
 * Content that settles into place the first time it is scrolled into view.
 * `delay` (ms) staggers siblings; `as` picks the element.
 */
export default function Reveal({ as: Tag = 'div', delay = 0, className = '', children, ...rest }) {
  const [ref, inView] = useInView();
  return (
    <Tag
      ref={ref}
      className={`lp-reveal${inView ? ' is-in' : ''}${className ? ` ${className}` : ''}`}
      style={{ '--lp-delay': `${delay}ms` }}
      {...rest}
    >
      {children}
    </Tag>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/Reveal.jsx"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/motion.js <<'__LP2_EOF__'
import { useEffect, useRef, useState } from 'react';

/**
 * Motion helpers for the homepage  (Landing)
 *
 * One easing and one idea throughout: things arrive from slightly below and
 * slightly out of focus, and settle. Nothing moves for anyone who asked their
 * system for reduced motion — they get the finished state at once.
 */

export const prefersReducedMotion = () =>
  typeof window !== 'undefined' && Boolean(window.matchMedia?.('(prefers-reduced-motion: reduce)').matches);

/** true once the element has come into view (and stays true). */
export function useInView({ threshold = 0.18, rootMargin = '0px 0px -8% 0px' } = {}) {
  const ref = useRef(null);
  const [inView, setInView] = useState(() => prefersReducedMotion());

  useEffect(() => {
    if (inView || !ref.current || typeof IntersectionObserver === 'undefined') {
      if (typeof IntersectionObserver === 'undefined') setInView(true);
      return undefined;
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setInView(true);
          observer.disconnect();
        }
      },
      { threshold, rootMargin },
    );
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, [inView, threshold, rootMargin]);

  return [ref, inView];
}

/**
 * Calls `onFrame(rect, viewportHeight)` once per animation frame while the
 * page scrolls — for effects tied to scroll position. Stops when unmounted.
 */
export function useScrollFrame(ref, onFrame) {
  const callback = useRef(onFrame);
  callback.current = onFrame;

  useEffect(() => {
    if (prefersReducedMotion()) return undefined;
    let frame = 0;
    const run = () => {
      frame = 0;
      if (ref.current) callback.current(ref.current.getBoundingClientRect(), window.innerHeight);
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(run);
    };
    run();
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', schedule);
    };
  }, [ref]);
}
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/motion.js"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/landingModel.js <<'__LP2_EOF__'
/**
 * Pure helpers for the public homepage  (Landing)
 *
 * The room planner on the homepage uses the same rules as the real room
 * editor — doors 3 to 10 minutes before the start, hosts 30 minutes early —
 * so what a visitor tries here is what they get after signing up.
 * No React, no network: tested in __checks__/landingModel.check.mjs.
 */

export const DOORS = Object.freeze({ min: 3, max: 10, default: 5 });
export const HOST_EARLY_MIN = 30;
export const LENGTHS = Object.freeze([30, 45, 60, 90]);

const MINUTE = 60_000;

/** The next full half hour at least 20 minutes from now: a believable example start. */
export const exampleStart = (now = new Date()) => {
  const start = new Date(now.getTime() + 20 * MINUTE);
  start.setSeconds(0, 0);
  start.setMinutes(start.getMinutes() < 30 ? 30 : 60);
  return start;
};

export const clampDoors = (value) =>
  Math.min(DOORS.max, Math.max(DOORS.min, Math.round(Number(value) || DOORS.default)));

/**
 * The moments of one room, and where each sits on a bar from the host's
 * early entry to the end (0–100 %), for the timeline drawing.
 */
export const timelineFor = ({ start, lengthMinutes, doorsMinutes }) => {
  const startsAt = new Date(start).getTime();
  const doors = clampDoors(doorsMinutes);
  const hostAt = startsAt - HOST_EARLY_MIN * MINUTE;
  const doorsAt = startsAt - doors * MINUTE;
  const endsAt = startsAt + lengthMinutes * MINUTE;
  const span = endsAt - hostAt;
  const at = (t) => Math.round(((t - hostAt) / span) * 1000) / 10;
  return {
    hostAt,
    doorsAt,
    startsAt,
    endsAt,
    marks: [
      { id: 'host', label: 'You can open the room', time: hostAt, position: 0 },
      { id: 'doors', label: 'Doors open', time: doorsAt, position: at(doorsAt) },
      { id: 'start', label: 'Lesson starts', time: startsAt, position: at(startsAt) },
      { id: 'end', label: 'Room closes', time: endsAt, position: 100 },
    ],
  };
};

/**
 * A language tag the date formatter accepts, or undefined (the browser's
 * default). Browsers can report tags Intl rejects (e.g. "en-US@posix"), and
 * a throwing formatter would blank the whole homepage.
 */
export const safeLocale = (locale) => {
  try {
    return locale && Intl.DateTimeFormat.supportedLocalesOf([locale]).length ? locale : undefined;
  } catch {
    return undefined;
  }
};

/** A time zone Intl knows, or UTC. */
export const safeZone = (zone) => {
  try {
    new Intl.DateTimeFormat('en', { timeZone: zone });
    return zone || 'UTC';
  } catch {
    return 'UTC';
  }
};

/** "14:30" in a time zone, in the visitor's language. */
export const clock = (time, timeZone, locale) =>
  new Intl.DateTimeFormat(safeLocale(locale), { timeZone: safeZone(timeZone), hour: '2-digit', minute: '2-digit' }).format(
    new Date(time),
  );

/** The weekday offset between two zones at a moment: -1, 0 or +1 ("next day"). */
export const dayShift = (time, fromZone, toZone) => {
  const day = (zone) =>
    new Intl.DateTimeFormat('en-CA', { timeZone: safeZone(zone), year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(time));
  const a = day(fromZone);
  const b = day(toZone);
  return a === b ? 0 : b > a ? 1 : -1;
};

/** Cities shown next to the visitor's own time; the visitor's zone first, no duplicates. */
export const GUEST_ZONES = Object.freeze([
  { zone: 'Europe/London', city: 'London' },
  { zone: 'Europe/Berlin', city: 'Berlin' },
  { zone: 'America/New_York', city: 'New York' },
  { zone: 'Asia/Singapore', city: 'Singapore' },
  { zone: 'Australia/Sydney', city: 'Sydney' },
]);

export const cityOf = (zone) => String(zone || 'UTC').split('/').pop().replace(/_/g, ' ');

export const guestTimes = ({ time, ownZone, locale, count = 3 }) => {
  const seen = new Set();
  const list = [];
  for (const entry of [{ zone: ownZone, city: cityOf(ownZone), own: true }, ...GUEST_ZONES]) {
    const shown = clock(time, entry.zone, locale);
    const key = `${shown}|${dayShift(time, ownZone, entry.zone)}`;
    if (seen.has(entry.zone) || (!entry.own && seen.has(key))) continue;
    seen.add(entry.zone);
    seen.add(key);
    list.push({ ...entry, time: shown, shift: dayShift(time, ownZone, entry.zone) });
    if (list.length === count + 1) break;
  }
  return list;
};

/** "4:59" — minutes and seconds, for the countdown in the demo. */
export const mmss = (ms) => {
  const total = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
};

/** Where the "Create this room" button leads: sign-up first, then the real editor. */
export const plannerNext = '/rooms/new';

// ---------------------------------------------------------------------------
// Contact form
// ---------------------------------------------------------------------------

export const CONTACT_TOPICS = Object.freeze([
  { value: 'school', label: 'Bringing Classroom to my school or team' },
  { value: 'question', label: 'A question about the product' },
  { value: 'support', label: 'Help with my account' },
  { value: 'privacy', label: 'Privacy or data' },
  { value: 'other', label: 'Something else' },
]);

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Problems with the contact form, keyed by field; empty when it can be sent. */
export const validateContact = ({ name, email, topic, message }) => {
  const errors = {};
  if (!String(name ?? '').trim()) errors.name = 'Tell us your name.';
  if (!EMAIL.test(String(email ?? '').trim())) errors.email = 'Enter an email address we can answer to.';
  if (!CONTACT_TOPICS.some((entry) => entry.value === topic)) errors.topic = 'Choose what it is about.';
  const text = String(message ?? '').trim();
  if (text.length < 10) errors.message = 'A few more words, please: at least 10 characters.';
  if (text.length > 4000) errors.message = 'At most 4,000 characters.';
  return errors;
};

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

/** 0 when an element's top reaches the bottom of the viewport, 1 when its middle reaches the middle. */
export const enterProgress = ({ top, height, viewport }) => {
  const start = viewport;
  const end = viewport / 2 - height / 2;
  if (start === end) return 1;
  return Math.min(1, Math.max(0, (start - top) / (start - end)));
};

/** Which step of a sticky story is active: the last one whose top has passed the reading line. */
export const activeStep = (tops, readingLine) => {
  let active = 0;
  tops.forEach((top, index) => {
    if (top <= readingLine) active = index;
  });
  return active;
};
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/landingModel.js"

mkdir -p apps/web/src/components/Landing
cat > apps/web/src/components/Landing/landing.css <<'__LP2_EOF__'
/* Public homepage — see pages/LandingPage.jsx.
 *
 * Light, like a classroom in daylight: a cool paper white, slate ink, and the
 * highlighter yellow of the product. The only dark surfaces are screens — the
 * lesson in the hero, the device in "how it works", the invitation card — so
 * they read as the product, and the page around them stays bright.
 *
 *   paper  #F4F8F7   page          ink    #13262B  text
 *   tint   #EAF2F0   alternate     sun    #FFD54A  calls to action, highlights
 *   white  #FFFFFF   raised        sky    #2E6FD8  links, "live"
 *   board  #15262B   screens       mint   #1E9A77  done, allowed
 *
 * Motion: one easing (expo-out), long and soft. Things arrive from a little
 * below and a little out of focus, and settle. Reduced motion: no movement.
 * Everything is scoped under .lp; the app behind sign-in is untouched.
 */

@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400&family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500..800&display=swap');

.lp {
  --paper: #f4f8f7;
  --tint: #eaf2f0;
  --white: #ffffff;
  --ink: #13262b;
  --ink-2: #3f5559;
  --ink-3: #6b7f82;
  --line: #d8e3e0;
  --board: #15262b;
  --board-2: #1d353b;
  --chalk: #eef2ee;
  --sun: #ffd54a;
  --sun-soft: #fff0b8;
  --sun-ink: #2a2206;
  --sky: #2e6fd8;
  --sky-soft: #e0ecff;
  --mint: #1e9a77;
  --mint-soft: #d6f3e9;
  --live: #ff6b5e;
  --display: 'Bricolage Grotesque', 'Segoe UI', system-ui, sans-serif;
  --body: 'Atkinson Hyperlegible', system-ui, -apple-system, 'Segoe UI', sans-serif;
  --ease: cubic-bezier(0.16, 1, 0.3, 1);
  --max: 1200px;
  --radius: 14px;
  --radius-lg: 24px;
  --shadow: 0 1px 2px rgba(19, 38, 43, 0.06), 0 12px 32px -18px rgba(19, 38, 43, 0.25);
  --shadow-lg: 0 2px 6px rgba(19, 38, 43, 0.06), 0 40px 80px -40px rgba(19, 38, 43, 0.45);

  min-height: 100vh;
  color: var(--ink);
  background: var(--paper);
  font-family: var(--body);
  font-size: 17px;
  line-height: 1.6;
  overflow-x: clip;
  -webkit-font-smoothing: antialiased;
}
html.lp-root { scroll-behavior: smooth; scroll-padding-top: 88px; background: #f4f8f7; }
@media (prefers-reduced-motion: reduce) { html.lp-root { scroll-behavior: auto; } }

.lp *, .lp *::before, .lp *::after { box-sizing: border-box; }
:where(.lp) a { color: inherit; }
.lp :focus-visible { outline: 3px solid var(--sky); outline-offset: 3px; border-radius: 8px; }
.lp ::selection { background: var(--sun); color: var(--sun-ink); }

.lp-skip { position: absolute; left: -999px; top: 10px; z-index: 60; padding: 10px 16px; border-radius: 10px; background: var(--ink); color: #fff; font-weight: 700; }
.lp-skip:focus { left: 12px; }

/* ------------------------------------------------------------ motion */

@keyframes lp-rise { from { transform: translateY(105%); } to { transform: none; } }
@keyframes lp-fade-up { from { opacity: 0; transform: translateY(24px); filter: blur(6px); } to { opacity: 1; transform: none; filter: none; } }

.lp-line { display: block; overflow: hidden; padding-bottom: 0.06em; margin-bottom: -0.06em; }
@media (min-width: 981px) { .lp-line > span { white-space: nowrap; } }
.lp-line > span { display: inline-block; animation: lp-rise 1.15s var(--ease) calc(var(--i) * 110ms + 120ms) both; }
.lp-enter { animation: lp-fade-up 1.1s var(--ease) calc(var(--i) * 110ms + 180ms) both; }

.lp-reveal {
  opacity: 0;
  transform: translateY(36px) scale(0.985);
  filter: blur(8px);
  transition:
    opacity 0.9s var(--ease) var(--lp-delay, 0ms),
    transform 1.1s var(--ease) var(--lp-delay, 0ms),
    filter 0.9s var(--ease) var(--lp-delay, 0ms);
}
.lp-reveal.is-in { opacity: 1; transform: none; filter: none; }

@media (prefers-reduced-motion: reduce) {
  .lp-line > span, .lp-enter { animation: none; }
  .lp-reveal { opacity: 1; transform: none; filter: none; transition: none; }
}

/* ------------------------------------------------------------ buttons */

.lp-button {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  min-height: 50px; padding: 0 26px; border-radius: 999px; border: 1.5px solid transparent;
  font: 700 16px/1 var(--body); text-decoration: none; white-space: nowrap; cursor: pointer;
  transition: transform 0.35s var(--ease), background-color 0.25s ease, border-color 0.25s ease, box-shadow 0.35s var(--ease), color 0.25s ease;
}
.lp-button:active { transform: scale(0.97); }
.lp-button--primary { background: var(--sun); color: var(--sun-ink); box-shadow: 0 8px 22px -10px rgba(214, 160, 0, 0.7); }
.lp-button--primary:hover { background: #ffdd6b; box-shadow: 0 12px 28px -10px rgba(214, 160, 0, 0.8); transform: translateY(-1px); }
.lp-button--dark { background: var(--ink); color: #fff; }
.lp-button--dark:hover { background: #1f3a41; transform: translateY(-1px); }
.lp-button--dark:disabled { opacity: 0.6; cursor: default; transform: none; }
.lp-button--ghost { background: var(--white); color: var(--ink); border-color: var(--line); }
.lp-button--ghost:hover { border-color: var(--ink-3); transform: translateY(-1px); }
.lp-button--text { min-height: 50px; padding: 0 8px; background: none; color: var(--ink); text-decoration: underline; text-decoration-color: var(--sun); text-decoration-thickness: 3px; text-underline-offset: 6px; }
.lp-button--text:hover { text-decoration-color: var(--ink); }
.lp-button--small { min-height: 40px; padding: 0 18px; font-size: 15px; }

/* ------------------------------------------------------------ navigation */

.lp-nav { position: sticky; top: 0; z-index: 40; transition: background-color 0.4s var(--ease), box-shadow 0.4s var(--ease), backdrop-filter 0.4s; }
.lp-nav.is-condensed { background: rgba(244, 248, 247, 0.78); backdrop-filter: blur(18px) saturate(1.6); -webkit-backdrop-filter: blur(18px) saturate(1.6); box-shadow: 0 1px 0 var(--line), 0 10px 30px -24px rgba(19, 38, 43, 0.45); }
.lp-nav__inner { display: flex; align-items: center; gap: 28px; max-width: var(--max); margin: 0 auto; padding: 18px 24px; transition: padding 0.4s var(--ease); }
.lp-nav.is-condensed .lp-nav__inner { padding-top: 11px; padding-bottom: 11px; }
.lp-nav__home { text-decoration: none; }
.lp-brand { display: inline-flex; align-items: center; gap: 10px; font: 780 21px/1 var(--display); letter-spacing: -0.02em; color: var(--ink); }
.lp-brand__mark { width: 28px; height: 28px; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; }
.lp-brand__mark circle { fill: var(--sun); stroke: none; }
.lp-nav__links { position: relative; display: flex; gap: 4px; }
.lp-nav__links a { position: relative; z-index: 1; padding: 8px 12px; border-radius: 999px; font-size: 15px; text-decoration: none; color: var(--ink-2); transition: color 0.25s ease; }
.lp-nav__links a:hover, .lp-nav__links a[aria-current='true'] { color: var(--ink); }
.lp-nav__mark { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 999px; background: var(--sun-soft); transition: transform 0.55s var(--ease), width 0.55s var(--ease); }
.lp-nav__actions { margin-left: auto; display: flex; align-items: center; gap: 14px; }
.lp-nav__signin { font-weight: 700; font-size: 15px; text-decoration: none; padding: 8px 6px; }
.lp-nav__signin:hover { text-decoration: underline; text-decoration-color: var(--sun); text-decoration-thickness: 3px; text-underline-offset: 5px; }
.lp-nav__menu { display: none; width: 44px; height: 44px; border: 0; border-radius: 12px; background: transparent; cursor: pointer; position: relative; }
.lp-nav__menu span { position: absolute; left: 12px; right: 12px; height: 2px; border-radius: 2px; background: var(--ink); transition: transform 0.45s var(--ease); }
.lp-nav__menu span:first-child { top: 17px; }
.lp-nav__menu span:last-child { top: 25px; }
.lp-nav.is-open .lp-nav__menu span:first-child { transform: translateY(4px) rotate(45deg); }
.lp-nav.is-open .lp-nav__menu span:last-child { transform: translateY(-4px) rotate(-45deg); }

.lp-sheet { position: fixed; inset: 64px 0 0; z-index: 39; padding: 20px 24px 40px; background: rgba(244, 248, 247, 0.97); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); overflow-y: auto; }
.lp-sheet[hidden] { display: none; }
.lp-sheet nav { display: grid; }
.lp-sheet nav a { padding: 14px 0; border-bottom: 1px solid var(--line); font: 750 28px/1.1 var(--display); letter-spacing: -0.02em; text-decoration: none; animation: lp-fade-up 0.7s var(--ease) calc(var(--i) * 45ms) both; }
.lp-sheet__actions { display: grid; gap: 10px; margin-top: 28px; }

@media (max-width: 1060px) {
  .lp-nav__links { display: none; }
  .lp-nav__menu { display: inline-block; }
}
@media (max-width: 560px) {
  .lp-nav__inner { gap: 12px; padding: 12px 16px; }
  .lp-nav__signin { display: none; }
  .lp-nav__actions .lp-button { display: none; }
}

/* ------------------------------------------------------------ hero */

.lp-hero { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 56px; align-items: center; max-width: var(--max); margin: 0 auto; padding: 48px 24px 80px; }
.lp-hero__title { margin: 0; font: 800 clamp(42px, 5.8vw, 80px) / 0.98 var(--display); font-variation-settings: 'wdth' 80, 'opsz' 96; letter-spacing: -0.04em; }
.lp-hero__lead { margin: 26px 0 0; max-width: 33em; font-size: 19.5px; color: var(--ink-2); }
.lp-hero__actions { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; margin-top: 34px; }
.lp-hero__assurances { display: flex; flex-wrap: wrap; gap: 8px 20px; margin: 26px 0 0; padding: 0; list-style: none; font-size: 14.5px; color: var(--ink-3); }
.lp-hero__assurances li { display: inline-flex; align-items: center; gap: 8px; }
.lp-hero__assurances li::before { content: ''; width: 16px; height: 16px; border-radius: 50%; background: var(--mint-soft) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4.5 8.2l2.2 2.2 4.8-4.8' fill='none' stroke='%231e9a77' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 16px no-repeat; }
@media (max-width: 980px) {
  .lp-hero { grid-template-columns: 1fr; gap: 48px; padding-top: 24px; }
}

.lp-tilt { transform: perspective(1800px) rotateX(calc(var(--lp-tilt, 0.6) * 9deg)) rotateY(calc(var(--lp-tilt, 0.6) * -6deg)) scale(calc(1 - var(--lp-tilt, 0.6) * 0.03)); transform-origin: 50% 80%; will-change: transform; }
@media (prefers-reduced-motion: reduce), (max-width: 980px) { .lp-tilt { transform: none; } }

/* ------------------------------------------------------------ the demo (a dark screen) */

.lp-demo { position: relative; margin: 0; }
.lp-demo__window { border-radius: var(--radius-lg); background: linear-gradient(180deg, #1f3a41, #172e34); color: var(--chalk); box-shadow: var(--shadow-lg), 0 0 0 1px rgba(19, 38, 43, 0.08); overflow: hidden; }
.lp-demo__bar { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid rgba(238, 242, 238, 0.1); font-size: 14px; }
.lp-demo__dots { display: inline-flex; gap: 6px; }
.lp-demo__dots i { width: 10px; height: 10px; border-radius: 50%; background: rgba(238, 242, 238, 0.2); }
.lp-demo__title { font-weight: 700; }
.lp-demo__clock { margin-left: auto; padding: 3px 10px; border-radius: 999px; font-size: 12.5px; font-weight: 700; background: rgba(255, 107, 94, 0.18); color: #ffb3ab; transition: background-color 0.4s ease, color 0.4s ease; }
.lp-demo__clock::before { content: ''; display: inline-block; width: 7px; height: 7px; margin-right: 6px; border-radius: 50%; background: var(--live); vertical-align: 1px; animation: lp-blink 1.6s ease-in-out infinite; }
.lp-demo__clock.is-warn { background: rgba(255, 213, 74, 0.18); color: var(--sun); }
.lp-demo__clock.is-warn::before { background: var(--sun); }
.lp-demo__clock.is-quiet { background: rgba(238, 242, 238, 0.08); color: rgba(238, 242, 238, 0.7); }
.lp-demo__clock.is-quiet::before { background: rgba(238, 242, 238, 0.5); animation: none; }
@keyframes lp-blink { 50% { opacity: 0.35; } }

.lp-demo__stage { position: relative; aspect-ratio: 16 / 10; padding: 14px; }
.lp-demo__stage > * { animation: lp-scene 0.8s var(--ease) both; }
@keyframes lp-scene { from { opacity: 0; transform: scale(0.97); filter: blur(6px); } to { opacity: 1; transform: none; filter: none; } }

.lp-lobby { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; border-radius: 14px; background: radial-gradient(circle at 50% 35%, rgba(255, 213, 74, 0.1), transparent 62%); text-align: center; }
.lp-lobby__label { margin: 0; color: rgba(238, 242, 238, 0.72); font-size: 15px; }
.lp-lobby__count { margin: 0; font: 800 clamp(46px, 7vw, 76px) / 1 var(--display); font-variant-numeric: tabular-nums; letter-spacing: -0.02em; }
.lp-lobby__waiting { display: flex; align-items: center; gap: 6px; }
.lp-lobby__hint { margin-left: 6px; font-size: 13px; color: rgba(238, 242, 238, 0.55); }
.lp-lobby__button { margin-top: 6px; padding: 10px 22px; border-radius: 999px; font-weight: 700; font-size: 15px; background: rgba(238, 242, 238, 0.08); color: rgba(238, 242, 238, 0.5); transition: background-color 0.5s var(--ease), color 0.5s var(--ease), box-shadow 0.5s var(--ease), transform 0.5s var(--ease); }
.lp-lobby__button.is-ready { background: var(--sun); color: var(--sun-ink); box-shadow: 0 0 0 10px rgba(255, 213, 74, 0.16); transform: scale(1.04); }

.lp-dot { display: inline-grid; place-items: center; width: 30px; height: 30px; border-radius: 50%; font-size: 13px; font-weight: 700; color: #10232a; }
.lp-dot--sky { background: #8cc8ff; }
.lp-dot--mint { background: #7fd6b4; }
.lp-dot--sun { background: var(--sun); }
.lp-dot--rose { background: #ff9fb2; }

.lp-grid { position: relative; height: 100%; display: grid; grid-template-columns: repeat(2, 1fr); grid-auto-rows: 1fr; gap: 10px; }
.lp-tile { position: relative; border-radius: 12px; overflow: hidden; animation: lp-join 0.7s var(--ease) both; box-shadow: inset 0 0 0 2px transparent; transition: box-shadow 0.35s ease; }
.lp-tile--sky { background: linear-gradient(160deg, #2f5f7a, #20465a); }
.lp-tile--mint { background: linear-gradient(160deg, #2e6655, #1f4a3f); }
.lp-tile--sun { background: linear-gradient(160deg, #6f5a23, #4b3d17); }
.lp-tile--rose { background: linear-gradient(160deg, #6b3a49, #4a2833); }
.lp-tile.is-speaking { box-shadow: inset 0 0 0 3px var(--sun); }
.lp-tile__figure { position: absolute; inset: 0; display: grid; place-items: end center; }
.lp-tile__head { position: absolute; top: 24%; width: 26%; aspect-ratio: 1; border-radius: 50%; background: rgba(238, 242, 238, 0.28); }
.lp-tile__body { width: 56%; height: 34%; border-radius: 50% 50% 0 0 / 70% 70% 0 0; background: rgba(238, 242, 238, 0.2); }
.lp-tile__name { position: absolute; left: 8px; bottom: 8px; display: inline-flex; gap: 6px; align-items: center; padding: 3px 8px; border-radius: 6px; background: rgba(10, 20, 23, 0.55); font-size: 12px; font-weight: 700; }
.lp-tile__role { font-weight: 400; color: var(--sun); }
.lp-tile__hand { position: absolute; top: 8px; right: 8px; font-size: 18px; animation: lp-wave 1.2s ease-in-out infinite; transform-origin: 70% 90%; }
.lp-tile.is-small .lp-tile__head { top: 18%; }
.lp-tile.is-small .lp-tile__name { left: 4px; bottom: 4px; padding: 1px 5px; font-size: 10px; }
.lp-tile.is-small .lp-tile__hand { top: 4px; right: 4px; font-size: 14px; }
@keyframes lp-join { from { opacity: 0; transform: scale(0.82) translateY(10px); } to { opacity: 1; transform: none; } }
@keyframes lp-wave { 0%, 100% { transform: rotate(0); } 30% { transform: rotate(14deg); } 60% { transform: rotate(-8deg); } }

.lp-share { height: 100%; display: grid; grid-template-rows: 1fr auto; gap: 10px; }
.lp-share__main { position: relative; border-radius: 12px; background: #f6f9f8; color: var(--ink); overflow: hidden; display: grid; place-items: center; }
.lp-share__label { position: absolute; left: 10px; top: 10px; padding: 3px 8px; border-radius: 6px; background: rgba(19, 38, 43, 0.75); color: #fff; font-size: 11.5px; font-weight: 700; }
.lp-share__strip { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; height: 26%; min-height: 54px; }
.lp-slide { text-align: center; animation: lp-scene 0.7s var(--ease) both; }
.lp-slide__kicker { margin: 0; font-size: 12px; font-weight: 700; color: var(--ink-3); }
.lp-slide__big { margin: 2px 0 10px; font: 800 clamp(26px, 4vw, 44px) / 1 var(--display); letter-spacing: -0.02em; }
.lp-slide__bars { display: flex; gap: 4px; width: min(260px, 80%); margin: 0 auto; height: 14px; border-radius: 7px; background: #e3ebe9; overflow: hidden; }
.lp-slide__bars span { display: block; height: 100%; border-radius: 7px; background: var(--sky); animation: lp-grow 1s var(--ease) both; }
.lp-slide__bars span + span { background: var(--sun); }
.lp-slide__bars.is-done span { background: linear-gradient(90deg, var(--sky) 0 66.6%, var(--sun) 66.6%); }
@keyframes lp-grow { from { transform: scaleX(0); transform-origin: left; } to { transform: scaleX(1); transform-origin: left; } }

.lp-reaction { position: absolute; right: 16%; bottom: 8%; pointer-events: none; }
.lp-reaction i { position: absolute; font-style: normal; font-size: 32px; animation: lp-float 2s var(--ease) both; }
.lp-reaction i:nth-child(2) { left: -44px; animation-delay: 0.25s; font-size: 26px; }
.lp-reaction i:nth-child(3) { left: 30px; animation-delay: 0.5s; font-size: 24px; }
@keyframes lp-float { 0% { opacity: 0; transform: translateY(24px) scale(0.5); } 18% { opacity: 1; transform: translateY(0) scale(1.1); } 100% { opacity: 0; transform: translateY(-150px) scale(0.95); } }

.lp-demo__foot { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 0 14px 14px; min-height: 48px; }
.lp-chat { display: flex; align-items: center; gap: 8px; min-width: 0; opacity: 0; transform: translateY(10px); transition: opacity 0.6s var(--ease), transform 0.6s var(--ease); }
.lp-chat.is-shown { opacity: 1; transform: none; }
.lp-chat .lp-dot { width: 26px; height: 26px; flex: 0 0 auto; font-size: 12px; }
.lp-chat__bubble { padding: 7px 12px; border-radius: 14px 14px 14px 4px; background: rgba(238, 242, 238, 0.12); font-size: 13.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.lp-controls { display: flex; gap: 6px; flex: 0 0 auto; }
.lp-control { padding: 6px 10px; border-radius: 999px; background: rgba(238, 242, 238, 0.08); font-size: 12px; color: rgba(238, 242, 238, 0.72); transition: background-color 0.4s ease, color 0.4s ease; }
.lp-control.is-on { background: rgba(140, 200, 255, 0.25); color: #cfe6ff; }
.lp-control--end { background: rgba(255, 107, 94, 0.2); color: #ffb3ab; }
@media (max-width: 560px) { .lp-controls { display: none; } }

.lp-demo__toast, .lp-demo__note { position: absolute; margin: 0; display: inline-flex; align-items: center; gap: 12px; padding: 10px 14px; border-radius: 14px; background: var(--white); color: var(--ink); font-weight: 700; font-size: 14px; box-shadow: var(--shadow-lg); animation: lp-pop 0.7s var(--ease) both; }
.lp-demo__toast { right: -10px; bottom: -20px; }
.lp-demo__note { left: -14px; top: 64px; }
.lp-demo__note::before { content: '✋'; }
.lp-demo__toast-action { padding: 4px 10px; border-radius: 999px; background: var(--sun); color: var(--sun-ink); }
@keyframes lp-pop { from { opacity: 0; transform: translateY(14px) scale(0.94); } to { opacity: 1; transform: none; } }
@media (max-width: 560px) { .lp-demo__toast { right: 8px; } .lp-demo__note { left: 8px; } }

@media (prefers-reduced-motion: reduce) {
  .lp-demo__stage > *, .lp-tile, .lp-slide, .lp-slide__bars span, .lp-reaction i, .lp-demo__toast, .lp-demo__note, .lp-tile__hand, .lp-demo__clock::before { animation: none; }
}

/* ------------------------------------------------------------ "made for" */

.lp-for { display: flex; flex-wrap: wrap; align-items: center; justify-content: center; gap: 14px 24px; max-width: var(--max); margin: 0 auto; padding: 8px 24px 40px; }
.lp-for__lead { margin: 0; color: var(--ink-3); font-size: 15px; }
.lp-for__list { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px; margin: 0; padding: 0; list-style: none; }
.lp-for__list li { padding: 8px 16px; border-radius: 999px; background: var(--white); border: 1px solid var(--line); font: 700 15px/1 var(--body); color: var(--ink-2); }

/* ------------------------------------------------------------ sections */

.lp-section { max-width: var(--max); margin: 0 auto; padding: 110px 24px; }
.lp-section--tint {
  max-width: none;
  background: var(--tint);
  padding-left: max(24px, calc((100% - var(--max)) / 2 + 24px));
  padding-right: max(24px, calc((100% - var(--max)) / 2 + 24px));
}
.lp-section__head { max-width: 42em; margin-bottom: 56px; }
.lp-section__title { margin: 0; font: 790 clamp(34px, 4.6vw, 58px) / 1.02 var(--display); font-variation-settings: 'wdth' 84; letter-spacing: -0.035em; text-wrap: balance; }
.lp-section__lead { margin: 18px 0 0; font-size: 19.5px; color: var(--ink-2); max-width: 36em; }
.lp-section__lead a { color: var(--sky); font-weight: 700; }
@media (max-width: 720px) { .lp-section { padding: 80px 20px; } .lp-section__head { margin-bottom: 40px; } }

.lp-split { display: grid; grid-template-columns: minmax(0, 0.85fr) minmax(0, 1.15fr); gap: 64px; align-items: start; }
.lp-split__head { position: sticky; top: 110px; margin-bottom: 0; }
@media (max-width: 920px) { .lp-split { grid-template-columns: 1fr; gap: 36px; } .lp-split__head { position: static; } }

/* ------------------------------------------------------------ bento */

.lp-bento { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); grid-auto-rows: minmax(260px, auto); grid-auto-flow: dense; gap: 16px; }
.lp-bento__item { display: flex; flex-direction: column; gap: 8px; padding: 24px; border-radius: var(--radius-lg); background: var(--white); border: 1px solid var(--line); box-shadow: var(--shadow); overflow: hidden; }
.lp-bento__item--wide { grid-column: span 2; }
.lp-bento__item--tall { grid-row: span 2; }
.lp-bento__title { margin: auto 0 0; font: 760 22px/1.15 var(--display); letter-spacing: -0.015em; }
.lp-bento__text { margin: 0; color: var(--ink-2); font-size: 16px; }
.lp-bento__item--rooms { background: var(--board); color: var(--chalk); border-color: transparent; }
.lp-bento__item--rooms .lp-bento__text { color: rgba(238, 242, 238, 0.75); }
@media (max-width: 1000px) { .lp-bento { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 620px) { .lp-bento { grid-template-columns: 1fr; } .lp-bento__item--wide { grid-column: auto; } .lp-bento__item--tall { grid-row: auto; } }

/* Each tile's drawing plays once, when the tile arrives. */
.lp-fa { position: relative; flex: 1 1 auto; min-height: 120px; margin-bottom: 12px; border-radius: 16px; }
.lp-fa--live { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; padding: 14px; background: var(--board); }
.lp-fa--live i { border-radius: 10px; aspect-ratio: 4 / 5; opacity: 0; transform: translateY(12px); transition: opacity 0.7s var(--ease), transform 0.8s var(--ease); }
.lp-fa--live i:nth-child(2) { transition-delay: 0.12s; } .lp-fa--live i:nth-child(3) { transition-delay: 0.24s; } .lp-fa--live i:nth-child(4) { transition-delay: 0.36s; }
.lp-fa--live .is-sky { background: linear-gradient(160deg, #2f5f7a, #20465a); } .lp-fa--live .is-mint { background: linear-gradient(160deg, #2e6655, #1f4a3f); }
.lp-fa--live .is-sun { background: linear-gradient(160deg, #6f5a23, #4b3d17); } .lp-fa--live .is-rose { background: linear-gradient(160deg, #6b3a49, #4a2833); }
.lp-fa--live .is-speaking { box-shadow: inset 0 0 0 3px var(--sun); }
.is-in .lp-fa--live i { opacity: 1; transform: none; }
.lp-fa__float { position: absolute; right: 22px; bottom: 16px; font-size: 26px; opacity: 0; }
.is-in .lp-fa__float { animation: lp-float 2.4s var(--ease) 0.8s both; }

.lp-fa--doors { display: grid; place-items: center; background: radial-gradient(circle at 50% 50%, rgba(255, 213, 74, 0.28), transparent 60%), #0f1d21; overflow: hidden; min-height: 220px; }
.lp-fa__door { position: absolute; top: 0; bottom: 0; width: 50%; background: linear-gradient(180deg, #274850, #1d363c); transition: transform 1.4s var(--ease) 0.5s; }
.lp-fa__door--l { left: 0; border-right: 1px solid rgba(238, 242, 238, 0.15); }
.lp-fa__door--r { right: 0; }
.is-in .lp-fa__door--l { transform: translateX(-86%); }
.is-in .lp-fa__door--r { transform: translateX(86%); }
.lp-fa__count { position: relative; font: 800 56px/1 var(--display); color: var(--sun); font-variant-numeric: tabular-nums; }

.lp-fa--queue { display: flex; align-items: center; justify-content: center; gap: 10px; background: var(--sun-soft); }
.lp-fa--queue span { width: 34px; height: 34px; border-radius: 50%; }
.lp-fa--queue .is-seat { background: var(--ink); }
.lp-fa--queue .is-free { background: transparent; box-shadow: inset 0 0 0 2px var(--ink); transition: background-color 0.6s var(--ease) 1.2s; }
.lp-fa--queue .is-wait { background: #d6b640; opacity: 0.55; transition: transform 1s var(--ease) 1s, opacity 0.6s ease 1s; }
.lp-fa--queue .is-wait:nth-of-type(4) { margin-left: 18px; }
.is-in .lp-fa--queue .is-free { background: var(--mint); }
.is-in .lp-fa--queue .is-wait:nth-of-type(4) { transform: translateX(-62px) scale(0.6); opacity: 0; }

.lp-fa--course { display: grid; align-content: center; gap: 10px; padding: 20px; background: var(--mint-soft); }
.lp-fa--course span { height: 12px; border-radius: 6px; background: rgba(30, 154, 119, 0.18); position: relative; overflow: hidden; }
.lp-fa--course span::after { content: ''; position: absolute; inset: 0; width: var(--w); border-radius: 6px; background: var(--mint); transform: scaleX(0); transform-origin: left; transition: transform 1.2s var(--ease); }
.lp-fa--course span:nth-child(2)::after { transition-delay: 0.2s; } .lp-fa--course span:nth-child(3)::after { transition-delay: 0.4s; }
.is-in .lp-fa--course span::after { transform: scaleX(1); }

.lp-fa--thread { display: grid; align-content: center; gap: 8px; padding: 18px; background: var(--sky-soft); }
.lp-fa--thread span { height: 22px; border-radius: 8px; background: #fff; box-shadow: 0 1px 2px rgba(19, 38, 43, 0.08); opacity: 0; transform: translateY(8px); transition: opacity 0.6s var(--ease), transform 0.7s var(--ease); }
.lp-fa--thread .is-reply { margin-left: 22px; width: calc(100% - 22px); }
.lp-fa--thread span:nth-child(2) { transition-delay: 0.3s; } .lp-fa--thread span:nth-child(3) { transition-delay: 0.6s; }
.is-in .lp-fa--thread span { opacity: 1; transform: none; }

.lp-fa--chat { display: flex; flex-direction: column; justify-content: center; gap: 8px; padding: 18px; background: var(--tint); }
.lp-fa__bubble { align-self: flex-start; max-width: 80%; padding: 9px 14px; border-radius: 16px 16px 16px 4px; background: #fff; font-size: 15px; box-shadow: 0 1px 2px rgba(19, 38, 43, 0.08); opacity: 0; transform: translateY(10px) scale(0.96); transition: opacity 0.6s var(--ease) 0.2s, transform 0.7s var(--ease) 0.2s; }
.lp-fa__bubble.is-mine { align-self: flex-end; border-radius: 16px 16px 4px 16px; background: var(--sky); color: #fff; transition-delay: 0.9s; }
.lp-fa__seen { align-self: flex-end; font-size: 12.5px; color: var(--ink-3); opacity: 0; transition: opacity 0.5s ease 1.5s; }
.is-in .lp-fa__bubble, .is-in .lp-fa__seen { opacity: 1; transform: none; }

.lp-fa--moon { display: grid; place-items: center; background: linear-gradient(180deg, #243f5c, #172a3d); }
.lp-fa__moon { width: 54px; height: 54px; border-radius: 50%; box-shadow: inset -14px -6px 0 0 #f6e6a6; transform: rotate(-20deg) scale(0.6); opacity: 0; transition: transform 1.2s var(--ease), opacity 0.8s ease; }
.lp-fa__z { position: absolute; bottom: 12px; font-size: 13px; color: rgba(238, 242, 238, 0.75); }
.is-in .lp-fa__moon { transform: rotate(-20deg); opacity: 1; }

.lp-fa--zones { display: grid; align-content: center; gap: 8px; padding: 16px; background: var(--sun-soft); }
.lp-fa--zones span { justify-self: start; padding: 6px 12px; border-radius: 999px; background: #fff; font-size: 14px; font-weight: 700; opacity: 0; transform: translateX(-12px); transition: opacity 0.6s var(--ease), transform 0.8s var(--ease); }
.lp-fa--zones span:first-child { background: var(--ink); color: #fff; }
.lp-fa--zones span:nth-child(2) { transition-delay: 0.15s; } .lp-fa--zones span:nth-child(3) { transition-delay: 0.3s; }
.is-in .lp-fa--zones span { opacity: 1; transform: none; }

@media (prefers-reduced-motion: reduce) {
  .lp-fa *, .lp-fa::after, .lp-fa span::after { transition: none !important; animation: none !important; opacity: 1 !important; transform: none !important; }
  .lp-fa__float { display: none; }
}

/* ------------------------------------------------------------ comparison */

.lp-compare { border-radius: var(--radius-lg); background: var(--white); border: 1px solid var(--line); box-shadow: var(--shadow); overflow: hidden; }
.lp-compare__row { display: grid; grid-template-columns: minmax(150px, 0.7fr) minmax(0, 1.3fr) minmax(0, 1fr); gap: 24px; padding: 20px 26px; border-top: 1px solid var(--line); }
.lp-compare__head { border-top: 0; background: var(--paper); font: 750 15px/1.2 var(--body); color: var(--ink-3); padding-top: 16px; padding-bottom: 16px; }
.lp-compare__head span:nth-child(2) { color: var(--ink); }
.lp-compare__topic { font: 750 17px/1.35 var(--display); }
.lp-compare__ours { position: relative; padding-left: 30px; }
.lp-compare__ours::before { content: ''; position: absolute; left: 0; top: 2px; width: 20px; height: 20px; border-radius: 50%; background: var(--mint-soft) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4.5 8.2l2.2 2.2 4.8-4.8' fill='none' stroke='%231e9a77' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 18px no-repeat; }
.lp-compare__theirs { color: var(--ink-3); }
.is-in .lp-compare__row:not(.lp-compare__head) { animation: lp-fade-up 0.9s var(--ease) calc(var(--i, 0) * 70ms + 150ms) both; }
@media (max-width: 760px) {
  .lp-compare__row { grid-template-columns: 1fr; gap: 6px; }
  .lp-compare__head { display: none; }
  .lp-compare__theirs::before { content: 'A meeting link: '; font-weight: 700; }
}
@media (prefers-reduced-motion: reduce) { .is-in .lp-compare__row { animation: none; } }

/* ------------------------------------------------------------ story */

.lp-story { display: grid; grid-template-columns: minmax(0, 0.9fr) minmax(0, 1.1fr); gap: 72px; }
.lp-story__steps { margin: 0; padding: 0; list-style: none; }
.lp-story__step { min-height: 62vh; display: flex; flex-direction: column; justify-content: center; opacity: 0.32; transition: opacity 0.6s var(--ease); }
.lp-story__step.is-active { opacity: 1; }
.lp-story__num { display: inline-grid; place-items: center; width: 36px; height: 36px; margin-bottom: 14px; border-radius: 50%; background: var(--white); border: 1.5px solid var(--line); font-weight: 700; transition: background-color 0.5s var(--ease), border-color 0.5s var(--ease); }
.lp-story__step.is-active .lp-story__num { background: var(--sun); border-color: var(--sun); }
.lp-story__title { margin: 0; font: 780 clamp(26px, 3vw, 38px) / 1.08 var(--display); letter-spacing: -0.025em; }
.lp-story__text { margin: 14px 0 0; font-size: 18px; color: var(--ink-2); max-width: 30em; }
.lp-story__inline { display: none; }
.lp-story__stage { position: relative; }
.lp-device { position: relative; border-radius: 28px; padding: 14px; background: #0f1d21; box-shadow: var(--shadow-lg); }
.lp-device--sticky { position: sticky; top: calc(50vh - 220px); aspect-ratio: 5 / 4.2; }
.lp-device__screen { position: absolute; inset: 14px; border-radius: 18px; overflow: hidden; background: linear-gradient(180deg, #1f3a41, #172e34); color: var(--chalk); opacity: 0; transform: translateY(34px) scale(0.96); filter: blur(10px); transition: opacity 0.8s var(--ease), transform 1s var(--ease), filter 0.8s var(--ease); pointer-events: none; }
.lp-device__screen.is-past { transform: translateY(-26px) scale(0.98); }
.lp-device__screen.is-active { opacity: 1; transform: none; filter: none; }
.lp-device__screen.is-still { transition: none; }
.lp-device__progress { position: absolute; left: 28px; right: 28px; bottom: -22px; height: 4px; border-radius: 2px; background: var(--line); overflow: hidden; }
.lp-device__progress i { display: block; height: 100%; background: var(--ink); transform-origin: left; transition: transform 0.8s var(--ease); }
@media (max-width: 920px) {
  .lp-story { grid-template-columns: 1fr; }
  .lp-story__stage { display: none; }
  .lp-story__step { min-height: 0; padding: 28px 0; opacity: 1; }
  .lp-story__inline { display: block; margin-top: 22px; }
  .lp-story__inline .lp-device { aspect-ratio: 5 / 4; }
  .lp-story__inline .lp-scr { position: absolute; inset: 14px; border-radius: 18px; background: linear-gradient(180deg, #1f3a41, #172e34); color: var(--chalk); }
}
@media (prefers-reduced-motion: reduce) { .lp-device__screen, .lp-story__step, .lp-device__progress i { transition: none; } }

/* The screens inside the device */
.lp-scr { position: relative; height: 100%; padding: 26px; display: flex; flex-direction: column; gap: 12px; font-size: 15px; }
.lp-scr__label { margin: 0; font: 780 22px/1.1 var(--display); }
.lp-scr__field { margin: 0; padding: 12px 14px; border-radius: 12px; background: rgba(238, 242, 238, 0.08); }
.lp-scr__row { display: flex; flex-wrap: wrap; gap: 8px; }
.lp-scr__chip { padding: 6px 12px; border-radius: 999px; background: rgba(238, 242, 238, 0.08); font-size: 14px; }
.lp-scr__chip.is-on { background: var(--chalk); color: var(--ink); font-weight: 700; }
.lp-scr__small { margin: 0; font-size: 14px; color: rgba(238, 242, 238, 0.7); }
.lp-scr__slider { position: relative; height: 6px; border-radius: 3px; background: rgba(238, 242, 238, 0.15); }
.lp-scr__slider i { position: absolute; left: 0; top: 0; bottom: 0; width: 28%; border-radius: 3px; background: var(--sun); }
.lp-scr__slider i::after { content: ''; position: absolute; right: -9px; top: -6px; width: 18px; height: 18px; border-radius: 50%; background: #fff; }
.is-active .lp-scr__slider i { animation: lp-slide 3.2s var(--ease) infinite alternate; }
@keyframes lp-slide { from { width: 28%; } to { width: 72%; } }
.lp-scr__cta { margin-top: auto; align-self: flex-start; padding: 10px 20px; border-radius: 999px; background: var(--sun); color: var(--sun-ink); font-weight: 700; }
.lp-scr--invite { justify-content: center; }
.lp-scr__card { padding: 20px; border-radius: 16px; background: var(--chalk); color: var(--ink); display: grid; gap: 6px; }
.lp-scr__card .lp-scr__small { color: var(--ink-3); }
.lp-scr__title { margin: 0; font: 790 26px/1.1 var(--display); }
.lp-scr__zone { padding: 4px 10px; border-radius: 999px; background: var(--tint); font-size: 13px; }
.lp-scr__zone.is-own { background: var(--ink); color: #fff; }
.lp-scr__link { margin: 0; padding: 10px 14px; border-radius: 12px; background: rgba(238, 242, 238, 0.08); font-size: 13.5px; overflow-wrap: anywhere; }
.lp-scr--doors { align-items: center; justify-content: center; text-align: center; }
.lp-scr__count { margin: 0; font: 800 72px/1 var(--display); font-variant-numeric: tabular-nums; }
.lp-scr__knock { margin: 8px 0 0; width: 100%; display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 10px 12px 10px 16px; border-radius: 12px; background: rgba(238, 242, 238, 0.1); }
.lp-scr__knock b { padding: 6px 14px; border-radius: 999px; background: var(--sun); color: var(--sun-ink); font-size: 14px; }
.is-active .lp-scr__knock { animation: lp-pop 0.8s var(--ease) 0.4s both; }
.lp-scr--teach { gap: 10px; }
.lp-scr__slide { flex: 1; display: grid; place-items: center; border-radius: 14px; background: #f6f9f8; color: var(--ink); font: 800 40px/1 var(--display); }
.lp-scr__strip { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; height: 70px; }
.lp-scr__strip i { border-radius: 10px; position: relative; }
.lp-scr__strip .is-sky { background: linear-gradient(160deg, #2f5f7a, #20465a); } .lp-scr__strip .is-mint { background: linear-gradient(160deg, #2e6655, #1f4a3f); }
.lp-scr__strip .is-sun { background: linear-gradient(160deg, #6f5a23, #4b3d17); } .lp-scr__strip .is-rose { background: linear-gradient(160deg, #6b3a49, #4a2833); }
.lp-scr__strip .is-speaking { box-shadow: inset 0 0 0 3px var(--sun); }
.lp-scr__strip .has-hand::after { content: '✋'; position: absolute; top: 4px; right: 6px; font-size: 16px; font-style: normal; }
.lp-scr--talk { justify-content: center; }
.lp-scr__msg { margin: 0; align-self: flex-start; max-width: 82%; padding: 10px 14px; border-radius: 16px 16px 16px 4px; background: rgba(238, 242, 238, 0.12); }
.lp-scr__msg.is-mine { align-self: flex-end; border-radius: 16px 16px 4px 16px; background: #8cc8ff; color: #0d2233; }
.lp-scr__msg.is-private { background: rgba(255, 213, 74, 0.16); color: var(--sun); }
.is-active .lp-scr__msg { animation: lp-pop 0.7s var(--ease) both; }
.is-active .lp-scr__msg:nth-child(2) { animation-delay: 0.35s; } .is-active .lp-scr__msg:nth-child(3) { animation-delay: 0.7s; }
.lp-scr__seen { margin: 0; align-self: flex-end; font-size: 12.5px; color: rgba(238, 242, 238, 0.5); }
.lp-scr--after { justify-content: center; }
.lp-scr__lesson { margin: 0; display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 12px; background: rgba(238, 242, 238, 0.06); }
.lp-scr__lesson::before { content: ''; width: 18px; height: 18px; border-radius: 50%; border: 2px solid rgba(238, 242, 238, 0.5); }
.lp-scr__lesson.is-done::before { border-color: #7fd6b4; background: #7fd6b4; }
.lp-scr__lesson.is-now { box-shadow: inset 3px 0 0 var(--sun); background: rgba(255, 213, 74, 0.1); }
.lp-scr__thread { margin: 6px 0 0; display: grid; gap: 4px; padding: 14px; border-radius: 12px; background: var(--chalk); color: var(--ink); }
.lp-scr__thread b { font-size: 13px; color: var(--ink-3); }
@media (prefers-reduced-motion: reduce) { .lp-scr * { animation: none !important; } }

/* ------------------------------------------------------------ planner */

.lp-planner { display: grid; grid-template-columns: minmax(0, 0.9fr) minmax(0, 1.1fr); gap: 40px; align-items: start; }
@media (max-width: 920px) { .lp-planner { grid-template-columns: 1fr; } }
.lp-planner__controls { display: grid; gap: 22px; padding: 28px; border-radius: var(--radius-lg); background: var(--white); border: 1px solid var(--line); box-shadow: var(--shadow); }
.lp-field { display: grid; gap: 8px; margin: 0; padding: 0; border: 0; min-width: 0; }
.lp-field__label { font-weight: 700; font-size: 15px; padding: 0; }
.lp-field__label strong { background: var(--sun-soft); padding: 0 6px; border-radius: 6px; }
.lp-field__error { font-size: 14px; color: #b3261e; }
.lp-input { width: 100%; min-height: 48px; padding: 12px 14px; border-radius: var(--radius); border: 1.5px solid var(--line); background: var(--paper); color: var(--ink); font: inherit; transition: border-color 0.25s ease, box-shadow 0.35s var(--ease), background-color 0.25s ease; }
.lp-input:focus { outline: none; border-color: var(--ink); background: #fff; box-shadow: 0 0 0 4px rgba(255, 213, 74, 0.45); }
.lp-input[aria-invalid='true'] { border-color: #d64545; }
textarea.lp-input { resize: vertical; min-height: 120px; }
.lp-pills { display: flex; flex-wrap: wrap; gap: 8px; }
.lp-pill { padding: 10px 16px; border-radius: 999px; border: 1.5px solid var(--line); background: var(--white); color: var(--ink); font: inherit; font-size: 15px; cursor: pointer; transition: background-color 0.3s var(--ease), border-color 0.3s var(--ease), color 0.3s var(--ease); }
.lp-pill.is-on { background: var(--ink); border-color: var(--ink); color: #fff; font-weight: 700; }
.lp-range { width: 100%; accent-color: var(--ink); height: 28px; }
.lp-range__scale { display: flex; justify-content: space-between; font-size: 13px; color: var(--ink-3); margin-top: -4px; }
.lp-stepper { display: inline-flex; align-items: center; justify-self: start; border-radius: 999px; border: 1.5px solid var(--line); background: var(--white); }
.lp-stepper button { width: 46px; height: 46px; border: 0; background: transparent; color: var(--ink); font-size: 22px; cursor: pointer; border-radius: 50%; }
.lp-stepper button:hover { background: var(--tint); }
.lp-stepper output { min-width: 3ch; text-align: center; font: 700 18px/1 var(--body); font-variant-numeric: tabular-nums; }
.lp-segment { display: grid; grid-template-columns: 1fr 1fr; padding: 4px; border-radius: 999px; background: var(--tint); }
.lp-segment button { padding: 10px 12px; border: 0; border-radius: 999px; background: transparent; color: var(--ink-2); font: inherit; font-size: 14.5px; cursor: pointer; transition: background-color 0.35s var(--ease), color 0.35s var(--ease), box-shadow 0.35s var(--ease); }
.lp-segment button.is-on { background: var(--white); color: var(--ink); font-weight: 700; box-shadow: 0 2px 8px -2px rgba(19, 38, 43, 0.2); }
.lp-check { display: flex; align-items: center; gap: 10px; font-size: 15px; cursor: pointer; }
.lp-check input { width: 20px; height: 20px; accent-color: var(--ink); }

.lp-planner__result { display: grid; gap: 26px; justify-items: start; }
.lp-timeline { width: 100%; }
.lp-timeline__track { position: relative; height: 14px; border-radius: 7px; background: #dbe6e3; margin: 12px 0 18px; }
.lp-timeline__early, .lp-timeline__live { position: absolute; top: 0; bottom: 0; transition: left 0.6s var(--ease), width 0.6s var(--ease), right 0.6s var(--ease); }
.lp-timeline__early { background: repeating-linear-gradient(45deg, #ffd54a 0 6px, #ffe38a 6px 12px); }
.lp-timeline__live { background: var(--sky); border-radius: 0 7px 7px 0; }
.lp-timeline__mark { position: absolute; top: -6px; width: 4px; height: 26px; margin-left: -2px; border-radius: 2px; background: var(--ink); transition: left 0.6s var(--ease); }
.lp-timeline__mark--host, .lp-timeline__mark--end { background: var(--ink-3); }
.lp-timeline__legend { margin: 0; padding: 0; list-style: none; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
.lp-legend { display: grid; gap: 2px; font-size: 13.5px; color: var(--ink-3); }
.lp-legend__time { font: 760 21px/1.1 var(--display); color: var(--ink); font-variant-numeric: tabular-nums; }
.lp-legend--doors .lp-legend__time { background: var(--sun-soft); justify-self: start; padding: 0 6px; border-radius: 6px; }
@media (max-width: 560px) { .lp-timeline__legend { grid-template-columns: repeat(2, minmax(0, 1fr)); } }

.lp-invite { width: 100%; padding: 26px; border-radius: var(--radius-lg); background: var(--board); color: var(--chalk); box-shadow: var(--shadow-lg); }
.lp-invite__from { margin: 0; font-size: 14px; color: rgba(238, 242, 238, 0.65); }
.lp-invite__title { margin: 4px 0 0; font: 790 30px/1.1 var(--display); letter-spacing: -0.02em; overflow-wrap: anywhere; }
.lp-invite__when { margin: 6px 0 0; font-weight: 700; }
.lp-invite__facts { margin: 14px 0 0; padding-left: 18px; display: grid; gap: 4px; color: rgba(238, 242, 238, 0.8); }
.lp-invite__zones { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 18px; }
.lp-zone { padding: 6px 12px; border-radius: 999px; background: rgba(238, 242, 238, 0.1); font-size: 14px; }
.lp-zone.is-own { background: var(--sun); color: var(--sun-ink); }
.lp-zone sup { font-size: 10px; }
@media (prefers-reduced-motion: reduce) { .lp-timeline__early, .lp-timeline__live, .lp-timeline__mark { transition: none; } }

/* ------------------------------------------------------------ use cases */

.lp-cases { border-radius: var(--radius-lg); background: var(--white); border: 1px solid var(--line); box-shadow: var(--shadow); padding: 12px; }
.lp-cases__tabs { position: relative; display: flex; gap: 4px; padding: 4px; border-radius: 999px; background: var(--tint); overflow-x: auto; scrollbar-width: none; }
.lp-cases__tab { position: relative; z-index: 1; flex: 1 0 auto; padding: 12px 18px; border: 0; border-radius: 999px; background: transparent; color: var(--ink-2); font: 700 15.5px/1 var(--body); cursor: pointer; white-space: nowrap; transition: color 0.35s ease; }
.lp-cases__tab.is-on { color: var(--ink); }
.lp-cases__mark { position: absolute; left: 0; top: 4px; bottom: 4px; border-radius: 999px; background: var(--white); box-shadow: 0 2px 10px -3px rgba(19, 38, 43, 0.25); transition: transform 0.6s var(--ease), width 0.6s var(--ease); }
.lp-cases__panel { padding: 34px 28px 26px; animation: lp-fade-up 0.8s var(--ease) both; }
.lp-cases__title { margin: 0; font: 780 clamp(24px, 2.6vw, 34px) / 1.1 var(--display); letter-spacing: -0.02em; max-width: 22em; }
.lp-cases__points { margin: 22px 0 0; padding: 0; list-style: none; display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px 32px; }
.lp-cases__points li { position: relative; padding-left: 30px; animation: lp-fade-up 0.8s var(--ease) calc(var(--i) * 70ms + 120ms) both; }
.lp-cases__points li::before { content: ''; position: absolute; left: 0; top: 4px; width: 20px; height: 20px; border-radius: 50%; background: var(--sun-soft) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4.5 8.2l2.2 2.2 4.8-4.8' fill='none' stroke='%2313262b' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 18px no-repeat; }
@media (max-width: 720px) { .lp-cases__points { grid-template-columns: 1fr; } .lp-cases__panel { padding: 26px 14px 16px; } }
@media (prefers-reduced-motion: reduce) { .lp-cases__panel, .lp-cases__points li { animation: none; } .lp-cases__mark { transition: none; } }

/* ------------------------------------------------------------ security */

.lp-checkup { margin-top: 32px; padding: 22px; border-radius: var(--radius-lg); background: var(--white); border: 1px solid var(--line); box-shadow: var(--shadow); display: grid; gap: 10px; }
.lp-checkup__title { margin: 0 0 4px; font: 760 18px/1.2 var(--display); }
.lp-checkup__line { margin: 0; position: relative; padding: 10px 12px 10px 42px; border-radius: 12px; background: var(--paper); font-size: 15px; }
.lp-checkup__line::before { content: ''; position: absolute; left: 12px; top: 50%; width: 20px; height: 20px; margin-top: -10px; border-radius: 50%; background: var(--mint-soft) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4.5 8.2l2.2 2.2 4.8-4.8' fill='none' stroke='%231e9a77' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 18px no-repeat; }
.is-in .lp-checkup__line { animation: lp-fade-up 0.8s var(--ease) both; }
.is-in .lp-checkup__line:nth-child(3) { animation-delay: 0.15s; } .is-in .lp-checkup__line:nth-child(4) { animation-delay: 0.3s; } .is-in .lp-checkup__line:nth-child(5) { animation-delay: 0.45s; }
.lp-facts { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; margin: 0; }
.lp-facts > div { padding: 24px; border-radius: var(--radius-lg); background: var(--white); border: 1px solid var(--line); }
.lp-facts dt { font: 760 20px/1.2 var(--display); letter-spacing: -0.01em; }
.lp-facts dd { margin: 8px 0 0; color: var(--ink-2); }
@media (max-width: 620px) { .lp-facts { grid-template-columns: 1fr; } }
@media (prefers-reduced-motion: reduce) { .is-in .lp-checkup__line { animation: none; } }

/* ------------------------------------------------------------ faq */

.lp-faq { border-top: 1px solid var(--line); }
.lp-faq__item { border-bottom: 1px solid var(--line); }
.lp-faq__q { margin: 0; }
.lp-faq__q button { width: 100%; display: flex; justify-content: space-between; align-items: center; gap: 20px; padding: 22px 0; border: 0; background: none; color: var(--ink); font: 750 19px/1.3 var(--display); text-align: start; cursor: pointer; }
.lp-faq__icon { position: relative; flex: 0 0 auto; width: 30px; height: 30px; border-radius: 50%; background: var(--tint); transition: background-color 0.35s var(--ease), transform 0.5s var(--ease); }
.lp-faq__icon::before, .lp-faq__icon::after { content: ''; position: absolute; left: 9px; right: 9px; top: 14px; height: 2px; border-radius: 1px; background: var(--ink); transition: transform 0.5s var(--ease); }
.lp-faq__icon::after { transform: rotate(90deg); }
.lp-faq__item.is-open .lp-faq__icon { background: var(--sun); transform: rotate(180deg); }
.lp-faq__item.is-open .lp-faq__icon::after { transform: rotate(0); }
.lp-faq__a { display: grid; grid-template-rows: 0fr; transition: grid-template-rows 0.6s var(--ease); }
.lp-faq__a > div { overflow: hidden; }
.lp-faq__a p { margin: 0; padding: 0 48px 24px 0; color: var(--ink-2); opacity: 0; transform: translateY(-6px); transition: opacity 0.5s var(--ease), transform 0.6s var(--ease); }
.lp-faq__item.is-open .lp-faq__a { grid-template-rows: 1fr; }
.lp-faq__item.is-open .lp-faq__a p { opacity: 1; transform: none; }
@media (prefers-reduced-motion: reduce) { .lp-faq__a, .lp-faq__a p, .lp-faq__icon, .lp-faq__icon::after { transition: none; } }

/* ------------------------------------------------------------ contact */

.lp-contact { padding: 30px; border-radius: var(--radius-lg); background: var(--white); border: 1px solid var(--line); box-shadow: var(--shadow); }
.lp-contact__form { display: grid; gap: 18px; }
.lp-contact__form .lp-button { justify-self: start; }
.lp-contact__row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
@media (max-width: 620px) { .lp-contact__row { grid-template-columns: 1fr; } .lp-contact { padding: 22px; } }
.lp-contact__notes { margin: 26px 0 0; padding: 0; list-style: none; display: grid; gap: 10px; color: var(--ink-2); }
.lp-contact__notes li { padding-left: 18px; position: relative; }
.lp-contact__notes li::before { content: ''; position: absolute; left: 0; top: 0.65em; width: 8px; height: 8px; border-radius: 50%; background: var(--sun); }
.lp-contact__done { display: grid; gap: 10px; justify-items: start; animation: lp-fade-up 0.8s var(--ease) both; }
.lp-contact__done-title { margin: 0; font: 790 30px/1.1 var(--display); }
.lp-contact__done p { margin: 0; }
.lp-honeypot { position: absolute; left: -10000px; width: 1px; height: 1px; overflow: hidden; }

/* ------------------------------------------------------------ closing */

.lp-final { max-width: var(--max); margin: 0 auto; padding: 120px 24px; text-align: center; display: grid; justify-items: center; gap: 18px; }
.lp-final__title { margin: 0; font: 800 clamp(38px, 6vw, 76px) / 1 var(--display); font-variation-settings: 'wdth' 80; letter-spacing: -0.04em; max-width: 15ch; text-wrap: balance; }
.lp-final__lead { margin: 0; font-size: 19px; color: var(--ink-2); }
.lp-final .lp-hero__actions { justify-content: center; margin-top: 12px; }

.lp-footer { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 2fr); gap: 32px 56px; max-width: var(--max); margin: 0 auto; padding: 48px 24px 40px; border-top: 1px solid var(--line); color: var(--ink-2); }
.lp-footer__brand p { margin: 12px 0 0; max-width: 22em; }
.lp-footer__cols { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 24px; }
.lp-footer__cols div { display: grid; gap: 10px; align-content: start; }
.lp-footer__head { margin: 0 0 4px; font-weight: 700; color: var(--ink); }
.lp-footer__cols a { text-decoration: none; font-size: 15px; }
.lp-footer__cols a:hover { color: var(--ink); text-decoration: underline; text-decoration-color: var(--sun); text-decoration-thickness: 3px; text-underline-offset: 5px; }
.lp-footer__small { grid-column: 1 / -1; margin: 12px 0 0; font-size: 14px; color: var(--ink-3); }
@media (max-width: 860px) { .lp-footer { grid-template-columns: 1fr; } .lp-footer__cols { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/landing.css"

mkdir -p apps/web/src/components/Landing/__checks__
cat > apps/web/src/components/Landing/__checks__/landingModel.check.mjs <<'__LP2_EOF__'
// Landing — the homepage's room planner and redirects.
// Run: node --test apps/web/src/components/Landing/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { clampDoors, clock, dayShift, exampleStart, guestTimes, mmss, safeLocale, timelineFor } from '../landingModel.js';

test('doors stay between 3 and 10 minutes, like the real room editor', () => {
  assert.equal(clampDoors(1), 3);
  assert.equal(clampDoors(12), 10);
  assert.equal(clampDoors('7'), 7);
  assert.equal(clampDoors(undefined), 5);
});

test('the example start is the next half hour at least 20 minutes away', () => {
  assert.equal(exampleStart(new Date('2026-03-10T10:05:00Z')).toISOString(), '2026-03-10T10:30:00.000Z');
  assert.equal(exampleStart(new Date('2026-03-10T10:20:00Z')).toISOString(), '2026-03-10T11:00:00.000Z');
});

test('the timeline puts every moment on the bar', () => {
  const t = timelineFor({ start: '2026-03-10T10:00:00Z', lengthMinutes: 60, doorsMinutes: 5 });
  assert.deepEqual(t.marks.map((m) => m.id), ['host', 'doors', 'start', 'end']);
  assert.equal(t.marks[0].position, 0);
  assert.equal(t.marks[3].position, 100);
  // 25 of 90 minutes, 30 of 90 minutes
  assert.equal(t.marks[1].position, 27.8);
  assert.equal(t.marks[2].position, 33.3);
  assert.equal(t.doorsAt, Date.parse('2026-03-10T09:55:00Z'));
});

test('guest times: own zone first, other cities, next-day marked', () => {
  const list = guestTimes({ time: '2026-03-10T22:00:00Z', ownZone: 'Europe/Berlin', locale: 'en-GB', count: 3 });
  assert.equal(list[0].own, true);
  assert.equal(list[0].time, '23:00');
  assert.equal(list.length, 4);
  assert.ok(list.every((entry, i) => i === 0 || !entry.own));
  const sydney = guestTimes({ time: '2026-03-10T22:00:00Z', ownZone: 'Europe/Berlin', locale: 'en-GB', count: 5 }).find((e) => e.city === 'Sydney');
  assert.equal(sydney.shift, 1);
  assert.equal(dayShift('2026-03-10T22:00:00Z', 'Europe/Berlin', 'America/New_York'), 0);
});

test('countdown', () => {
  assert.equal(mmss(299_001), '5:00');
  assert.equal(mmss(61_000), '1:01');
  assert.equal(mmss(-5), '0:00');
});

test('odd browser languages and zones never break the page', () => {
  assert.equal(safeLocale('en-US@posix'), undefined);
  assert.equal(safeLocale('de-DE'), 'de-DE');
  assert.equal(safeLocale(undefined), undefined);
  assert.match(clock('2026-03-10T10:00:00Z', 'Not/AZone', 'en-US@posix'), /\d{1,2}[:.]\d{2}/);
  assert.equal(guestTimes({ time: '2026-03-10T10:00:00Z', ownZone: 'UTC', locale: 'en-US@posix', count: 3 }).length, 4);
});

import { activeStep, enterProgress, validateContact } from '../landingModel.js';

test('contact form validation', () => {
  const good = { name: 'Anna', email: 'anna@example.com', topic: 'school', message: 'We have 40 teachers and would like a demo.' };
  assert.deepEqual(validateContact(good), {});
  const bad = validateContact({ name: '', email: 'x', topic: 'spam', message: 'hi' });
  assert.deepEqual(Object.keys(bad).sort(), ['email', 'message', 'name', 'topic']);
  assert.ok(validateContact({ ...good, message: 'x'.repeat(4001) }).message);
});

test('scroll progress and the active story step', () => {
  assert.equal(enterProgress({ top: 900, height: 200, viewport: 900 }), 0);
  assert.equal(enterProgress({ top: 350, height: 200, viewport: 900 }), 1);
  assert.equal(enterProgress({ top: 625, height: 200, viewport: 900 }), 0.5);
  assert.equal(activeStep([100, 500, 900], 450), 0);
  assert.equal(activeStep([-200, 300, 900], 450), 1);
  assert.equal(activeStep([-900, -500, -100], 450), 2);
});
__LP2_EOF__
echo "wrote apps/web/src/components/Landing/__checks__/landingModel.check.mjs"

mkdir -p apps/web/src/components/Auth
cat > apps/web/src/components/Auth/auth.css <<'__LP2_EOF__'
/* Sign-in and sign-up — see components/Auth/AuthShell.jsx.
   Same palette and type as the homepage (components/Landing/landing.css):
   a light page for the form, and the slate board as the one dark panel. */

@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500..800&display=swap');

.au {
  --au-board: #15262b;
  --au-board-2: #1d353b;
  --au-board-3: #26444b;
  --au-chalk: #eef2ee;
  --au-chalk-2: rgba(238, 242, 238, 0.72);
  --au-chalk-3: rgba(238, 242, 238, 0.5);
  --au-sun: #ffd54a;
  --au-sun-ink: #2a2206;
  --au-sky: #8cc8ff;
  --au-danger: #b3261e;
  --au-paper: #f4f8f7;
  --au-white: #ffffff;
  --au-ink: #13262b;
  --au-ink-2: #3f5559;
  --au-ink-3: #6b7f82;
  --au-line: #d8e3e0;
  --au-display: 'Bricolage Grotesque', 'Segoe UI', system-ui, sans-serif;
  --au-body: 'Atkinson Hyperlegible', system-ui, -apple-system, 'Segoe UI', sans-serif;

  min-height: 100vh;
  display: grid;
  grid-template-columns: minmax(320px, 0.9fr) minmax(0, 1.1fr);
  background: var(--au-paper);
  color: var(--au-ink);
  font-family: var(--au-body);
  font-size: 16.5px;
  line-height: 1.55;
}
.au :focus-visible { outline: 3px solid #2e6fd8; outline-offset: 2px; border-radius: 6px; }
:where(.au) a { color: #2e6fd8; }

.au-board {
  position: relative; display: flex; flex-direction: column; justify-content: space-between; gap: 32px;
  padding: 32px 40px 40px;
  background:
    radial-gradient(700px 400px at 20% 110%, rgba(255, 213, 74, 0.12), transparent 60%),
    radial-gradient(600px 400px at 110% -10%, rgba(140, 200, 255, 0.12), transparent 60%),
    var(--au-board-2);
  color: var(--au-chalk);
  overflow: hidden;
}
.au-brand { display: inline-flex; align-items: center; gap: 10px; color: var(--au-chalk) !important; text-decoration: none; font: 750 20px/1 var(--au-display); }
.au-brand__mark { width: 28px; height: 28px; fill: none; stroke: var(--au-chalk); stroke-width: 2.2; stroke-linecap: round; }
.au-brand__mark circle { fill: var(--au-sun); stroke: none; }
.au-board__art { align-self: center; text-align: center; }
.au-board__big { margin: 0; color: var(--au-chalk-2); }
.au-board__count { margin: 0; font: 800 clamp(64px, 9vw, 120px) / 1 var(--au-display); font-variation-settings: 'wdth' 80; letter-spacing: -0.03em; font-variant-numeric: tabular-nums; }
.au-board__track { display: block; width: min(280px, 70%); height: 10px; margin: 18px auto 0; border-radius: 5px; background: rgba(238, 242, 238, 0.12); overflow: hidden; }
.au-board__track i { display: block; width: 72%; height: 100%; border-radius: 5px; background: repeating-linear-gradient(45deg, rgba(255, 213, 74, 0.8) 0 6px, rgba(255, 213, 74, 0.5) 6px 12px); }
.au-board__line { margin: 0; max-width: 24em; font: 700 22px/1.3 var(--au-display); letter-spacing: -0.01em; }

.au-main { color: var(--au-ink); display: flex; flex-direction: column; justify-content: center; align-items: center; gap: 20px; padding: 48px 24px; }
.au-card { width: 100%; max-width: 420px; }
.au-title { margin: 0; font: 800 clamp(32px, 4vw, 44px) / 1.05 var(--au-display); letter-spacing: -0.03em; }
.au-lead { margin: 10px 0 0; color: var(--au-ink-2); }
.au-footer { width: 100%; max-width: 420px; color: var(--au-ink-2); font-size: 15px; }
.au-footer p { margin: 6px 0; }

.au-form { display: grid; gap: 16px; margin-top: 28px; }
.au-field { display: grid; gap: 6px; }
.au-label { font-weight: 700; font-size: 15px; }
.au-hint { font-size: 13.5px; color: var(--au-ink-3); }
.au-input-wrap { position: relative; }
.au-input {
  width: 100%; box-sizing: border-box; min-height: 48px; padding: 12px 14px; border-radius: 12px;
  border: 1.5px solid var(--au-line); background: var(--au-white); color: var(--au-ink); font: inherit;
  transition: border-color 0.25s ease, box-shadow 0.35s cubic-bezier(0.16, 1, 0.3, 1);
}
.au-input:focus { border-color: var(--au-ink); outline: none; box-shadow: 0 0 0 4px rgba(255, 213, 74, 0.45); }
.au-input[aria-invalid='true'] { border-color: var(--au-danger); }
.au-input--code { font-size: 22px; letter-spacing: 0.25em; text-align: center; }
.au-reveal { position: absolute; right: 8px; top: 50%; transform: translateY(-50%); padding: 6px 10px; border: 0; border-radius: 8px; background: transparent; color: var(--au-ink-2); font: inherit; font-size: 14px; cursor: pointer; }
.au-reveal:hover { color: var(--au-ink); background: #eaf2f0; }

.au-meter { display: flex; gap: 4px; margin-top: 2px; }
.au-meter i { flex: 1; height: 5px; border-radius: 3px; background: #dbe6e3; transition: background-color 0.3s ease; }
.au-meter[data-level='1'] i:nth-child(-n + 1) { background: #e0584f; }
.au-meter[data-level='2'] i:nth-child(-n + 2) { background: #e8b400; }
.au-meter[data-level='3'] i:nth-child(-n + 3) { background: #6bb84a; }
.au-meter[data-level='4'] i { background: #1e9a77; }

.au-button {
  display: inline-flex; align-items: center; justify-content: center; min-height: 50px; padding: 0 22px;
  border: 2px solid transparent; border-radius: 999px; font: 700 16px/1 var(--au-body); cursor: pointer; text-decoration: none;
}
.au-button { transition: transform 0.35s cubic-bezier(0.16, 1, 0.3, 1), background-color 0.25s ease, border-color 0.25s ease; }
.au-button:active:not(:disabled) { transform: scale(0.98); }
.au-button--primary { background: var(--au-sun); color: var(--au-sun-ink); box-shadow: 0 8px 22px -10px rgba(214, 160, 0, 0.7); }
.au-button--primary:hover { background: #ffe07a; }
.au-button--primary:disabled { opacity: 0.6; cursor: default; }
.au-button--ghost { background: var(--au-white); color: var(--au-ink); border-color: var(--au-line); }
.au-button--ghost:hover { border-color: var(--au-ink-3); }
.au-textbutton { justify-self: start; padding: 0; border: 0; background: none; color: #2e6fd8; font: inherit; font-size: 15px; cursor: pointer; text-decoration: underline; text-underline-offset: 3px; }

.au-or { display: flex; align-items: center; gap: 12px; color: var(--au-ink-3); font-size: 14px; }
.au-or::before, .au-or::after { content: ''; flex: 1; height: 1px; background: var(--au-line); }

.au-alert { margin: 0; padding: 12px 14px; border-radius: 12px; font-size: 15px; }
.au-alert--error { background: #fde8e6; color: #8c1d18; }
.au-alert--info { background: #e0ecff; color: #173a73; }

@media (max-width: 860px) {
  .au { grid-template-columns: 1fr; }
  .au-board { flex-direction: row; align-items: center; padding: 18px 20px; }
  .au-board__art { display: none; }
  .au-board__line { display: none; }
  .au-main { justify-content: flex-start; padding-top: 36px; }
}
@media (prefers-reduced-motion: reduce) { .au-meter i { transition: none; } }

.au-card, .au-footer { animation: au-in 0.9s cubic-bezier(0.16, 1, 0.3, 1) both; }
.au-footer { animation-delay: 0.12s; }
@keyframes au-in { from { opacity: 0; transform: translateY(18px); filter: blur(6px); } to { opacity: 1; transform: none; filter: none; } }
@media (prefers-reduced-motion: reduce) { .au-card, .au-footer { animation: none; } .au-button, .au-input { transition: none; } }
__LP2_EOF__
echo "wrote apps/web/src/components/Auth/auth.css"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/AppHeader.jsx <<'__LP2_EOF__'
import { Link, NavLink } from 'react-router-dom';
import { useCore } from '@classroom/core-client';

/**
 * The app's top bar  (Design)
 *
 * The same five places as before — Dashboard, Community, Messages, Media,
 * Settings — with an icon each, a soft pill for the page you are on, and your
 * name on the right as the way to your settings. Purely presentation: every
 * link goes where it always went.
 */

const ICONS = {
  home: 'M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z',
  community: 'M8 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm8 0a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM2 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5M14.5 15c.5-.3 1-.5 1.5-.5 3.3 0 6 2.2 6 5.5',
  messages: 'M4 5h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9l-5 4V6a1 1 0 0 1 1-1z',
  media: 'M4 5h16v14H4zM4 15l5-5 4 4 3-3 4 4',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 13a7.6 7.6 0 0 0 0-2l2-1.6-2-3.4-2.4 1a7.7 7.7 0 0 0-1.7-1L15 3h-4l-.4 2.6a7.7 7.7 0 0 0-1.7 1l-2.4-1-2 3.4 2 1.6a7.6 7.6 0 0 0 0 2l-2 1.6 2 3.4 2.4-1a7.7 7.7 0 0 0 1.7 1L11 21h4l.4-2.6a7.7 7.7 0 0 0 1.7-1l2.4 1 2-3.4z',
};

const LINKS = [
  { to: '/', label: 'Dashboard', icon: 'home', end: true },
  { to: '/community', label: 'Community', icon: 'community' },
  { to: '/messages', label: 'Messages', icon: 'messages' },
  { to: '/media', label: 'Media', icon: 'media' },
  { to: '/settings', label: 'Settings', icon: 'settings' },
];

function Icon({ name }) {
  return (
    <svg className="app__icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={ICONS[name]} />
    </svg>
  );
}

export default function AppHeader() {
  const { session } = useCore();
  const name = session?.displayName ?? '';
  const initial = name.trim().charAt(0).toUpperCase() || '·';

  return (
    <header className="app__bar">
      <Link to="/" className="app__brand" aria-label="Classroom, dashboard">
        <svg className="app__mark" viewBox="0 0 32 32" aria-hidden="true">
          <rect x="3" y="6" width="26" height="18" rx="4" />
          <path d="M11 29h10M16 24v5" />
          <circle cx="23" cy="11" r="2.4" />
        </svg>
        <span className="app__brand-text">Classroom</span>
      </Link>

      <nav className="app__nav" aria-label="Main">
        {LINKS.map((link) => (
          <NavLink key={link.to} to={link.to} end={link.end}>
            <Icon name={link.icon} />
            <span className="app__nav-label">{link.label}</span>
          </NavLink>
        ))}
      </nav>

      <Link to="/settings/profile" className="app__me" title="Your profile and settings">
        <span className="app__avatar" aria-hidden="true">
          {initial}
        </span>
        <span className="app__me-name">{name}</span>
      </Link>
    </header>
  );
}
__LP2_EOF__
echo "wrote apps/web/src/components/system/AppHeader.jsx"

mkdir -p apps/web/src/styles
cat > apps/web/src/styles/theme.css <<'__LP2_EOF__'
/* The app behind sign-in: "evening" theme  (Design)
 *
 * Calmer and lighter than before — a soft slate-teal instead of near-black,
 * gentle light from two corners, rounder surfaces, one warm accent — so the
 * app feels like a quiet room rather than a control panel.
 *
 * Only presentation, and only inside .app (AppLayout): the classroom, room
 * lobbies, sign-in and the homepage are not affected. It works by redefining
 * the same colour variables app.css and every page already use, so no
 * component changes and nothing about chat, calls or data is touched.
 *
 * Still a dark-leaning theme on purpose: some pages (chat, community, media)
 * set light text of their own, and must stay readable.
 */

@import url('https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400&family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,500..800&display=swap');

.app {
  --color-bg: #20363c;
  --color-surface: #27434a;
  --color-surface-2: #2f4f57;
  --color-border: rgba(214, 232, 227, 0.13);
  --color-text: #eef4f2;
  --color-muted: #a8bcb9;
  --color-accent: #5a7bf2;
  --color-danger: #e5484d;
  --app-sun: #ffd54a;
  --app-sun-ink: #2a2206;
  --app-ease: cubic-bezier(0.16, 1, 0.3, 1);
  --app-radius: 16px;
  --app-shadow: 0 1px 2px rgba(0, 0, 0, 0.12), 0 18px 40px -28px rgba(0, 0, 0, 0.55);
  --font-sans: 'Atkinson Hyperlegible', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;

  position: relative;
  min-height: 100vh;
  color: var(--color-text);
  font-family: var(--font-sans);
  background:
    radial-gradient(1100px 620px at 92% -8%, rgba(140, 200, 255, 0.11), transparent 62%),
    radial-gradient(900px 520px at -8% 108%, rgba(255, 213, 74, 0.075), transparent 60%),
    var(--color-bg);
  background-attachment: fixed;
  -webkit-font-smoothing: antialiased;
}

.app ::selection { background: var(--app-sun); color: var(--app-sun-ink); }
.app :focus-visible { outline: 3px solid var(--app-sun); outline-offset: 2px; border-radius: 8px; }

/* ------------------------------------------------------------ top bar */

.app .app__bar {
  position: sticky;
  top: 0;
  z-index: 30;
  display: flex;
  align-items: center;
  gap: 18px;
  padding: 10px max(20px, calc((100% - 1280px) / 2));
  border-bottom: 1px solid var(--color-border);
  background: rgba(32, 54, 60, 0.74);
  backdrop-filter: blur(16px) saturate(1.4);
  -webkit-backdrop-filter: blur(16px) saturate(1.4);
}
.app .app__brand { display: inline-flex; align-items: center; gap: 9px; color: var(--color-text); text-decoration: none; font: 780 19px/1 'Bricolage Grotesque', var(--font-sans); letter-spacing: -0.02em; }
.app .app__mark { width: 26px; height: 26px; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; }
.app .app__mark circle { fill: var(--app-sun); stroke: none; }

.app .app__nav { display: flex; gap: 4px; margin: 0 auto; padding: 4px; border-radius: 999px; background: rgba(238, 242, 238, 0.05); font-size: 14.5px; }
.app .app__nav a {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 8px 14px; border-radius: 999px;
  color: var(--color-muted); text-decoration: none;
  transition: background-color 0.35s var(--app-ease), color 0.25s ease;
}
.app .app__nav a:hover { color: var(--color-text); background: rgba(238, 242, 238, 0.06); }
.app .app__nav a.active { color: var(--color-text); background: rgba(238, 242, 238, 0.12); box-shadow: inset 0 0 0 1px rgba(238, 242, 238, 0.08); }
.app .app__icon { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
.app .app__nav a.active .app__icon { stroke: var(--app-sun); }

.app .app__me { display: inline-flex; align-items: center; gap: 10px; padding: 4px 12px 4px 4px; border-radius: 999px; color: var(--color-text); text-decoration: none; transition: background-color 0.3s var(--app-ease); }
.app .app__me:hover { background: rgba(238, 242, 238, 0.07); }
.app .app__avatar { display: grid; place-items: center; width: 32px; height: 32px; border-radius: 50%; background: linear-gradient(135deg, #ffd54a, #f2a93b); color: var(--app-sun-ink); font-weight: 700; font-size: 14px; }
.app .app__me-name { max-width: 14ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14.5px; }

@media (max-width: 980px) {
  .app .app__me-name { display: none; }
  .app .app__me { padding-right: 4px; }
}
@media (max-width: 760px) {
  .app .app__bar { gap: 10px; padding: 8px 12px; }
  .app .app__brand-text { display: none; }
  .app .app__nav { margin: 0; flex: 1; justify-content: space-between; }
  .app .app__nav-label { display: none; }
  .app .app__nav a { padding: 10px 12px; }
}

/* ------------------------------------------------------------ pages */

.app .app__content { max-width: 1280px; margin: 0 auto; padding: 28px 20px 64px; }
.app .page { animation: app-in 0.6s var(--app-ease) both; }
@keyframes app-in { from { opacity: 0; transform: translateY(14px); } to { opacity: 1; transform: none; } }

.app .app__content h1 { font-family: 'Bricolage Grotesque', var(--font-sans); font-weight: 780; letter-spacing: -0.025em; }
.app .app__content h2 { font-family: 'Bricolage Grotesque', var(--font-sans); letter-spacing: -0.015em; }

.app .card {
  border-radius: var(--app-radius);
  background: linear-gradient(180deg, rgba(238, 242, 238, 0.03), transparent 40%), var(--color-surface);
  box-shadow: var(--app-shadow);
}

.app .muted { color: var(--color-muted); }

/* Buttons: same classes, softer surfaces and a lift on hover. */
.app .btn {
  background: var(--color-surface-2);
  border-color: var(--color-border);
  transition: background-color 0.25s ease, border-color 0.25s ease, transform 0.3s var(--app-ease), box-shadow 0.3s var(--app-ease);
}
.app .btn:hover:not(:disabled) { background: #37595f; border-color: rgba(214, 232, 227, 0.22); }
.app a.btn { display: inline-flex; align-items: center; justify-content: center; text-decoration: none; color: inherit; }

/* The variants keep their colours over the base rule above. */
.app .btn--primary, .app .btn--active { background: var(--color-accent); border-color: var(--color-accent); }
.app .btn--danger { background: var(--color-danger); border-color: var(--color-danger); }
.app .btn--off { background: #3a2f10; border-color: #574615; color: #fbbf24; }
.app .btn:active:not(:disabled) { transform: scale(0.98); }
.app .btn--primary, .app a.btn--primary { color: #fff; box-shadow: 0 8px 20px -12px rgba(90, 123, 242, 0.9); }
.app .btn--primary:hover:not(:disabled) { background: #6a89f6; border-color: #6a89f6; transform: translateY(-1px); }
.app .btn--danger { color: #fff; }
.app .btn--danger:hover:not(:disabled) { background: #ec5c61; border-color: #ec5c61; }

/* Fields everywhere inside the app get the same calm focus. */
.app input:not([type='checkbox']):not([type='radio']):not([type='range']):focus,
.app textarea:focus,
.app select:focus {
  outline: none;
  border-color: rgba(255, 213, 74, 0.7);
  box-shadow: 0 0 0 3px rgba(255, 213, 74, 0.22);
}

.app .banner { border-radius: 12px; }

/* Chat surfaces that use the shared classes: rounder, softer. */
.app .bubble { border-radius: 14px; }
.app .bubble--mine { color: #fff; }
.app .thread__composer input { border-radius: 999px; }

/* Quiet scrollbars. */
.app * { scrollbar-width: thin; scrollbar-color: rgba(214, 232, 227, 0.22) transparent; }

@media (prefers-reduced-motion: reduce) {
  .app .page { animation: none; }
  .app .app__nav a, .app .btn, .app .app__me { transition: none; }
}
__LP2_EOF__
echo "wrote apps/web/src/styles/theme.css"

cat > .landing-v2-patch.mjs <<'__LP2_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Homepage v2 and the app's new look — edits to files that stay otherwise
 * untouched. Every anchor must be found exactly once; otherwise nothing is
 * written and the installer stops.
 */

const plan = [
  {
    file: 'server/src/app.js',
    marker: 'publicRoutes',
    edits: [
      {
        name: 'import the public routes (contact form)',
        regex: /^import\s+scheduledRoomsRoutes\s+from\s+['"]([^'"]*)scheduledRooms\.routes\.js['"];?[ \t]*\r?\n/m,
        replace: (m, dir) => `${m}import publicRoutes from '${dir}public.routes.js';\n`,
      },
      {
        name: 'mount them under /public',
        regex: /^([ \t]*)app\.use\(\s*['"]\/scheduled-rooms['"],\s*scheduledRoomsRoutes\s*\);[^\n]*\r?\n/m,
        replace: (m, indent) => `${m}${indent}app.use('/public', publicRoutes); // Landing: contact form\n`,
      },
    ],
  },
  {
    file: 'apps/web/src/pages/AppLayout.jsx',
    marker: 'AppHeader',
    edits: [
      {
        name: 'NavLink now lives in AppHeader',
        find: "import { NavLink, Outlet, useNavigate } from 'react-router-dom';\n",
        replace: "import { Outlet, useNavigate } from 'react-router-dom';\n",
      },
      {
        name: 'the new top bar and the evening theme',
        find: "import DeletionBanner from '../components/system/DeletionBanner.jsx';\n",
        replace:
          "import DeletionBanner from '../components/system/DeletionBanner.jsx';\n" +
          "import AppHeader from '../components/system/AppHeader.jsx';\n" +
          "import '../styles/theme.css';\n",
      },
      {
        name: 'same five links, now with icons and your name',
        find:
          '      <header className="app__bar">\n' +
          '        <span className="app__brand">Classroom</span>\n' +
          '        <nav className="app__nav">\n' +
          '          <NavLink to="/" end>\n' +
          '            Dashboard\n' +
          '          </NavLink>\n' +
          '          <NavLink to="/community">Community</NavLink>\n' +
          '          <NavLink to="/messages">Messages</NavLink>\n' +
          '          <NavLink to="/media">Media</NavLink>\n' +
          '          <NavLink to="/settings">Settings</NavLink>\n' +
          '        </nav>\n' +
          '      </header>\n',
        replace: '      <AppHeader />\n',
      },
    ],
  },
];

const count = (src, edit) => {
  if (edit.regex) {
    const global = new RegExp(edit.regex.source, edit.regex.flags.includes('g') ? edit.regex.flags : `${edit.regex.flags}g`);
    return [...src.matchAll(global)].length;
  }
  return src.split(edit.find).length - 1;
};
const apply = (src, edit) => (edit.regex ? src.replace(edit.regex, edit.replace) : src.replace(edit.find, () => edit.replace));

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed in any patched file.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = count(src, edit);
    if (n !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${n}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = apply(src, edit);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__LP2_EOF__
node .landing-v2-patch.mjs
rm -f .landing-v2-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.tsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.tsx=tsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error --define:__RELEASE_SHA__=0 >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo "A file did not pass its check (see above). Undo with: bash landing-v2-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs \
  apps/web/src/components/Landing/__checks__/*.check.mjs apps/web/src/components/Auth/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .landing-v2-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .landing-v2-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .landing-v2-test.log
else
  cat .landing-v2-test.log
  rm -f .landing-v2-test.log
  echo "The rule checks failed (see above). Undo with: bash landing-v2-install.sh --restore" >&2
  exit 1
fi

echo "--- database"
if SERVICE_ROLE=api npm run db:migrate; then
  touch server/src/server.js
  echo
  echo "Homepage v2 and the new app look are installed, migration 025 applied."
  echo "The API restarts on its own; reload the browser tabs with Ctrl+Shift+R."
  echo "Homepage: a private window at /, or /welcome while signed in."
  if ! grep -qE '^CONTACT_EMAIL=.+' .env 2>/dev/null; then
    echo "Note: contact messages are stored in the table contact_messages. Set CONTACT_EMAIL=you@example.com"
    echo "in .env to also receive them by email (the worker's mail settings are used)."
  fi
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  exit 1
fi
if grep -qE '^SIGNUP_MODE=closed' .env 2>/dev/null; then
  echo "Note: SIGNUP_MODE=closed in .env — the sign-up form will refuse new accounts."
fi