-- 019_channels_public_lobby_key.sql
--
-- One public lobby per tenant, enforced by the database.
--
-- Channel.ensureForScope() creates the lobby with INSERT ... ON CONFLICT. For
-- the public scope scope_ref_id is NULL (channels_scope_target_check), and
-- channels_scope_ref_key only covers rows WHERE scope_ref_id IS NOT NULL, so
-- nothing could ever conflict: the statement failed ("no unique or exclusion
-- constraint matching the ON CONFLICT specification"), and under the older
-- index shape two concurrent requests could create two lobbies.
--
-- Additive and non-destructive: a tenant that already has several active
-- lobbies keeps the oldest; the others are archived, never deleted, so their
-- messages stay readable.

UPDATE channels c
   SET archived_at = now(), updated_at = now()
 WHERE c.scope = 'public'
   AND c.archived_at IS NULL
   AND c.channel_id <> (
         SELECT c2.channel_id
           FROM channels c2
          WHERE c2.tenant_id = c.tenant_id
            AND c2.scope = 'public'
            AND c2.archived_at IS NULL
          ORDER BY c2.created_at, c2.channel_id
          LIMIT 1
       );

CREATE UNIQUE INDEX IF NOT EXISTS channels_public_lobby_key
    ON channels (tenant_id)
 WHERE scope = 'public' AND archived_at IS NULL;
