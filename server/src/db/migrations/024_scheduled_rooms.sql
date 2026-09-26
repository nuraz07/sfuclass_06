-- 024_scheduled_rooms.sql  (Rooms: create your own room)
--
-- A room someone creates is a scheduled session (010) with a room of its own.
-- The session row stays the source of truth for time, host, invitees and
-- reminders, so the calendar feed, the reminder sweep and "who is invited"
-- keep working unchanged. What a self-created room adds:
--
--   room_code       the id in its link (/rooms/<code>), unique, unguessable
--   early_entry_min when the doors open: 3 to 10 minutes before the start
--   late_join_min   optional: nobody new after this many minutes past the
--                   start (people who were already in may always come back)
--   capacity        seats; null means the plan's limit
--   access          'invited'  host, co-hosts and invitees only
--                   'link'     anyone in the organisation who has the link
--   approval        people knock in the lobby and a host lets them in
--   cohost_ids      co-hosts: may enter early, admit people, extend and end
--   room_settings   how the room starts (muted learners, reactions, screen
--                   sharing) and the agenda
--
-- Additive only; lessons scheduled before this stay as they were.

alter table scheduled_sessions add column if not exists room_code       text;
alter table scheduled_sessions add column if not exists early_entry_min integer not null default 5;
alter table scheduled_sessions add column if not exists late_join_min   integer;
alter table scheduled_sessions add column if not exists capacity        integer;
alter table scheduled_sessions add column if not exists access          text    not null default 'invited';
alter table scheduled_sessions add column if not exists approval        boolean not null default false;
alter table scheduled_sessions add column if not exists cohost_ids      uuid[]  not null default '{}';
alter table scheduled_sessions add column if not exists room_settings   jsonb   not null default '{}'::jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_early_entry_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_early_entry_check
      check (early_entry_min between 3 and 10);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_late_join_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_late_join_check
      check (late_join_min is null or late_join_min between 0 and 120);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_capacity_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_capacity_check
      check (capacity is null or capacity between 2 and 1000);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_access_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_access_check
      check (access in ('invited', 'link'));
  end if;
end $$;

create unique index if not exists scheduled_sessions_room_code_key
  on scheduled_sessions (room_code) where room_code is not null;

-- "My rooms": what someone hosts, co-hosts or is invited to, by time.
create index if not exists scheduled_sessions_host_rooms_idx
  on scheduled_sessions (host_id, starts_at) where room_code is not null;
create index if not exists scheduled_sessions_cohosts_idx
  on scheduled_sessions using gin (cohost_ids) where room_code is not null;
