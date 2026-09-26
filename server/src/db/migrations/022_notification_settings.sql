-- 022_notification_settings.sql  (Settings, Phase B)
--
-- Notification settings get real storage, browsers can receive push, and the
-- account history reads quickly.
--
--   notification_preferences   exists since 004 with the type × channel matrix
--                              (channels jsonb) and quiet_start / quiet_end.
--                              Phase B adds the switches that go with them.
--   web_push_subscriptions     one row per browser that allowed push. Bound to
--                              the sign-in session that registered it, so
--                              signing that device out stops its notifications.
--   audit_log index            "Recent changes" and "Sign-in history" read one
--                              person's events by action, newest first.
--
-- Additive only.

alter table notification_preferences add column if not exists quiet_enabled       boolean not null default false;
alter table notification_preferences add column if not exists quiet_allow_lessons boolean not null default true;
alter table notification_preferences add column if not exists focus_in_lessons    boolean not null default true;
alter table notification_preferences add column if not exists show_previews       boolean not null default true;

create table if not exists web_push_subscriptions (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references users (id) on delete cascade,
  -- The Redis sign-in session (SessionStore) that registered it. Text, not a
  -- foreign key: sessions do not live in Postgres.
  session_id      text,
  endpoint        text        not null,
  p256dh          text        not null,
  auth            text        not null,
  user_agent      text,
  failures        integer     not null default 0,
  last_success_at timestamptz,
  created_at      timestamptz not null default now(),
  constraint web_push_subscriptions_endpoint_key unique (endpoint)
);

create index if not exists web_push_subscriptions_user_idx on web_push_subscriptions (user_id);
create index if not exists web_push_subscriptions_session_idx
  on web_push_subscriptions (session_id) where session_id is not null;

create index if not exists audit_log_actor_action_idx on audit_log (actor_id, action, id desc);
