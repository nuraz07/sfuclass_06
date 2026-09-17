-- 015_user_blocks_view.sql — one table, two vocabularies
--
-- 009_profiles.sql created `blocks` with `user_id`; messaging/models/Block.js
-- queries `user_blocks` with `blocker_id`. Two names for one table and two
-- names for one column.
--
-- This is not merely a failed query. chatGateway calls allRelatedIds() from
-- connection middleware without a catch, so the rejection is unhandled, and
-- server.js treats an unhandled rejection as fatal — one missing table killed
-- the process on the first socket that connected.
--
-- A view rather than a rename, for the same reason as 014: other callers
-- already use the migrated names, and renaming would fix one and break those.
-- `user_id` is kept alongside `blocker_id` so both vocabularies read correctly.

-- CREATE OR REPLACE can append columns but cannot rename or reorder existing
-- ones, and an earlier version of this file defined the view as SELECT *. The
-- drop is what lets the column list change; a view owns no data, so dropping
-- one costs nothing.
DROP VIEW IF EXISTS user_blocks;

CREATE VIEW user_blocks AS
  SELECT
    user_id,
    user_id AS blocker_id,
    blocked_id,
    reason,
    created_at
  FROM blocks;