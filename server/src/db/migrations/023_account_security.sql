-- 023_account_security.sql  (Settings, Phase C)
--
-- Two-step sign-in, passkeys and scheduled account deletion.
--
--   user_totp                  one authenticator app per account. The secret is
--                              encrypted at rest (security/secretBox.js), never
--                              stored in the clear. last_used_step stops a code
--                              from being used twice.
--   user_recovery_codes        ten single-use codes, stored as SHA-256 hashes:
--                              they are random, so a slow hash adds nothing.
--   user_passkeys              WebAuthn credentials. rp_id records the site the
--                              passkey was made for; a browser will only use it
--                              there.
--   account_deletion_requests  "Delete my account" with a grace period. The
--                              account keeps working until scheduled_for, so
--                              signing in and pressing Cancel undoes it.
--
-- users.status already allows 'deleted', which is what the anonymisation sets.
-- Additive only.

create table if not exists user_totp (
  user_id          uuid        primary key references users (id) on delete cascade,
  secret_encrypted text        not null,
  last_used_step   bigint      not null default 0,
  enabled_at       timestamptz not null default now()
);

create table if not exists user_recovery_codes (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references users (id) on delete cascade,
  code_hash  text        not null,
  used_at    timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists user_recovery_codes_user_idx
  on user_recovery_codes (user_id) where used_at is null;

create table if not exists user_passkeys (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references users (id) on delete cascade,
  credential_id text        not null,
  public_key    bytea       not null,
  counter       bigint      not null default 0,
  transports    text[]      not null default '{}',
  device_type   text,
  backed_up     boolean     not null default false,
  name          text        not null default 'Passkey',
  rp_id         text        not null,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz,
  constraint user_passkeys_credential_key unique (credential_id)
);

create index if not exists user_passkeys_user_idx on user_passkeys (user_id);

create table if not exists account_deletion_requests (
  user_id       uuid        primary key references users (id) on delete cascade,
  requested_at  timestamptz not null default now(),
  scheduled_for timestamptz not null,
  completed_at  timestamptz
);

create index if not exists account_deletion_due_idx
  on account_deletion_requests (scheduled_for) where completed_at is null;
