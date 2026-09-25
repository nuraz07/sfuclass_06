-- 021_profile_preferences.sql
--
-- Account-wide preferences that follow a person to every device: appearance,
-- date and time format, how they join a lesson, and — for teachers — the
-- defaults their new lessons start with.
--
-- One jsonb column rather than a column per setting: these are read together,
-- written one at a time, and change shape as the product grows. They carry no
-- constraint the database has to enforce; the server validates every key
-- (server/src/settings/preferences.js) before it is stored.
--
-- Additive only.

alter table profiles add column if not exists preferences jsonb not null default '{}'::jsonb;
