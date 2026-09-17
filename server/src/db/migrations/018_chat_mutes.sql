-- 018_chat_mutes.sql
-- Channel moderation mutes used by ChatModerationService.assertNotMuted().

create table if not exists chat_mutes (
  mute_id       uuid        primary key default gen_random_uuid(),
  channel_id    uuid        not null references channels (channel_id) on delete cascade,
  user_id       uuid        not null references users (id) on delete cascade,
  muted_until   timestamptz,
  muted_by      uuid        not null references users (id),
  reason        text,
  created_at    timestamptz not null default now(),
  constraint chat_mutes_channel_user_key unique (channel_id, user_id)
);

create index if not exists chat_mutes_active_idx
  on chat_mutes (channel_id, user_id, muted_until);