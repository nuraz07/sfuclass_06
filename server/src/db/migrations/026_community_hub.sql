-- 026_community_hub.sql  (Community, part 1)
--
-- The community builds on the tables that already exist — spaces,
-- space_memberships, threads, posts — and adds only what they lack.
--
--   spaces            kind         'class' (a course or class) · 'topic' · 'study' (a small group with an end)
--                     access       'open' (anyone in the organisation joins) ·
--                                  'request' (ask, a moderator admits) · 'invite' (invisible to non-members)
--                     member_list  'members' (members see each other) · 'moderators' (only moderators see the list)
--                     join_question  asked when someone requests to join
--                     ends_at      a study group archives itself after this
--                     emoji, tags  how it looks and is found in Discover
--   space_memberships last_seen_at (what is new for you), timeout_until (a moderator's pause)
--   threads           kind 'discussion' · 'question', anonymous, answered_post_id, metoo_count
--   thread_metoo      "I have the same question"
--   space_join_requests, space_reports
--
-- spaces.visibility is left as it was; `access` is what the community uses.
-- Additive only.

alter table spaces add column if not exists kind          text    not null default 'topic';
alter table spaces add column if not exists access        text    not null default 'open';
alter table spaces add column if not exists member_list   text    not null default 'members';
alter table spaces add column if not exists join_question text;
alter table spaces add column if not exists ends_at       timestamptz;
alter table spaces add column if not exists emoji         text;
alter table spaces add column if not exists tags          text[]  not null default '{}';

alter table space_memberships add column if not exists last_seen_at  timestamptz;
alter table space_memberships add column if not exists timeout_until timestamptz;

alter table threads add column if not exists kind             text    not null default 'discussion';
alter table threads add column if not exists anonymous        boolean not null default false;
alter table threads add column if not exists answered_post_id uuid    references posts (id) on delete set null;
alter table threads add column if not exists metoo_count      integer not null default 0;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'spaces_kind_check') then
    alter table spaces add constraint spaces_kind_check check (kind in ('class', 'topic', 'study'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'spaces_access_check') then
    alter table spaces add constraint spaces_access_check check (access in ('open', 'request', 'invite'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'spaces_member_list_check') then
    alter table spaces add constraint spaces_member_list_check check (member_list in ('members', 'moderators'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'threads_kind_check') then
    alter table threads add constraint threads_kind_check check (kind in ('discussion', 'question'));
  end if;
end $$;

create table if not exists thread_metoo (
  thread_id  uuid        not null references threads (id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (thread_id, user_id)
);

create table if not exists space_join_requests (
  space_id   uuid        not null references spaces (id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  answer     text,
  status     text        not null default 'pending',
  decided_by uuid        references users (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (space_id, user_id),
  constraint space_join_requests_status_check check (status in ('pending', 'approved', 'declined'))
);

create table if not exists space_reports (
  id          uuid        primary key default gen_random_uuid(),
  space_id    uuid        not null references spaces (id) on delete cascade,
  target_type text        not null,
  target_id   uuid        not null,
  reporter_id uuid        not null references users (id) on delete cascade,
  reason      text        not null,
  note        text,
  status      text        not null default 'open',
  resolved_by uuid        references users (id) on delete set null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint space_reports_target_check check (target_type in ('thread', 'post', 'user')),
  constraint space_reports_status_check check (status in ('open', 'removed', 'dismissed'))
);

create index if not exists spaces_hub_discover_idx on spaces (tenant_id, access, created_at desc) where archived_at is null;
create index if not exists threads_hub_questions_idx on threads (space_id, kind, last_post_at desc) where deleted_at is null;
create index if not exists space_reports_open_idx on space_reports (space_id, created_at desc) where status = 'open';
