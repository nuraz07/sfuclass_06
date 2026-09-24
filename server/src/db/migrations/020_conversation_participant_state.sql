-- 020_conversation_participant_state.sql
--
-- Per-person state of a conversation, and the duplicate guard for direct
-- messages. Additive only: no existing row changes meaning.
--
--   muted_until   a mute that ends by itself (1 h, 8 h, 1 day). `muted` stays the
--                 switch; a mute with muted_until in the past counts as off.
--   hidden_at     "deleted for me": the conversation is gone from this person's
--                 list. A new message in it clears the marker, so it comes back.
--   cleared_at    where this person's history starts after a delete. Messages
--                 at or before it stay hidden from them, also after it comes
--                 back; the other side keeps everything.
--
-- conversations.updated_at is read by the conversation model and by the
-- contract's timestamps; it did not exist.
--
-- participant_key: the unique index (tenant_id, participant_key) was already
-- there to guarantee one direct conversation per pair of people, but nothing
-- ever filled the key in. Existing direct conversations get it here — the
-- oldest one per pair only, so a pair that already has duplicates cannot make
-- this migration fail; the newer duplicates simply stay unkeyed.

alter table conversation_participants add column if not exists muted_until timestamptz;
alter table conversation_participants add column if not exists hidden_at   timestamptz;
alter table conversation_participants add column if not exists cleared_at  timestamptz;

alter table conversations add column if not exists updated_at timestamptz not null default now();

with pairs as (
  select cp.conversation_id,
         string_agg(cp.user_id::text, ':' order by cp.user_id) as pair_key,
         count(*) as members
    from conversation_participants cp
    join conversations c on c.id = cp.conversation_id
   where c.kind = 'direct'
     and c.participant_key is null
   group by cp.conversation_id
),
ranked as (
  select p.conversation_id,
         p.pair_key,
         c.tenant_id,
         row_number() over (partition by c.tenant_id, p.pair_key order by c.created_at, c.id) as rn
    from pairs p
    join conversations c on c.id = p.conversation_id
   where p.members = 2
)
update conversations c
   set participant_key = r.pair_key
  from ranked r
 where c.id = r.conversation_id
   and r.rn = 1
   and not exists (
         select 1 from conversations x
          where x.tenant_id = r.tenant_id and x.participant_key = r.pair_key
       );

-- The conversation list: someone's visible threads.
create index if not exists conversation_participants_visible_idx
    on conversation_participants (user_id)
 where left_at is null and hidden_at is null;
