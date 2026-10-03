-- 033_space_chat_extras.sql  (Community: the space chat gets the chat's building blocks)
--
--   space_messages.updated_at    moves on every change (new, edit, delete,
--                                reaction), so an open chat catches up on all
--                                of them, not only on new messages
--   space_messages.edited_at     "edited"
--   space_messages.reply_to_id   replies quote the message they answer
--   space_message_reactions      one row per person and emoji
--   space_message_files          files from the upload pipeline (files, 029);
--                                voice_duration_ms marks a voice message
--
-- Additive only. Existing messages get updated_at = created_at.

alter table space_messages add column if not exists updated_at  timestamptz;
alter table space_messages add column if not exists edited_at   timestamptz;
alter table space_messages add column if not exists reply_to_id uuid references space_messages (id) on delete set null;
update space_messages set updated_at = coalesce(deleted_at, created_at) where updated_at is null;
alter table space_messages alter column updated_at set default now();
alter table space_messages alter column updated_at set not null;
create index if not exists space_messages_updated_idx on space_messages (space_id, updated_at);

create table if not exists space_message_reactions (
  message_id uuid        not null references space_messages (id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  emoji      text        not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

create table if not exists space_message_files (
  message_id        uuid     not null references space_messages (id) on delete cascade,
  file_id           uuid     not null references files (id) on delete cascade,
  position          smallint not null default 0,
  voice_duration_ms integer  check (voice_duration_ms is null or voice_duration_ms between 0 and 900000),
  primary key (message_id, file_id)
);
create index if not exists space_message_files_file_idx on space_message_files (file_id);
