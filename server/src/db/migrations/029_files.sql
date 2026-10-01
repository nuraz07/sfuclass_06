-- 029_files.sql  (Files and Media)
--
--   files            everyone's own uploads: the Media library. Bytes live in
--                    object storage (raw bucket until checked, then delivery);
--                    this row is the catalogue entry.
--   space_materials  can now point at a file instead of a link.
--
-- Additive only.

create table if not exists files (
  id            uuid        primary key default gen_random_uuid(),
  tenant_id     uuid        not null references tenants (id) on delete cascade,
  owner_id      uuid        not null references users (id) on delete cascade,
  name          text        not null,
  ext           text        not null,
  content_type  text        not null,
  kind          text        not null,
  size_bytes    bigint      not null,
  bucket        text        not null default 'raw',
  object_key    text        not null,
  status        text        not null default 'pending',
  reject_reason text,
  created_at    timestamptz not null default now(),
  ready_at      timestamptz,
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  constraint files_status_check check (status in ('pending', 'ready', 'rejected')),
  constraint files_kind_check check (kind in ('image', 'document', 'video', 'audio', 'text')),
  constraint files_size_check check (size_bytes > 0)
);
create index if not exists files_owner_idx on files (owner_id, created_at desc) where deleted_at is null;
create unique index if not exists files_object_key on files (object_key);

alter table space_materials add column if not exists file_id uuid references files (id) on delete set null;
alter table space_materials add column if not exists added_by_name text;
alter table space_materials alter column url drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'space_materials_target_check') then
    alter table space_materials add constraint space_materials_target_check check (url is not null or file_id is not null) not valid;
  end if;
end $$;
