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
