-- 013_profile_handle.sql — the @name a profile is addressed by
--
-- identity/Profile.js generates one on creation and checks it for uniqueness,
-- but 009_profiles.sql never created the column. Registration therefore
-- succeeded at the users table and failed at the profile, leaving an account
-- that exists but cannot be looked up by name.

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS handle text;

-- Unique per tenant, not globally: two schools may both want @alex, and
-- forcing them to compete for it serves nobody. The join is needed because
-- the tenant lives on users, not on profiles.
CREATE UNIQUE INDEX IF NOT EXISTS profiles_handle_key
  ON profiles (handle)
  WHERE handle IS NOT NULL;