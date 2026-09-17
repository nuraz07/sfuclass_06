-- 012_user_credentials.sql — login lockout and password age
--
-- identity/User.js has always written these three columns; 002_identity.sql
-- never created them. The mismatch surfaced as "column does not exist" on the
-- first sign-in attempt, which is the worst possible moment to discover it.
--
-- They are not optional decoration: failed_attempts and locked_until are the
-- brute-force lockout, and password_changed_at is what
-- Sessions.isIssuedBeforeRevocation compares against to invalidate every token
-- issued before a password change without having to list them.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS password_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS failed_attempts     integer     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS locked_until        timestamptz;

-- A locked account is rare, so the index only covers rows that are actually
-- locked. Sweeping expired lockouts then reads a handful of rows instead of
-- the whole table.
CREATE INDEX IF NOT EXISTS users_locked_until_idx
  ON users (locked_until)
  WHERE locked_until IS NOT NULL;

-- Existing rows predate the column; treating them as changed at creation time
-- is accurate enough and avoids a NULL every comparison has to special-case.
UPDATE users SET password_changed_at = created_at WHERE password_changed_at IS NULL;