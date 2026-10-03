-- 032_chat_reactions_files.sql  (Messages: reactions, attachments, voice)
--
--   message_reactions   one row per person and emoji on a message
--   message_files       files from the upload pipeline (files, 029) attached
--                       to a message; voice_duration_ms marks a voice message
--
-- The older message_attachments table (008) points at the legacy assets table
-- and stays as it is. Additive only.

create table if not exists message_reactions (
  message_id uuid        not null references messages (message_id) on delete cascade,
  user_id    uuid        not null references users (id) on delete cascade,
  emoji      text        not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);
create index if not exists message_reactions_message_idx on message_reactions (message_id);

create table if not exists message_files (
  message_id        uuid     not null references messages (message_id) on delete cascade,
  file_id           uuid     not null references files (id) on delete cascade,
  position          smallint not null default 0,
  voice_duration_ms integer  check (voice_duration_ms is null or voice_duration_ms between 0 and 900000),
  primary key (message_id, file_id)
);
create index if not exists message_files_file_idx on message_files (file_id);
