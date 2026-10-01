-- 028_community_part3.sql  (Community, part 3)
--
--   study_profiles      opt-in: subjects, free times and a note, for finding study partners
--   study_requests      "study together?" — nothing is shared until both agree
--   scheduled_posts     the late-night nudge: a reply, thread or chat message sent at 8:00
--   space_log           what moderators did in a space, and why
--   threads.slow_seconds        calm mode: one reply per person every N seconds
--   spaces.chat_slow_seconds    calm mode for the space chat
--   space_memberships.notify_mode  'each' · 'daily' (one summary a day) · 'off'
--   space_memberships.last_digest_at
--
-- Additive only.

create table if not exists study_profiles (
  user_id      uuid        primary key references users (id) on delete cascade,
  tenant_id    uuid        not null references tenants (id) on delete cascade,
  active       boolean     not null default true,
  subjects     text[]      not null default '{}',
  availability text[]      not null default '{}',   -- e.g. {'tue-evening','sat-morning'}
  note         text,
  updated_at   timestamptz not null default now()
);
create index if not exists study_profiles_tenant_idx on study_profiles (tenant_id) where active;

create table if not exists study_requests (
  requester_id uuid        not null references users (id) on delete cascade,
  target_id    uuid        not null references users (id) on delete cascade,
  status       text        not null default 'pending',
  message      text,
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  primary key (requester_id, target_id),
  constraint study_requests_status_check check (status in ('pending', 'accepted', 'declined', 'ended')),
  constraint study_requests_self_check check (requester_id <> target_id)
);
create index if not exists study_requests_target_idx on study_requests (target_id, status);

create table if not exists scheduled_posts (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references users (id) on delete cascade,
  kind       text        not null,
  target_id  uuid        not null,             -- the thread (reply) or the space (thread, chat)
  payload    jsonb       not null,
  send_at    timestamptz not null,
  status     text        not null default 'pending',
  error      text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  constraint scheduled_posts_kind_check check (kind in ('reply', 'thread', 'chat')),
  constraint scheduled_posts_status_check check (status in ('pending', 'sent', 'cancelled', 'failed'))
);
create index if not exists scheduled_posts_due_idx on scheduled_posts (send_at) where status = 'pending';
create index if not exists scheduled_posts_user_idx on scheduled_posts (user_id, status);

create table if not exists space_log (
  id          uuid        primary key default gen_random_uuid(),
  space_id    uuid        not null references spaces (id) on delete cascade,
  actor_id    uuid        references users (id) on delete set null,
  action      text        not null,
  target_type text,
  target_id   uuid,
  detail      jsonb       not null default '{}',
  created_at  timestamptz not null default now()
);
create index if not exists space_log_space_idx on space_log (space_id, created_at desc);

alter table threads add column if not exists slow_seconds integer not null default 0;
alter table spaces add column if not exists chat_slow_seconds integer not null default 0;
alter table space_memberships add column if not exists notify_mode text not null default 'each';
alter table space_memberships add column if not exists last_digest_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'space_memberships_notify_mode_check') then
    alter table space_memberships add constraint space_memberships_notify_mode_check check (notify_mode in ('each', 'daily', 'off'));
  end if;
end $$;
