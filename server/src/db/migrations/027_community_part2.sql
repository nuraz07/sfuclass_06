-- 027_community_part2.sql  (Community, part 2)
--
--   space_cards        knowledge cards: a good answer, saved and findable
--   posts              hidden_solution: a reply that shows only when opened
--   space_messages     the chat of a space
--   space_materials    links a space keeps at hand (documents, videos, sites)
--   scheduled_sessions space_id: a drop-in room belongs to a space, and the
--                      space's members may enter it
--
-- Additive only.

create table if not exists space_cards (
  id         uuid        primary key default gen_random_uuid(),
  space_id   uuid        not null references spaces (id) on delete cascade,
  thread_id  uuid        references threads (id) on delete set null,
  post_id    uuid        references posts (id) on delete set null,
  title      text        not null,
  body       text        not null,
  created_by uuid        references users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists space_cards_space_idx on space_cards (space_id, created_at desc) where deleted_at is null;

alter table posts add column if not exists hidden_solution boolean not null default false;

create table if not exists space_messages (
  id         uuid        primary key default gen_random_uuid(),
  space_id   uuid        not null references spaces (id) on delete cascade,
  author_id  uuid        not null references users (id) on delete cascade,
  body       text        not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid        references users (id) on delete set null
);
create index if not exists space_messages_space_idx on space_messages (space_id, created_at desc);

create table if not exists space_materials (
  id         uuid        primary key default gen_random_uuid(),
  space_id   uuid        not null references spaces (id) on delete cascade,
  title      text        not null,
  url        text        not null,
  note       text,
  pinned     boolean     not null default false,
  added_by   uuid        references users (id) on delete set null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint space_materials_url_check check (url ~* '^https?://')
);
create index if not exists space_materials_space_idx on space_materials (space_id, pinned desc, created_at desc) where deleted_at is null;

alter table scheduled_sessions add column if not exists space_id uuid references spaces (id) on delete set null;
create index if not exists scheduled_sessions_space_idx on scheduled_sessions (space_id, starts_at) where space_id is not null;
