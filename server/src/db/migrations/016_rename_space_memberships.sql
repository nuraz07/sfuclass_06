-- 016_rename_space_memberships.sql
-- Match the community model's table name while preserving existing membership rows.

alter table memberships rename to space_memberships;