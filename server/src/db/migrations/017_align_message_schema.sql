-- 017_align_message_schema.sql
-- Align the persisted message shape with the shared messaging model.

alter table messages rename column id to message_id;
alter table messages rename column sender_id to author_id;
alter table messages rename column client_id to client_message_id;

alter table messages add column target_kind text;
alter table messages add column room_id uuid;
alter table messages add column kind text not null default 'text';

update messages
set target_kind = case
  when conversation_id is not null then 'conversation'
  when channel_id is not null then 'channel'
  else 'room'
end
where target_kind is null;

alter table messages alter column target_kind set not null;
alter table messages add constraint messages_target_kind_check
  check (target_kind in ('conversation', 'channel', 'room'));

alter table messages drop constraint messages_scope_check;
alter table messages add constraint messages_scope_check check (
  (target_kind = 'conversation' and conversation_id is not null and channel_id is null and room_id is null) or
  (target_kind = 'channel' and conversation_id is null and channel_id is not null and room_id is null) or
  (target_kind = 'room' and conversation_id is null and channel_id is null and room_id is not null)
);

create index if not exists messages_room_keyset_idx
  on messages (room_id, created_at desc, message_id desc) where room_id is not null;