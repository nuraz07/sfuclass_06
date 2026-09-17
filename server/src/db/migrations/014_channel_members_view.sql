-- 014_channel_members_view.sql — one table, two names
--
-- 008_messaging.sql created `channel_participants`; PublicChatService queries
-- `channel_members`. Renaming the table would fix this caller and break every
-- other one already using the migrated name, including the Participant model
-- the chat gateway depends on — so the table keeps its name and gains a second.
--
-- An updatable view rather than a copy: Postgres rewrites a simple view
-- automatically, so an INSERT through `channel_members` lands in
-- `channel_participants` and the two can never drift apart.

CREATE OR REPLACE VIEW channel_members AS
  SELECT * FROM channel_participants;