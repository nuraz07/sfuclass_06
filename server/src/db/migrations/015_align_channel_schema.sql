-- 015_align_channel_schema.sql
-- Bring the channel table in line with the messaging model used by the API.

alter table channels rename column id to channel_id;
alter table channels rename column slow_mode_seconds to slow_mode_sec;

alter table channels add column scope_ref_id uuid;
alter table channels add column read_only boolean not null default false;
alter table channels add column updated_at timestamptz not null default now();

update channels
set scope_ref_id = case
  when scope = 'space' then space_id
  when scope = 'course' then course_id
  else null
end
where scope_ref_id is null;

alter table channels drop constraint channels_scope_target_check;
alter table channels add constraint channels_scope_target_check check (
  (scope = 'public' and scope_ref_id is null) or
  (scope in ('space', 'course') and scope_ref_id is not null)
);

create unique index if not exists channels_scope_ref_key
  on channels (scope, scope_ref_id) where scope_ref_id is not null;