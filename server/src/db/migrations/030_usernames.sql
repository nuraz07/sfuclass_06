-- 030_usernames.sql  (Sign in with a username)
--
-- An optional username per account, unique regardless of case among accounts
-- that are not deleted, so someone can sign in with "anna.b" instead of an
-- email address. Stored as typed (lower-case, see identity/usernameRules.js).
-- Additive only.

alter table users add column if not exists username text;

create unique index if not exists users_username_key
  on users (lower(username))
  where username is not null and deleted_at is null;
