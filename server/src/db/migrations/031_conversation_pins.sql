-- 031_conversation_pins.sql  (Messages)
--
-- Per-person: a conversation pinned to the top of this person's list. Like
-- muted_until, hidden_at and cleared_at (020), it belongs to the participant
-- row; the other side never sees it.
--
-- Additive only.

alter table conversation_participants add column if not exists pinned_at timestamptz;
